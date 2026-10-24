#!/usr/bin/env python3
"""bconnect_axfast.py —— 直连 macOS 辅助功能 API（ctypes）的快速 AX 探针。

为什么不用 System Events：走 osascript + System Events 时，每读一个 AX 属性都是一次
AppleEvent 往返（实测约 17ms/次），一次全树遍历要 4~6s；而按本模块直接调
AXUIElementCopyAttributeValue 是进程内调用（约 0.3ms/次），同样遍历 243 个节点只要
0.23s（快 20 倍以上）。选机/等待页面这些「一次流程里读十几遍」的步骤，全部时间都花
在 AX 读取上，所以这一层是提速的关键。

前提：运行本模块的进程（这里是 python）已在「系统设置 → 隐私与安全性 → 辅助功能」
获得授权（AXIsProcessTrusted == True）；否则 available() 返回 False，调用方回退到
System Events 老路径。Electron 的 web 内容仍需 AXManualAccessibility=true 才会进树。

对外接口（与 bconnect_ax 中同名函数语义一致，失败返回空值、不抛异常）：
  available()          是否可用（已授权 + Connect 在跑）
  enable_ax()          给 Connect 打开 AXManualAccessibility
  send_info()          发送页设备选择器 {name, group{x,y,w,h}, chevron{x,y}|None}
  texts()              当前界面全部静态文字
  probe(texts, buttons) 短路探测（一次遍历同时找文字与按钮）
  press_text(want)     按按钮文字 AXPress
  press_desc(desc)     按按钮 description AXPress
  click_at(x, y)       CGEvent 真实鼠标点击（不过 AX、不抢焦点解析）
"""
from __future__ import annotations

import ctypes
import ctypes.util
import subprocess
import time

APP = "Bambu Connect"
MAX_DEPTH = 16

# ---------------------------------------------------------------- 动态库
_as = ctypes.CDLL(ctypes.util.find_library("ApplicationServices"))
_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))

_cf.CFStringCreateWithCString.restype = ctypes.c_void_p
_cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFRelease.restype = None
_cf.CFRelease.argtypes = [ctypes.c_void_p]
_cf.CFRetain.restype = ctypes.c_void_p
_cf.CFRetain.argtypes = [ctypes.c_void_p]
_cf.CFGetTypeID.restype = ctypes.c_ulong
_cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
_cf.CFStringGetTypeID.restype = ctypes.c_ulong
_cf.CFStringGetTypeID.argtypes = []
_CF_STRING_TYPE = _cf.CFStringGetTypeID()
_cf.CFArrayGetTypeID.restype = ctypes.c_ulong
_cf.CFArrayGetTypeID.argtypes = []
_CF_ARRAY_TYPE = _cf.CFArrayGetTypeID()
_cf.CFArrayGetCount.restype = ctypes.c_long
_cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
_cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
_cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]

_cf.CFBooleanGetValue.restype = ctypes.c_bool
_cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]

_as.AXIsProcessTrusted.restype = ctypes.c_bool
_as.AXUIElementCreateApplication.restype = ctypes.c_void_p
_as.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
_as.AXUIElementCopyAttributeValue.restype = ctypes.c_int
_as.AXUIElementCopyAttributeValue.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
_as.AXUIElementSetAttributeValue.restype = ctypes.c_int
_as.AXUIElementSetAttributeValue.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
_as.AXUIElementPerformAction.restype = ctypes.c_int
_as.AXUIElementPerformAction.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_as.AXValueGetValue.restype = ctypes.c_bool
_as.AXValueGetValue.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p]

_kCFBooleanTrue = ctypes.c_void_p.in_dll(_cf, "kCFBooleanTrue")
_UTF8 = 0x08000100          # kCFStringEncodingUTF8
_kAXValueCGPointType = 1
_kAXValueCGSizeType = 2


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


_cfstr_cache: dict[str, int] = {}


def _cfstr(s: str) -> int:
    """CFString 常量缓存（这些属性名一进程内反复用，不必每次重建）。"""
    v = _cfstr_cache.get(s)
    if v is None:
        v = _cf.CFStringCreateWithCString(None, s.encode("utf-8"), _UTF8)
        _cfstr_cache[s] = v
    return v


def _to_str(val: int | None) -> str:
    if not val:
        return ""
    # 必须先验类型：CFStringGetCString 收到 CFNumber/CFArray 会抛 ObjC 异常，
    # 直接把整个进程打挂（-getCString:maxLength:encoding: unrecognized selector）。
    if _cf.CFGetTypeID(val) != _CF_STRING_TYPE:
        return ""
    buf = ctypes.create_string_buffer(2048)
    if not _cf.CFStringGetCString(val, buf, 2048, _UTF8):
        return ""
    return buf.value.decode("utf-8", "replace")


def _attr(el: int, name: str) -> int | None:
    """读一个 AX 属性，返回 +1 引用（调用方负责 CFRelease），失败返回 None。"""
    v = ctypes.c_void_p()
    rc = _as.AXUIElementCopyAttributeValue(el, _cfstr(name), ctypes.byref(v))
    return v.value if rc == 0 and v.value else None


def _attr_str(el: int, name: str) -> str:
    v = _attr(el, name)
    if not v:
        return ""
    try:
        return _to_str(v)
    finally:
        _cf.CFRelease(v)


def _children(el: int) -> tuple[list[int], int | None]:
    """返回 (子元素 id 列表, 数组引用)。数组引用必须由调用方在遍历完再 CFRelease
    ——子元素由其持有，提前释放会让子元素失效。"""
    v = _attr(el, "AXChildren")
    if not v:
        return [], None
    if _cf.CFGetTypeID(v) != _CF_ARRAY_TYPE:
        _cf.CFRelease(v)
        return [], None
    n = _cf.CFArrayGetCount(v)
    return [ctypes.c_void_p(_cf.CFArrayGetValueAtIndex(v, i)).value or 0
            for i in range(n)], v


def _rect(el: int) -> dict | None:
    """元素的 {x, y, w, h}；读不到返回 None。"""
    pv, sv = _attr(el, "AXPosition"), _attr(el, "AXSize")
    try:
        if not pv or not sv:
            return None
        pt, sz = CGPoint(), CGSize()
        ok_p = _as.AXValueGetValue(pv, _kAXValueCGPointType, ctypes.byref(pt))
        ok_s = _as.AXValueGetValue(sv, _kAXValueCGSizeType, ctypes.byref(sz))
        if not (ok_p and ok_s):
            return None
        return {"x": pt.x, "y": pt.y, "w": sz.width, "h": sz.height}
    finally:
        for v in (pv, sv):
            if v:
                _cf.CFRelease(v)


def _center(el: int) -> dict | None:
    r = _rect(el)
    if not r:
        return None
    return {"x": r["x"] + r["w"] / 2, "y": r["y"] + r["h"] / 2}


# ---------------------------------------------------------------- 应用/进程
_pid_cache: dict = {"pid": 0, "t": 0.0}


def _pid() -> int:
    """Connect 的 pid（2 秒内复用；进程没了自动重查）。"""
    now = time.time()
    pid = _pid_cache["pid"]
    if pid and now - _pid_cache["t"] < 2.0:
        return pid
    try:
        out = subprocess.run(["pgrep", "-f", "%s.app/Contents/MacOS" % APP],
                             capture_output=True, text=True, timeout=5).stdout
        pid = int(out.split()[0]) if out.strip() else 0
    except Exception:  # noqa: BLE001
        pid = 0
    if pid:
        _pid_cache.update(pid=pid, t=now)
    return pid


def available() -> bool:
    try:
        return bool(_as.AXIsProcessTrusted()) and _pid() > 0
    except Exception:  # noqa: BLE001
        return False


def _app():
    """(app 元素, pid)；不可用时 (None, 0)。"""
    pid = _pid()
    if not pid:
        return None, 0
    return _as.AXUIElementCreateApplication(pid), pid


def frontmost() -> bool:
    """Connect 是否在最前（读 AXFrontmost，约 1ms，不必起 osascript）。"""
    app, _ = _app()
    if not app:
        return False
    try:
        v = _attr(app, "AXFrontmost")
        if not v:
            return False
        try:
            return bool(_cf.CFBooleanGetValue(v))
        finally:
            _cf.CFRelease(v)
    finally:
        _cf.CFRelease(app)


def app_focused() -> bool:
    """Connect 当前是否有「键盘焦点窗口」（激活到能接收点击还需要窗口 key）。

    「app 在最前」不等于「窗口能接收点击」：刚激活时有一段窗口还没 key 的空档，
    这时注入的点击会被系统吞掉（下拉点不开）。所以点像素坐标前要等这个为 True。
    """
    app, _ = _app()
    if not app:
        return False
    try:
        v = _attr(app, "AXFocusedWindow")
        if not v:
            return False
        _cf.CFRelease(v)
        return True
    finally:
        _cf.CFRelease(app)


def enable_ax() -> bool:
    """给 Connect 打开 AXManualAccessibility（Electron web 内容默认不进 AX 树）。"""
    app, _ = _app()
    if not app:
        return False
    try:
        rc = _as.AXUIElementSetAttributeValue(
            app, _cfstr("AXManualAccessibility"), _kCFBooleanTrue)
        return rc == 0
    finally:
        _cf.CFRelease(app)


# ---------------------------------------------------------------- 遍历
def walk(on_element, depth_max: int = MAX_DEPTH) -> bool:
    """深度优先遍历 Connect 全部窗口；on_element(el, depth) 返回 True 即提前结束。

    遍历期间数组引用全程持有，结束后统一释放（子元素由数组持有）。
    """
    app, _ = _app()
    if not app:
        return False
    keep: list[int] = [app]
    stop = False

    def rec(el: int, d: int) -> None:
        nonlocal stop
        if stop or d > depth_max:
            return
        kids, arr = _children(el)
        if arr:
            keep.append(arr)
        for k in kids:
            if stop or not k:
                continue
            if on_element(k, d + 1):
                stop = True
                break
            rec(k, d + 1)

    try:
        rec(app, 0)
    finally:
        for ref in keep:
            _cf.CFRelease(ref)
    return stop


def _role(el: int) -> str:
    return _attr_str(el, "AXRole")


def _label(el: int) -> str:
    """按钮可见文字 = AXTitle + AXValue + 子元素的 AXTitle/AXValue（同 _PRESS_JS）。"""
    lbl = _attr_str(el, "AXTitle") + _attr_str(el, "AXValue")
    kids, arr = _children(el)
    try:
        for k in kids:
            if k:
                lbl += _attr_str(k, "AXTitle") + _attr_str(k, "AXValue")
    finally:
        if arr:
            _cf.CFRelease(arr)
    return lbl


# ---------------------------------------------------------------- 对外接口
def send_info() -> dict | None:
    """发送页设备选择器：{name, group{x,y,w,h}, chevron{x,y}|None}。

    group  = description 形如「{机名} chevron_down」的 AXGroup（发送页只有一个）
    chevron = 该组内部那个 chevron_down 箭头（页面上别处也有同名箭头，必须按包含
              关系筛，否则会点到无关的箭头）
    """
    found: dict = {}

    def on(el, _d):
        desc = _attr_str(el, "AXDescription")
        if "chevron_down" not in desc:
            return False
        role = _role(el)
        if role == "AXGroup" and not found.get("group"):
            r = _rect(el)
            if r:
                found["group"] = r
                found["name"] = desc.replace("chevron_down", "").strip()
        elif role == "AXImage" and found.get("group") and not found.get("chevron"):
            c = _center(el)
            g = found["group"]
            if c and g["x"] <= c["x"] <= g["x"] + g["w"] \
                    and g["y"] <= c["y"] <= g["y"] + g["h"]:
                found["chevron"] = c
        return bool(found.get("group") and found.get("chevron"))

    walk(on)
    if not found.get("group"):
        return None
    return {"name": found.get("name", ""), "group": found["group"],
            "chevron": found.get("chevron")}


def send_target_device() -> str:
    info = send_info()
    return (info or {}).get("name") or ""


_TEXT_ROLES = ("AXStaticText", "AXHeading", "AXTextField", "AXTextArea")


def texts(limit: int = 400) -> list[str]:
    out: list[str] = []

    def on(el, _d):
        if len(out) >= limit:
            return True
        if _role(el) in _TEXT_ROLES:
            t = _attr_str(el, "AXValue") or _attr_str(el, "AXTitle") \
                or _attr_str(el, "AXDescription")
            if t:
                out.append(t)
        return False

    walk(on)
    return out


def probe(want_texts: list[str] | None = None,
          want_buttons: list[str] | None = None) -> dict:
    """短路探测：一次遍历同时找文字/按钮；全部命中即停（同 bconnect_ax.probe）。"""
    wt = list(want_texts or [])
    wb = list(want_buttons or [])
    ft: dict[str, str] = {}
    fb: dict[str, dict] = {}
    need_t, need_b = len(wt), len(wb)

    def on(el, _d):
        nonlocal need_t, need_b
        role = _role(el)
        if need_t and role in _TEXT_ROLES:
            t = _attr_str(el, "AXValue") or _attr_str(el, "AXTitle")
            if t:
                for w in wt:
                    if w not in ft and w in t:
                        ft[w] = t
                        need_t -= 1
        if need_b and role == "AXButton":
            full = _label(el) + _attr_str(el, "AXDescription")
            for w in wb:
                if w not in fb and w in full:
                    fb[w] = {"label": full, "pos": _rect(el)}
                    need_b -= 1
        return need_t == 0 and need_b == 0

    walk(on)
    return {"texts": ft, "buttons": fb}


def _press(predicate) -> bool:
    hit: list[int] = []

    def on(el, _d):
        if _role(el) == "AXButton" and predicate(el):
            hit.append(el)
            return True
        return False

    walk(on)
    # walk() 已释放元素引用：改为在遍历中直接按，避免持有失效引用
    return bool(hit)


def press_text(want: str) -> bool:
    if not want:
        return False
    done: list[bool] = []

    def on(el, _d):
        if _role(el) != "AXButton":
            return False
        if want in _label(el):
            done.append(_as.AXUIElementPerformAction(el, _cfstr("AXPress")) == 0)
            return True
        return False

    walk(on)
    return bool(done and done[0])


def press_desc(desc: str) -> bool:
    if not desc:
        return False
    done: list[bool] = []

    def on(el, _d):
        if _role(el) != "AXButton":
            return False
        if _attr_str(el, "AXDescription") == desc:
            done.append(_as.AXUIElementPerformAction(el, _cfstr("AXPress")) == 0)
            return True
        return False

    walk(on)
    return bool(done and done[0])


# ---------------------------------------------------------------- 通用点击（控制流）
# 与 bconnect_ax 里同名 JS 版本语义一致，但走进程内 AX API（~0.3ms/属性），
# 一次全树遍历 0.2~0.4s；osascript 版本要 2~8s（每读一个属性一次 AppleEvent 往返）。
_CLICKABLE_ROLES = frozenset((
    "AXButton", "AXLink", "AXCell", "AXImage", "AXRadioButton",
    "AXCheckBox", "AXPopUpButton", "AXMenuItem",
))

# 控制图标按钮没有 label，只能按「大小≈30x32 + 与「跳过」同一行」识别。
_ICON_W = (28.0, 32.0)
_ICON_H = (30.0, 34.0)


def press_desc_any(want: str) -> bool:
    """按 description/title「包含」匹配点任意可点元素（导航链接、打印机卡片）。

    点了就在遍历里就地 AXPress（遍历结束后数组引用释放，元素会失效）。
    """
    if not want:
        return False
    done: list[bool] = []

    def on(el, _d):
        if _role(el) not in _CLICKABLE_ROLES:
            return False
        d = _attr_str(el, "AXDescription")
        t = _attr_str(el, "AXTitle")
        if want in d or want in t:
            done.append(_as.AXUIElementPerformAction(el, _cfstr("AXPress")) == 0)
            return True
        return False

    walk(on)
    return bool(done and done[0])


def press_at_any(x: float, y: float) -> bool:
    """点「包含 (x,y)」可点元素里最小的那个（取最深的可点元素）。"""
    hit: list[int] = []
    area: list[float] = []

    def on(el, _d):
        if _role(el) not in _CLICKABLE_ROLES:
            return False
        r = _rect(el)
        if not r or r["w"] <= 0 or r["h"] <= 0:
            return False
        if not (r["x"] <= x <= r["x"] + r["w"] and r["y"] <= y <= r["y"] + r["h"]):
            return False
        a = r["w"] * r["h"]
        if not area or a < area[0]:
            # 要等遍历结束再点，元素引用必须先 CFRetain 住
            if hit:
                _cf.CFRelease(hit[0])
            _cf.CFRetain(el)
            hit[:] = [el]
            area[:] = [a]
        return False

    walk(on)
    if not hit:
        return False
    try:
        return _as.AXUIElementPerformAction(hit[0], _cfstr("AXPress")) == 0
    finally:
        _cf.CFRelease(hit[0])


def press_at(x: float, y: float) -> bool:
    """点「包含 (x,y)」的 AXButton（含 3px 容差），取面积最小者。"""
    hit: list[int] = []
    area: list[float] = []

    def on(el, _d):
        if _role(el) != "AXButton":
            return False
        r = _rect(el)
        if not r or r["w"] <= 0 or r["h"] <= 0:
            return False
        if not (r["x"] - 3 <= x <= r["x"] + r["w"] + 3
                and r["y"] - 3 <= y <= r["y"] + r["h"] + 3):
            return False
        a = r["w"] * r["h"]
        if not area or a < area[0]:
            if hit:
                _cf.CFRelease(hit[0])
            _cf.CFRetain(el)
            hit[:] = [el]
            area[:] = [a]
        return False

    walk(on)
    if not hit:
        return False
    try:
        return _as.AXUIElementPerformAction(hit[0], _cfstr("AXPress")) == 0
    finally:
        _cf.CFRelease(hit[0])


def press_control(name: str, command: str) -> dict:
    """一次遍历：确认在 name 详情页 + 找「跳过」锚 + 点对应控制图标。

    返回 {"pressed": bool, "coord": [x,y], "reason": str}；reason 与
    bconnect_ax.press_control 的 osascript 版本完全一致：
      not_on_detail（不在详情页）/ wrong_printer（别的打印机）/
      idle_no_skip（空闲，没有控制按钮）/ no_icons / press_failed。
    找到两个图标的那一刻就地点击（遍历结束引用即失效）。
    """
    st: dict = {"name": False, "skip": None, "icons": []}
    out: dict = {}

    def on(el, _d):
        role = _role(el)
        if not st["name"] and role in _TEXT_ROLES:
            t = _attr_str(el, "AXValue") or _attr_str(el, "AXTitle")
            if t and name in t:
                st["name"] = True
        elif role == "AXButton" and len(st["icons"]) < 2:
            lbl = _attr_str(el, "AXTitle") + _attr_str(el, "AXValue")
            r = _rect(el)
            # 「跳过」认 title/value/description 三处（System Events 的 name 在
            # title 为空时会退回 description，这里保持同样的宽松度）
            if not st["skip"] and "跳过" in (lbl + _attr_str(el, "AXDescription")):
                if r:
                    st["skip"] = r
            elif st["skip"] and not lbl and r:
                if (_ICON_W[0] <= r["w"] <= _ICON_W[1]
                        and _ICON_H[0] <= r["h"] <= _ICON_H[1]
                        and abs(r["y"] - st["skip"]["y"]) < 0.5):
                    st["icons"].append({"el": el, "rect": r})
        # 三个条件齐了才点（与 osascript 版 done() 一致）：机器名核对是「不误控别的
        # 打印机」的关键，不能只看按钮在不在。
        if st["name"] and st["skip"] and len(st["icons"]) >= 2:
            _fire_control(st, command, out)
            return True
        return False

    walk(on)
    if out:
        return out
    if not st["skip"]:
        return {"pressed": False,
                "reason": "idle_no_skip" if st["name"] else "not_on_detail"}
    if not st["name"]:
        return {"pressed": False, "reason": "wrong_printer"}
    return {"pressed": False, "reason": "no_icons"}


def _fire_control(st: dict, command: str, out: dict) -> None:
    """按 x 排序取图标（stop=第 2 个，其余=第 1 个）并 AXPress。"""
    icons = sorted(st["icons"], key=lambda i: i["rect"]["x"])
    tgt = icons[1] if command == "stop" else icons[0]
    r = tgt["rect"]
    coord = [r["x"] + r["w"] / 2, r["y"] + r["h"] / 2]
    if _as.AXUIElementPerformAction(tgt["el"], _cfstr("AXPress")) == 0:
        out.update(pressed=True, coord=coord)
    else:
        out.update(pressed=False, reason="press_failed")


def buttons() -> list[dict]:
    out: list[dict] = []

    def on(el, _d):
        if len(out) > 400:
            return True
        if _role(el) == "AXButton":
            r = _rect(el) or {}
            out.append({"label": _label(el), "desc": _attr_str(el, "AXDescription"),
                        "pos": [r.get("x", 0), r.get("y", 0)],
                        "size": [r.get("w", 0), r.get("h", 0)]})
        return False

    walk(on)
    return out


# ---------------------------------------------------------------- 真实鼠标点击
_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventCreateMouseEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
_cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
_cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]

_kCGEventLeftMouseDown = 1
_kCGEventLeftMouseUp = 2
_kCGMouseButtonLeft = 0
_kCGHIDEventTap = 0


_cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
_cg.CGEventCreateKeyboardEvent.argtypes = [
    ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
_KVK_ESCAPE = 53


def press_escape() -> bool:
    """发一次 Esc 键（CGEvent 注入）。用于收起可能还开着的下拉浮层。"""
    try:
        down = _cg.CGEventCreateKeyboardEvent(None, _KVK_ESCAPE, True)
        up = _cg.CGEventCreateKeyboardEvent(None, _KVK_ESCAPE, False)
        if not down or not up:
            return False
        _cg.CGEventPost(_kCGHIDEventTap, down)
        _cg.CGEventPost(_kCGHIDEventTap, up)
        _cf.CFRelease(down)
        _cf.CFRelease(up)
        return True
    except Exception:  # noqa: BLE001
        return False


def click_at(x: float, y: float) -> bool:
    """在屏幕坐标发一次真实鼠标点击（CGEvent 注入，不经 AX 解析、不会挂）。

    点的是「该坐标最顶层窗口」，所以调用前需确保 Connect 在最前。
    """
    try:
        pt = CGPoint(float(x), float(y))
        down = _cg.CGEventCreateMouseEvent(
            None, _kCGEventLeftMouseDown, pt, _kCGMouseButtonLeft)
        up = _cg.CGEventCreateMouseEvent(
            None, _kCGEventLeftMouseUp, pt, _kCGMouseButtonLeft)
        if not down or not up:
            return False
        _cg.CGEventPost(_kCGHIDEventTap, down)
        _cg.CGEventPost(_kCGHIDEventTap, up)
        _cf.CFRelease(down)
        _cf.CFRelease(up)
        return True
    except Exception:  # noqa: BLE001
        return False


if __name__ == "__main__":
    t0 = time.time()
    print("available:", available(), "%.3fs" % (time.time() - t0))
    t0 = time.time()
    print("send_info:", send_info(), "%.3fs" % (time.time() - t0))
    t0 = time.time()
    ls = texts()
    print("texts(%d):" % len(ls), ls[:12], "%.3fs" % (time.time() - t0))
