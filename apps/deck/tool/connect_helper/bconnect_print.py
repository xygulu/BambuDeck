#!/usr/bin/env python3
"""Bambu Connect 云端打印驱动 —— 供 BambuDeck(deck) 调用。

真机验证过的三步（2026-10-21，macOS + Bambu Connect 2.5.0-beta.15）：
    deep link(bambu-connect://import-file)
      -> 导入弹窗（取消 / 导入Gcode 3MF文件）
      -> 打印选项页（打印）
      -> 发送页（取消 / 发送）  ==> Connect 以自己的合法身份向拓竹云端派单

为什么必须这样做：直接调云端 API 建任务只能拿到 status=1（永不下发）；
走 Connect 才能拿到 status=3（打印机真的开始执行）。见 README 第十一节。

★★★ 重要（踩过的坑，别改回去）★★★
1. 不要用 `entire contents of window 1` 找按钮。
   Electron/Chromium 在页面切换时会重建 AX 树，`entire contents` 间歇返回 0 个元素，
   即使窗口明明有子元素 —— 表现就是「前面都点得动，最后发送点不动/找不到按钮」。
   本文件改用 bconnect_ax.py 的 JXA 手动递归遍历（UI elements 层层走）。
2. 不要只按按钮名字匹配。
   Connect 的按钮 name 经常是空的，文字挂在下级 AXStaticText 上；
   而它稳定的标识是英文 description：confirm=发送/导入, cancel=取消, refresh=刷新。
   所以先按文字匹配，再按 desc 兜底。
3. 每次都重设 AXManualAccessibility。
   窗口重建后该标志会失效，文字节点全部消失（界面看着正常，AX 里啥都没有）。

用法（CLI）:
    python bconnect_print.py --file /path/to/x.gcode.3mf --json
    python bconnect_print.py --file ... --stop-before-send   # 只到发送页，不派单
    python bconnect_print.py --list-buttons                  # 调试：当前界面按钮
    python bconnect_print.py --dump                          # 调试：按钮+文字

JSON 输出契约（--json）:
    {"ok": bool,  # True = 已点「发送」即派单成功，不等页面离开/任务落库/打印执行
     "file": str, "steps": [{"step": str, "ok": bool, "detail": str,
                             "elapsed": float, "since_prev": float}],
     "task": {"id": int|None, "status": int|None, "device": str|None},
     "printer": {"state": str|None, "percent": int|None},
     "elapsed_total": float, "error": str|None}

前置条件:
    1. Bambu Connect 已安装且已登录（首次需人工登录一次）
    2. 系统设置 → 隐私与安全性 → 辅助功能，允许运行本脚本的 python
    3. 打印机在拓竹云端在线（云模式）
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse

APP = "Bambu Connect"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DEVICE = "03900D642905133"

# 默认静默：打印/换盘不把 Connect 置前（deep link 用 open -g 后台打开、跳过 activate），
# 并在「导入弹窗出现后 / 点完发送后」立刻把焦点压回用户原来的 app（不等到整个流程结束）。
# 要回到旧前台行为（Connect 全程置前、结束才还原焦点）设 BAMBU_SILENT=0。
SILENT = os.environ.get("BAMBU_SILENT", "1").strip().lower() not in ("0", "false", "no", "off")

sys.path.insert(0, HERE)
# 界面驱动层按平台选: Windows 用 bconnect_uia (UIA 控件树), macOS 用
# bconnect_ax (辅助功能 API + JXA)。以前 Windows 部署时要手工把 uia 拷成
# ax, 改代码经常忘了同步 —— 现在按平台显式 import, 拷贝这一步没了。
if os.name == "nt":
    import bconnect_uia as ax  # noqa: E402
else:
    import bconnect_ax as ax  # noqa: E402
import bconnect_cloud as cloud  # noqa: E402


_IS_WIN = os.name == "nt"  # Windows 移植 (2026-10-28): 进程探测/启动走 tasklist/exe


def _log(*a) -> None:
    """诊断输出 (service.log 收 stdout; 2026-10-29 补: 两处调用点早于定义)。"""
    print("[bp]", *a, flush=True)


# ---------------------------------------------------------------- 应用控制
def _frontmost_app() -> str | None:
    """当前最前 app 名。SILENT 模式下 Connect 收到 deep link 会自己弹到最前，
    用它把焦点还给用户原来的 app。"""
    if _IS_WIN:
        # Windows 不做焦点还原: helper 面向无人值守 console 会话 (autologon),
        # 没有「用户原来的 app」可还; RDP 在看的场景焦点被 Connect 拿走无伤大雅。
        return None
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first process '
         'whose frontmost is true'],
        capture_output=True, text=True, timeout=30)
    return (r.stdout or "").strip() or None


def _restore_frontmost(prev: str | None) -> None:
    """把焦点还给 prev（若不是 Connect）。绝不抛异常。"""
    if _IS_WIN or not prev or prev == APP:
        return
    try:
        subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % prev],
                       capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def app_running() -> bool:
    if _IS_WIN:
        r = subprocess.run(["tasklist", "/fi", "imagename eq %s.exe" % APP],
                           capture_output=True, text=True)
        return "%s.exe" % APP in (r.stdout or "")
    r = subprocess.run(["pgrep", "-f",
                        "%s.app/Contents/MacOS/%s" % (APP, APP)],
                       capture_output=True, text=True)
    return bool(r.stdout.strip())


def ensure_app(timeout: int = 30) -> str:
    """确保 Connect 在跑；默认并置前，BAMBU_SILENT=1 时保持后台。返回 'already'/'launched'。"""
    if app_running():
        if not SILENT and not _IS_WIN:
            subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % APP],
                           capture_output=True, text=True)
        return "already"
    if _IS_WIN:
        exe = os.path.expandvars(
            r"%LOCALAPPDATA%\Programs\bambu-connect\Bambu Connect.exe")
        subprocess.Popen([exe], cwd=os.path.dirname(exe))
    else:
        subprocess.run(["open", "-a", "/Applications/%s.app" % APP], check=False)
    for _ in range(timeout):
        time.sleep(1)
        if app_running():
            time.sleep(3)
            if not SILENT and not _IS_WIN:
                subprocess.run(["osascript", "-e",
                                'tell application "%s" to activate' % APP],
                               capture_output=True, text=True)
            return "launched"
    raise RuntimeError("Bambu Connect 启动失败")


def enable_ax() -> None:
    """Electron 的 web 内容默认不进无障碍树；窗口重建后要重设。"""
    if not ax.enable_ax():
        raise RuntimeError(
            "辅助功能未授权，无法操作 Connect 界面。请到 系统设置 → 隐私与安全性 → "
            "辅助功能 里勾选运行本脚本的 python（当前: %s）" % sys.executable)


def list_buttons() -> list[str]:
    return ax.labels()


def dump() -> dict:
    return {"buttons": [{"label": b["label"], "desc": b["desc"], "pos": b["pos"]}
                        for b in ax.buttons()],
            "texts": ax.texts()}


# ---------------------------------------------------------------- 轮询工具
# 轮询间隔（2026-10-24 提速）：AX 读取走快速路径（直连 AX API）后单次只要 ~20ms，
# 间隔从 1.0s 收紧到 0.08s，检测延迟从「最多 2.8s」降到 ~0.1s；总流程的等待时间
# 现在基本只剩 Connect 自己加载 3mf/切页的真实耗时。
_POLL_INTERVAL = 0.08


def _poll(fn, timeout: float, interval: float = _POLL_INTERVAL) -> bool:
    """轮询条件。AX 每轮重设一次没必要（窗口重建才需要），改为每 10 轮补一次。"""
    deadline = time.time() + timeout
    i = 0
    while time.time() < deadline:
        if i % 10 == 0:
            ax.enable_ax()
        i += 1
        try:
            if fn():
                return True
        except Exception:  # noqa: BLE001  窗口切换瞬间会报无效索引
            pass
        time.sleep(interval)
    return False


def wait_text(marker: str, timeout: float) -> bool:
    return _poll(lambda: ax.has_text(marker), timeout)


def wait_button(marker: str, timeout: float) -> bool:
    return _poll(lambda: any(marker in ln for ln in ax.labels()), timeout)


def gone_text(marker: str, timeout: float) -> bool:
    return _poll(lambda: not ax.has_text(marker), timeout)


def press_text(marker: str, tries: int = 3) -> bool:
    for _ in range(tries):
        if ax.press_text(marker):
            return True
        ax.enable_ax()
        time.sleep(0.15)
    return False


def press_desc(desc: str, tries: int = 3) -> bool:
    for _ in range(tries):
        if ax.press_desc(desc):
            return True
        ax.enable_ax()
        time.sleep(0.15)
    return False


def press_confirm_after(marker: str, timeout: float = 20.0) -> bool:
    """仅在确认页面文字出现后才按 confirm，避免误触别的弹窗。"""
    if not wait_text(marker, timeout):
        return False
    return press_desc("confirm")


def wait_probe(timeout: float, texts=(), buttons=(),
               interval: float = _POLL_INTERVAL) -> bool:
    """短路探测轮询：一次遍历同时找多个文字/按钮，找到即停。

    只有全部目标都命中才返回 True。AX 重设改为每 10 轮一次（窗口重建才需要）。
    """
    deadline = time.time() + timeout
    i = 0
    while time.time() < deadline:
        if i % 10 == 0:
            ax.enable_ax()
        i += 1
        try:
            r = ax.probe(texts=list(texts), buttons=list(buttons))
        except Exception:  # noqa: BLE001
            r = {"texts": {}, "buttons": {}}
        if all(t in r["texts"] for t in texts) and \
           all(b in r["buttons"] for b in buttons):
            return True
        time.sleep(interval)
    return False


def gone_probe(timeout: float, texts=(), buttons=(),
               interval: float = _POLL_INTERVAL, confirm: int = 2) -> bool:
    """轮询直到目标文字/按钮连续 `confirm` 次都不出现。

    必须连续多次确认「消失」：Electron 页面切换时会重建 AX 树，瞬时返回空树
    （看起来「文字没了」），单次空读不能算「已离开」（会误判为已发送成功）。
    """
    deadline = time.time() + timeout
    streak = 0
    i = 0
    while time.time() < deadline:
        if i % 10 == 0:
            ax.enable_ax()
        i += 1
        try:
            r = ax.probe(texts=list(texts), buttons=list(buttons))
        except Exception:  # noqa: BLE001
            r = {"texts": {}, "buttons": {}}
        if all(t not in r["texts"] for t in texts) and \
           all(b not in r["buttons"] for b in buttons):
            streak += 1
            if streak >= confirm:
                return True
        else:
            streak = 0
        time.sleep(interval)
    return False


def open_deeplink(path: str, name: str | None = None) -> str:
    name = name or os.path.basename(path)
    url = "bambu-connect://import-file?path=%s&name=%s&version=1.0.0" % (
        urllib.parse.quote(os.path.abspath(path), safe=""),
        urllib.parse.quote(name, safe=""))
    if _IS_WIN:
        # Windows: scheme 已注册 (HKCU\Software\Classes\bambu-connect,
        # 2026-10-29 实测), startfile 即 ShellExecute url, 会顺带激活 Connect。
        os.startfile(url)  # noqa: S606
    else:
        # SILENT 时 -g 后台打开（不抢焦点）；否则默认前台激活 Connect。
        subprocess.run(["open", "-g", url] if SILENT else ["open", url], check=False)
    return url


# ---------------------------------------------------------------- 云端校验
# cloud_state / latest_task 已收拢到 bconnect_cloud.py（共享层），
# 调用处用 cloud.cloud_state / cloud.latest_task。


# ---------------------------------------------------------------- 主流程
SEND_PAGE = "发送打印任务至"
IMPORT_PAGE = "导入文件"
_PAGE_LABEL = {SEND_PAGE: "发送页", IMPORT_PAGE: "导入弹窗"}
# Windows (2026-10-29 P17–P22 实测): 选项页「浏览换文件」按钮与导入弹窗确认钮
# 文案同名, 按按钮名探弹窗必假阳性 —— 弹窗探测只能用正文标记。
WIN_IMPORT_TEXT = "您将导入文件"

# 下拉布局偏移（2026-10-24 实测标定，Bambu Connect 2.5.0-beta.15）。
# 发送页设备选择器的下拉选项不暴露在 macOS AX 树（AXShowMenu/AXRows/children 都
# 读不到选项），自动选机只能靠「真实鼠标点击像素坐标」。下拉从设备选择器下方展开，
# 但**行序没有保证**（2026-10-25 实测首项是「嘉兴」而不是名称升序该排最前的
# 「123」，用户反馈顺序会变），所以只信「行高固定」，不按名字推位次——逐行点、
# 点完读回机名验证。偏移相对选择器组算（不依赖绝对窗口位置）：
#   第 0 项名字中心 ≈ 组下缘 +26px；行高 36px（2026-10-24 截图实测 473/509/545）。
# 名字 x：三项文字都从「组左缘 +63px」起（实测 123/嘉兴/拓竹A1宇树 均 528 起）；
# 取 +71 落在最短文字「123」(528~550) 中间，三项都点得中。带设备头像时文字会被
# 挤右，故留 +85 作兜底。点完用 send_target_device() 验证闭环。
_DROP_FIRST_DY = 26
_DROP_ROW = 36
_DROP_NAME_X_OFF = (71, 85)
# 浮层收起判定：亮度回到「展开前基线」附近（展开前后差 ~10，取 2.5 抗噪声）。
_DROP_CLOSE_DELTA = 2.5
# 下拉展开判定：检测矩形取「选择器正下方一整块面板区域」，展开前后亮度差
# 实测约 10~12（闭合 ~50.8 / 展开 ~61.5），取 4 作阈值足够抗噪声。
_DROP_PROBE_DX = 75
_DROP_PROBE_DY = 23
_DROP_PROBE_W = 150
_DROP_PROBE_H = 50
_DROP_OPEN_DELTA = 4.0


def _activate_connect() -> bool:
    """把 Connect 置前（SILENT 模式下仅在选机这几秒临时置前，选完还原焦点）。"""
    if _IS_WIN:
        return ax.activate()
    r = subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % APP],
                       capture_output=True, text=True, timeout=30)
    return r.returncode == 0


def _screen_mean_win(x: int, y: int, w: int, h: int) -> float | None:
    """Windows 版亮度采样: PIL ImageGrab 一次截矩形; PIL 缺失退 GDI GetPixel
    稀采样 (步长 3, 150x50 矩形 ~830 点, 判开合足够)。坐标系是物理像素
    (bconnect_uia 导入时已声明 DPI 感知), 与 UIA 矩形一致。"""
    try:
        from PIL import ImageGrab
        img = ImageGrab.grab(bbox=(x, y, x + w, y + h), all_screens=True)
        hist = img.convert("L").histogram()
        total = sum(i * v for i, v in enumerate(hist))
        n = sum(hist)
        return total / n if n else None
    except Exception:  # noqa: BLE001
        pass
    try:
        gdi32 = ctypes.windll.gdi32
        hdc = ctypes.windll.user32.GetDC(0)
        total = cnt = 0
        for yy in range(y, min(y + h, y + 60), 3):
            for xx in range(x, x + w, 3):
                c = gdi32.GetPixel(hdc, xx, yy) & 0xFFFFFF
                total += ((c & 0xFF) * 114 + ((c >> 8) & 0xFF) * 587
                          + ((c >> 16) & 0xFF) * 299) // 1000
                cnt += 1
        ctypes.windll.user32.ReleaseDC(0, hdc)
        return total / cnt if cnt else None
    except Exception:  # noqa: BLE001
        return None


def _screen_mean(x: int, y: int, w: int, h: int) -> float | None:
    """截一小块屏幕，返回平均亮度（判断下拉是否真的展开了）。

    为什么需要：下拉是 JS 浮层，AX 树里完全看不到（展开前后树结构一模一样），
    而刚切到发送页时注入的点击会被吞掉（浮层不出现）。与其猜 sleep 多长，不如
    用「展开前后这块矩形亮度变了没有」做确定性判断。macOS 截图为 BMP，纯
    Python 解码；Windows 走 PIL/GDI。
    """
    if _IS_WIN:
        return _screen_mean_win(x, y, w, h)
    path = os.path.join(tempfile.gettempdir(), "bc_probe.bmp")
    try:
        subprocess.run(["screencapture", "-x", "-R", "%d,%d,%d,%d" % (x, y, w, h),
                        "-t", "bmp", path], check=False, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(path, "rb") as f:
            data = f.read()
    except Exception:  # noqa: BLE001
        return None
    if len(data) < 54:
        return None
    off = int.from_bytes(data[10:14], "little")
    wpx = int.from_bytes(data[18:22], "little", signed=True)
    hpx = int.from_bytes(data[22:26], "little", signed=True)
    bpp = int.from_bytes(data[28:30], "little")
    if wpx <= 0 or hpx == 0 or bpp not in (24, 32) or off <= 0:
        return None
    step = bpp // 8
    n = wpx * step
    stride = (n + 3) // 4 * 4
    total = cnt = 0
    for r in range(abs(hpx)):
        row = data[off + r * stride: off + r * stride + n]
        if len(row) < n:
            break
        for i in range(0, n, step):
            # BMP 是 BGR(A)
            total += (row[i] * 114 + row[i + 1] * 587 + row[i + 2] * 299) // 1000
            cnt += 1
    return total / cnt if cnt else None


def _wait_target(want: str, timeout: float = 0.9) -> bool:
    """轮询读回目标机名，直到等于 want 或超时。"""
    deadline = time.time() + timeout
    while True:
        if ax.send_target_device() == want:
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.05)


def _settle_target(prev: str, timeout: float = 0.6) -> str:
    """点完一行后读回目标机名：轮询到读数变化或超时，返回最后一次读数。"""
    deadline = time.time() + timeout
    last = ax.send_target_device()
    while time.time() < deadline:
        cur = ax.send_target_device()
        if cur and cur != prev:
            return cur
        last = cur or last
        time.sleep(0.05)
    return last


_OCR_BIN = os.path.expanduser("~/.bambudeck/bin/deck_ocr")
_OCR_SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ocr_text.swift")


def _ocr_bin() -> str | None:
    """本地 OCR 可执行文件；首次用时用 swiftc 编译到 ~/.bambudeck/bin（不进仓库）。

    macOS 自带的 Vision 框架，纯本地识别，截图不出本机。没有 swiftc（未装 Xcode
    命令行工具）时返回 None，调用方退回逐行试。
    """
    if os.path.exists(_OCR_BIN):
        return _OCR_BIN
    if not (os.path.exists("/usr/bin/swiftc") and os.path.exists(_OCR_SRC)):
        return None
    try:
        os.makedirs(os.path.dirname(_OCR_BIN), exist_ok=True)
        tmp = _OCR_BIN + ".tmp"
        r = subprocess.run(["/usr/bin/swiftc", "-O", "-o", tmp, _OCR_SRC],
                           capture_output=True, text=True, timeout=180)
        if r.returncode != 0 or not os.path.exists(tmp):
            return None
        os.replace(tmp, _OCR_BIN)
        return _OCR_BIN
    except Exception:  # noqa: BLE001
        return None


def _png_size(path: str) -> tuple[int, int]:
    """读 PNG 宽高（screencapture 产出）；读不出回 (0, 0)。"""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return (int.from_bytes(head[16:20], "big"),
                    int.from_bytes(head[20:24], "big"))
    except Exception:  # noqa: BLE001
        pass
    return 0, 0


def _norm_name(s: str) -> str:
    return "".join(s.split()).lower()


def _match_row(rows: list[tuple[str, int, int]],
               want: str) -> tuple[int, int] | None:
    """从 OCR 出的下拉行里找目标机名，返回要点的屏幕坐标 (x, y)。"""
    target = _norm_name(want)
    if not target:
        return None
    for text, x, y in rows:
        if _norm_name(text) == target:
            return x, y
    # 识别偶尔多/少一个标点；包含匹配必须唯一，避免「A1」误中「A1 mini」。
    fuzzy = [(x, y) for text, x, y in rows if target in _norm_name(text)]
    return fuzzy[0] if len(fuzzy) == 1 else None


def _ocr_rows_win(group: dict, row_limit: int) -> list[tuple[str, int, int]]:
    """Windows 读下拉选项, 两级:
      1) UIA 树原生选项 (bconnect_uia.dropdown_options) —— 若 Chromium a11y 把
         浮层映射进了树, 这是最快路径, 零视觉零坐标猜测;
      2) PIL 截下拉区域 + 云端视觉模型问「每行文字和行中心坐标」(bconnect_vision,
         MiniMax/Qwen-VL, ~/.bambudeck/models.json 配 key 才可用)。
    都不行返回空列表, 调用方退回逐行几何点击 (点完读回机名验证, 不靠视觉)。
    坐标一律换算回屏幕物理像素; _snap_row 还会把命中点吸附到已知行几何上。
    """
    try:
        opts = ax.dropdown_options(group, row_limit=row_limit)
    except Exception:  # noqa: BLE001
        opts = []
    if opts:
        return [(o["name"], int(o["x"]), int(o["y"])) for o in opts]
    rx = int(group["x"] - 24)
    ry = int(group["y"] + group["h"] - 4)
    rw = int(group["w"] + 48)
    rh = int(_DROP_FIRST_DY + max(3, row_limit) * _DROP_ROW + 10)
    path = os.path.join(tempfile.gettempdir(), "bc_dropdown_win.png")
    try:
        from PIL import ImageGrab
        import bconnect_vision as vision
        if not (vision.resolve_model("vision").get("api_key")):
            return []
        ImageGrab.grab(bbox=(rx, ry, rx + rw, ry + rh),
                       all_screens=True).save(path, "PNG")
        ans = vision.ask_vision(path, (
            "这是打印机设备下拉列表的截图。列出每个选项的文字和该行中心的像素"
            "坐标，只回 JSON 数组 [{\"t\":\"机名\",\"x\":中心x,\"y\":中心y},"
            " ...]，不要其它文字。"))
    except Exception:  # noqa: BLE001
        return []
    rows: list[tuple[str, int, int]] = []
    for m in re.finditer(r"\{[^{}]*\}", ans or ""):
        try:
            item = json.loads(m.group(0))
        except ValueError:
            continue
        t = str(item.get("t") or "").strip()
        x, y = item.get("x"), item.get("y")
        if t and isinstance(x, (int, float)) and isinstance(y, (int, float)):
            rows.append((t, rx + int(x), ry + int(y)))
    return rows


def _ocr_dropdown_rows(group: dict, row_limit: int) -> list[tuple[str, int, int]]:
    """截图已展开的下拉浮层 + 本地 OCR，返回 [(文字, 屏幕 x, 屏幕 y)]。

    读不到（截图没权限 / 没有 swiftc / 识别失败）返回空列表，调用方退回逐行试。
    一次读取覆盖整个列表，打印机再多也只花一次 OCR 的时间（2026-10-25 用户反馈：
    逐行试选在机器多时太慢）。Windows 走 _ocr_rows_win (UIA 原生/云端视觉)。
    """
    if _IS_WIN:
        return _ocr_rows_win(group, row_limit)
    binary = _ocr_bin()
    if binary is None:
        return []
    rx = int(group["x"] - 24)
    ry = int(group["y"] + group["h"] - 4)
    rw = int(group["w"] + 48)
    rh = int(_DROP_FIRST_DY + max(3, row_limit) * _DROP_ROW + 10)
    path = os.path.join(tempfile.gettempdir(), "bc_dropdown.png")
    try:
        subprocess.run(["screencapture", "-x", "-R",
                        "%d,%d,%d,%d" % (rx, ry, rw, rh), "-t", "png", path],
                       check=False, timeout=5,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        r = subprocess.run([binary, path], capture_output=True, text=True,
                           timeout=15)
    except Exception:  # noqa: BLE001
        return []
    if r.returncode != 0:
        return []
    # Retina：截图是 2x 像素，-R 是逻辑点，按「图片宽 / 区域宽」换算回屏幕坐标。
    wpx, _hpx = _png_size(path)
    scale = (wpx / rw) if wpx and rw else 1.0
    rows: list[tuple[str, int, int]] = []
    for line in r.stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        text = str(item.get("t") or "").strip()
        if not text:
            continue
        cx = rx + int((item["x"] + item["w"] / 2) / scale)
        cy = ry + int((item["y"] + item["h"] / 2) / scale)
        rows.append((text, cx, cy))
    return rows


def _snap_row(group: dict, row_limit: int,
              hit: tuple[int, int]) -> tuple[int, int] | None:
    """把 OCR 命中点对到「第 k 行」的已知几何上；对不上就放弃这个命中。

    OCR 区域比下拉本身高时（机器数少于 row_limit），区域底部会盖到页面其它内容，
    OCR 可能读到下面的文字。这里只接受落在「选择器下方第 0..row_limit-1 行」且
    偏离行中心不超过半行高的命中，点击一律落在行中心——绝不点到下拉以外（比如
    「发送」按钮），这是防误派的硬保险。
    """
    x, y = hit
    gx, gw = group["x"], group["w"]
    if not (gx <= x <= gx + gw):
        return None
    origin = group["y"] + group["h"]
    k = round((y - origin - _DROP_FIRST_DY) / _DROP_ROW)
    if k < 0 or k >= row_limit:
        return None
    row_y = origin + _DROP_FIRST_DY + k * _DROP_ROW
    if abs(row_y - y) > _DROP_ROW / 2:
        return None
    return int(x), int(row_y)


def _dropdown_open(probe: tuple, base: float | None) -> bool | None:
    """下拉浮层现在是否还开着；None = 判断不了（截图不可用）。"""
    if base is None:
        return None
    cur = _screen_mean(*probe)
    if cur is None:
        return None
    return abs(cur - base) > _DROP_CLOSE_DELTA


def _click_row(group: dict, probe: tuple, base: float | None, idx: int,
               before: str) -> str | None:
    """点下拉第 idx 行的名字，返回这一下选中的目标机名；None = 没选中任何行。

    只看「名字变没变」不够：点到当前已选中的那台时名字不会变，但下拉确实收起、
    选择也确实生效了。所以用「浮层收起」当作选中信号，名字只用于返回结果。
    """
    ty = group["y"] + group["h"] + _DROP_FIRST_DY + idx * _DROP_ROW
    for xoff in _DROP_NAME_X_OFF:
        if not ax.click_at(group["x"] + xoff, ty):
            continue
        name = _settle_target(before)
        if _dropdown_open(probe, base) is False:
            return name
        if name and name != before:
            return name  # 读数已变，按选中处理（浮层状态读不准时的兜底）
    return None


def _open_dropdown(cx: float, cy: float, group: dict) -> bool:
    """点 chevron 展开下拉，并确认浮层真的出现了（没开就重点一次）。

    AX 树对下拉浮层完全无感（展开前后节点数一模一样），所以用像素亮度判断：
    浮层盖住选择器下方那块区域后亮度明显变化。刚跳转到发送页时第一次点击常被
    页面吞掉，靠这个检测才能既不误判成功、也不用固定死等 1.5s。
    返回 (是否已展开, 展开前基线亮度)。基线给调用方判断「后来是不是又被关上了」。
    """
    probe = (int(group["x"] + _DROP_PROBE_DX),
             int(group["y"] + group["h"] + _DROP_PROBE_DY),
             _DROP_PROBE_W, _DROP_PROBE_H)
    base = _screen_mean(*probe)
    if base is None:
        # 截不到图（缺屏幕录制权限等）→ 退回固定等待，行为与旧版一致
        if not ax.click_at(cx, cy):
            return False, None
        time.sleep(0.45)
        return True, None
    for _attempt in range(2):
        if not ax.click_at(cx, cy):
            return False, base
        # 必须是「稳定」的变化：发送页刚出现时那块区域自身也在变化（浮层/加载态
        # 淡出），单次采样跳变会把「页面自己在动」误判成「下拉展开了」——2026-10-24
        # 实测就栽在这里（判成已展开，接着去点选项，其实浮层根本没开）。
        deadline = time.time() + 0.8
        hits = prev = 0
        while time.time() < deadline:
            time.sleep(0.05)
            cur = _screen_mean(*probe)
            if cur is None:
                continue
            if abs(cur - base) > _DROP_OPEN_DELTA:
                hits += 1
                if hits >= 2 and abs(cur - prev) < 2.0:
                    time.sleep(0.1)  # 浮层画完再点，避免点在展开动画中间
                    return True, base
            else:
                hits = 0
            prev = cur
    return False, base


def _stable_selector(timeout: float = 2.0) -> dict | None:
    """等设备选择器几何稳定后再返回。

    发送弹窗是「缩放动画进场」：刚出现的那一刻 AX 读到的是动画中间态（实测组
    尺寸 225x46@(577,425)，动画结束才是 320x65@(465,382)），照中间态坐标点必然
    点空——2026-10-24 全流程失败的真正原因（下拉也确实没打开过）。连续两次读数
    一致即视为稳定，通常 0.2~0.4s，比固定 sleep 1.5s 快且不靠猜。
    """
    prev: dict | None = None
    deadline = time.time() + timeout
    while time.time() < deadline:
        cur = ax.selector_frame()
        if cur and prev and _same_frame(prev, cur):
            return cur
        prev = cur
        time.sleep(0.05)
    return prev or ax.selector_frame()


def _same_frame(a: dict, b: dict) -> bool:
    ga, gb = a.get("group") or {}, b.get("group") or {}
    if any(abs((ga.get(k) or 0) - (gb.get(k) or 0)) > 0.5
           for k in ("x", "y", "w", "h")):
        return False
    ca, cb = a.get("chevron"), b.get("chevron")
    if bool(ca) != bool(cb):
        return False
    if ca and cb and (abs(ca["x"] - cb["x"]) > 0.5 or abs(ca["y"] - cb["y"]) > 0.5):
        return False
    return True


def select_device(want_name: str, cur_target: str | None = None) -> bool:
    """在发送页把打印目标切到 want_name（自动选机）。

    纯 AX 读不到下拉选项（Electron 自定义下拉不映射成 AX 菜单项，AXShowMenu/AXRows/
    children 全空），而且**下拉行序不固定**（2026-10-25 实测首项是「嘉兴」，不是名称
    升序该排最前的「123」；用户反馈顺序会变）。所以：

      1. AX 读当前目标机名——已匹配直接 True，零点击（cur_target 可传入省一次读）；
      2. 临时把 Connect 置前（CGEvent 点击注入的是「该坐标最顶层窗口」，必须 Connect 在最前）；
      3. 等弹窗进场动画结束、AX 几何读数稳定，点 chevron_down 展开下拉（并确认真的展开）；
      4. **快路径**：截图下拉浮层 + 本地 OCR（macOS Vision）一次性读出整列机名，
         名字匹配到就直接点那一行；机器再多也只花一次读取；
      5. **兜底**（OCR 不可用/没匹配上）：从第 0 行起逐行点，每点一次立即 AX 读回目标
         机名，等于 want_name 即成功；选到别的机器就重新展开再试下一行，行数上限取
         云端设备数，点回已见过的机器即视为列表到底；
      6. 选完还原焦点。
    全程不上传任何画面：OCR 是 macOS 自带框架，本地跑。浮层开合判断不了（截图不可用）
    时直接放弃，绝不盲点——点空可能误触页面其它控件。失败返回 False，调用方走
    verify-and-abort（绝不误派）。
    """
    if not want_name:
        return False
    cur = ax.send_target_device() if cur_target is None else cur_target
    if cur == want_name:
        return True
    # 云端设备清单只用来确认「目标机存在」和上行数上限，不决定下拉行序。
    names = sorted((d.get("name") or "").strip()
                   for d in cloud.device_list() if (d.get("name") or "").strip())
    if want_name not in names:
        return False
    row_limit = max(1, len(names))

    def _geom(frame: dict) -> tuple[dict, dict, float, float, tuple]:
        """由选择器几何算出 (group, chevron, chevron 点击点, 检测矩形)。"""
        g = frame["group"]
        ch = frame.get("chevron")
        _cx = ch["x"] if ch else g["x"] + g["w"] - 24
        _cy = ch["y"] if ch else g["y"] + g["h"] / 2
        pr = (int(g["x"] + _DROP_PROBE_DX),
              int(g["y"] + g["h"] + _DROP_PROBE_DY),
              _DROP_PROBE_W, _DROP_PROBE_H)
        return g, ch, _cx, _cy, pr

    # 坐标点击前临时置前 Connect（SILENT 下选完还原焦点）
    prev = _frontmost_app()
    need_restore = SILENT and prev and prev != APP
    try:
        # 置前 + 等窗口真正拿到焦点：只等「app 在最前」不够——刚激活时窗口还没
        # key，注入的点击会被系统吞掉（下拉点不开，2026-10-24 实测栽在这里）。
        _activate_connect()
        if ax.fast_available():
            deadline = time.time() + 2.5
            while time.time() < deadline and not ax.app_ready():
                time.sleep(0.05)
        else:
            time.sleep(0.8)
        frame = _stable_selector()
        if not frame:
            return False
        group, chevron, cx, cy, probe = _geom(frame)
        # 展开下拉，并用「这块矩形亮度变没变」确认浮层真的出来了：页面刚就绪时
        # 注入的点击可能被吞，点完就探、没开就重点一次，不靠固定 sleep。
        opened, base = _open_dropdown(cx, cy, group)
        if not opened:
            # 坐标可能仍是动画中间态 → 重读稳定几何再来一轮
            frame = _stable_selector(0.5) or frame
            group, chevron, cx, cy, probe = _geom(frame)
            opened, base = _open_dropdown(cx, cy, group)
            if not opened:
                return False
        # 快路径：一次截图 + 本地 OCR 读出整个下拉列表，直接点匹配的那一行。
        # 打印机多时也只花一次读取，不用逐行试（2026-10-25 用户反馈）。
        rows = _ocr_dropdown_rows(group, row_limit)
        hit = _match_row(rows, want_name) if rows else None
        snap = _snap_row(group, row_limit, hit) if hit is not None else None
        if snap is not None:
            if ax.click_at(snap[0], snap[1]) and _wait_target(want_name, 0.9):
                return True
            # 没点中（识别偏差/点击被吞）：按浮层状态决定是否重开，再走逐行兜底。
            state = _dropdown_open(probe, base)
            if state is None:
                return False
            if state is False:
                frame = _stable_selector(1.0) or frame
                group, chevron, cx, cy, probe = _geom(frame)
                opened, base = _open_dropdown(cx, cy, group)
                if not opened:
                    return False

        # 兜底：逐行试。点「头像/空区」这类不可选项时下拉不会收起（Electron 下拉只在
        # 点项名字或下拉外才收），所以同一次展开内可以往后换 x 或换行；只有真的选中
        # （浮层收起）才需要重新展开。Esc 会关掉发送弹窗、点中性区会撞到返回按钮，
        # 两者都不能用来复位。
        seen: list[str] = []
        need_open = False
        for idx in range(row_limit):
            if need_open:
                frame = _stable_selector(1.0) or frame
                group, chevron, cx, cy, probe = _geom(frame)
                opened, base = _open_dropdown(cx, cy, group)
                if not opened:
                    return False
            picked = _click_row(group, probe, base, idx, cur)
            if picked == want_name:
                return True
            if picked is not None:
                if picked in seen:
                    return False  # 点回见过的机器：行号越界或坐标错位，别猜
                seen.append(picked)
                cur = picked
                need_open = True
                continue
            state = _dropdown_open(probe, base)
            if state is True:
                need_open = False  # 浮层还开着、这行没点中 → 直接试下一行
                continue
            # 浮层已收起却没读到机名，或根本判断不了 → 不盲点下一行
            return False
        return False
    finally:
        if need_restore:
            _restore_frontmost(prev)


# ---------------------------------------------------------------- 本地 OCR
# 2026-10-29: 云端视觉 (MiniMax) 配额 429 把换盘链路整个卡死 —— 派单不能
# 依赖一个外部配额。Windows 10+ 自带 OCR 引擎 (Windows.Media.Ocr), 用系统
# PowerShell 直调 WinRT: 零安装、零配额、零上传, 和 Mac 侧「OCR 是系统自带
# 框架, 本地跑」同一个设计。视觉从此只是可选兜底。
_WIN_OCR_PS = (
    # WinRT 类型必须用带限定的字面量 (2026-10-29 盒子实测): 裸写
    # [Windows.Media.Ocr.OcrEngine] 会报「找不到类型」, 加
    # ,Windows.Foundation,ContentType=WindowsRuntime 才投影得动。
    "$ErrorActionPreference='Stop';"
    "$Path='__PATH__';"
    "try{Add-Type -AssemblyName System.Runtime.WindowsRuntime}"
    "catch{Write-Output 'ERR: no rt';exit};"
    "$m=[System.WindowsRuntimeSystemExtensions].GetMethods()|"
    "Where-Object{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and "
    "$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'}"
    "|Select-Object -First 1;"
    "if(-not $m){Write-Output 'ERR: no asTask';exit};"
    "function Await($op,$t){$task=$m.MakeGenericMethod($t).Invoke($null,@($op));"
    "$task.Wait();$task.Result};"
    "$RT=',Windows.Foundation,ContentType=WindowsRuntime';"
    "$ocr=$null;"
    "try{$eng=[Type]('Windows.Media.Ocr.OcrEngine'+$RT);"
    "$lng=[Type]('Windows.Globalization.Language'+$RT);"
    "$zh=[Activator]::CreateInstance($lng,[object[]]@('zh-Hans'));"
    "$ocr=$eng::TryCreateFromLanguage($zh)}catch{};"
    "if(-not $ocr){try{$ocr=$eng::TryCreateFromUserProfileLanguages()}catch{}};"
    "if(-not $ocr){Write-Output 'ERR: no engine';exit};"
    "try{"
    "$sf=[Type]('Windows.Storage.StorageFile'+$RT);"
    "$file=Await ($sf::GetFileFromPathAsync($Path)) $sf;"
    "$fam=[Type]('Windows.Storage.FileAccessMode'+$RT);"
    "$strm=[Type]('Windows.Storage.Streams.IRandomAccessStream'+$RT);"
    "$stream=Await ($file.OpenAsync($fam::Read)) $strm;"
    "$bd=[Type]('Windows.Graphics.Imaging.BitmapDecoder'+$RT);"
    "$dec=Await ($bd::CreateAsync($stream)) $bd;"
    "$sb=[Type]('Windows.Graphics.Imaging.SoftwareBitmap'+$RT);"
    "$bmp=Await ($dec.GetSoftwareBitmapAsync()) $sb;"
    "$orr=[Type]('Windows.Media.Ocr.OcrResult'+$RT);"
    "$res=Await ($ocr.RecognizeAsync($bmp)) $orr;"
    "$out=@();"
    # OcrLine 没有 BoundingRect (只有 OcrWord 有, 盒子实测全 0) —— 行矩形
    # 按行内词包围盒取并集。
    "foreach($ln in $res.Lines){$x0=1e9;$y0=1e9;$x1=-1.0;$y1=-1.0;"
    "foreach($wd in $ln.Words){$r=$wd.BoundingRect;"
    "if($r.X -lt $x0){$x0=$r.X};if($r.Y -lt $y0){$y0=$r.Y};"
    "$e=$r.X+$r.Width;if($e -gt $x1){$x1=$e};"
    "$b=$r.Y+$r.Height;if($b -gt $y1){$y1=$b}};"
    "if($x1 -lt 0){continue};"
    "$out+=[pscustomobject]@{t=$ln.Text;x=[int](($x0+$x1)/2);"
    "y=[int](($y0+$y1)/2);w=[int]($x1-$x0);h=[int]($y1-$y0)}};"
    "if($out.Count -eq 0){Write-Output '[]'}else{"
    "Write-Output ($out|ConvertTo-Json -Compress -Depth 3)}"
    "}catch{Write-Output ('ERR: '+$_.Exception.Message)}"
)


def _win_ocr_parse(out: str) -> list[dict] | None:
    """PowerShell OCR 输出 -> [{name,x,y,w,h}]; None = 引擎不可用。"""
    out = (out or "").strip()
    if not out or out.startswith("ERR") or out == "[]":
        return None if out.startswith("ERR") else []
    try:
        arr = json.loads(out)
    except Exception:  # noqa: BLE001
        return None
    if isinstance(arr, dict):
        arr = [arr]
    res = []
    for it in arr:
        t = str(it.get("t") or "").strip()
        try:
            x, y = int(it["x"]), int(it["y"])
        except (KeyError, TypeError, ValueError):
            continue
        if t:
            res.append({"name": t, "x": x, "y": y,
                        "w": int(it.get("w") or 0), "h": int(it.get("h") or 0)})
    return res


def _win_ocr_lines(path: str) -> list[dict] | None:
    """本地 OCR 一张图。返回行列表 (位图像素 = 屏幕物理像素, ImageGrab
    截图与 OcrResult 包围盒同坐标系); None = 引擎不可用 (没装语言包等)。
    """
    import base64
    script = _WIN_OCR_PS.replace("__PATH__", path.replace("'", "''"))
    enc = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    try:
        r = subprocess.run(
            ["powershell", "-NoProfile", "-NonInteractive",
             "-EncodedCommand", enc],
            capture_output=True, text=True, timeout=40)
        return _win_ocr_parse(r.stdout)
    except Exception as e:  # noqa: BLE001
        _log("local ocr fail:", str(e)[:80])
        return None


def _win_ocr_region(shot_path: str, box: tuple | None) -> list[dict] | None:
    """OCR 截图的中央区域并平移回屏幕坐标 (2026-10-29 提速)。

    全屏 1920x1080 识别 ~2s, Connect 弹窗恒居中且不到 1/4 像素 —— 分类
    和选机锚定只关心弹窗内容, 收窄后省一半多时间。坐标平移后与全屏结果
    同坐标系, 下游 (picker 命中行/标题锚定) 无感。box=None 或裁剪失败
    返回 None, 调用方退全屏。
    """
    if not box:
        return None
    try:
        from PIL import Image
        w, h = Image.open(shot_path).size
        l, t = max(0, box[0]), max(0, box[1])
        r, b = min(w, box[2]), min(h, box[3])
        if r - l < 60 or b - t < 60:
            return None
        crop = shot_path + ".cls.png"
        Image.open(shot_path).crop((l, t, r, b)).save(crop, "PNG")
    except Exception:  # noqa: BLE001
        return None
    lines = _win_ocr_lines(crop)
    if not lines:
        return lines  # 引擎不可用 (None) 或区域里没字 ([]) 都如实上抛
    return [{"name": o["name"], "x": o["x"] + l, "y": o["y"] + t,
             "w": o.get("w", 0), "h": o.get("h", 0)} for o in lines]


def _win_ocr_dialog_lines(shot_path: str, frame: dict | None) -> list[dict] | None:
    """裁弹窗区域放大 2.5x 再 OCR —— 正文核对专用。

    小字号 CJK 全屏 OCR 会拆成部首 (2026-10-29 盒子实测: 正文
    「您将导入文件 "xxx.3mf"」 -> 「扌寻 与 ． 文 亻牛 au」), 文件名核对
    全靠这份放大版。区域: UIA 钮对矩形反推 (正文恒在钮上方); 钮对拿不到
    (树掏空是常态) 就取屏幕正中大块 —— Connect 弹窗恒居中。
    """
    try:
        from PIL import Image
        w, h = Image.open(shot_path).size
    except Exception:  # noqa: BLE001
        return None
    if frame:
        l = min(frame["cancel"][0], frame["confirm"][0]) - 330
        t = min(frame["cancel"][1], frame["confirm"][1]) - 175
        r = max(frame["cancel"][2], frame["confirm"][2]) + 35
        b = max(frame["cancel"][3], frame["confirm"][3]) + 40
    else:
        cx, cy = w // 2, h // 2
        l, t, r, b = cx - 380, cy - 260, cx + 380, cy + 220
    try:
        im = Image.open(shot_path).crop(
            (max(0, l), max(0, t), min(w, r), min(h, b)))
        resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
        im = im.resize((im.width * 5 // 2, im.height * 5 // 2), resample)
        # 2026-10-29 盒子实测: im.save() 按扩展名猜格式, ".zoom" 直接
        # ValueError("unknown file extension") —— 落盘必须是标准后缀。
        zoom = shot_path + ".zoom.png"
        im.save(zoom, "PNG")
        return _win_ocr_lines(zoom)
    except Exception:  # noqa: BLE001
        return None  # 裁剪/放大失败不致命: 外层还有全屏 OCR 和流程位置放行


_CHEVRON_TAIL = re.compile(r"[\s·.,:]*[vV∨⌄˄]$")


def _win_trim_chevron(text: str) -> str:
    """摘掉 OCR 读到的下拉框 chevron 尾巴。

    2026-10-29 盒子实测: 发送弹窗下拉当前值「123」被 zh-Hans OCR 读成
    「123 v」—— chevron 那个小三角被当成字母 v 拼在行尾。机名比对是
    **长度敏感**的同位比对 (长度不同 = 另一台机, 防误派), 于是「123 v」
    对「123」直接 0 分 -> 判成「认不出任何已知机器」-> 选择器几何拿不到
    -> 退到 UIA 的过期几何 -> 裁出来的图两个字都没有 -> 选机失败。
    只摘行尾的孤立 chevron 字符, 不动名字中间的内容。
    """
    return _CHEVRON_TAIL.sub("", (text or "").strip()).strip()


def _win_lines_hit_printer(ocr, known: dict, want_name: str) -> str:
    """OCR 行里有没有哪行像一台已知的机器 -> 返回那行原文。

    给「发送弹窗」分类用: 发送弹窗的下拉框当前值必然是某台已知的机器,
    导入弹窗里只有机型/耗材/时长文本 (实测 'A1'/'PLA'/'11m'), 撞不上
    (除非机器真的叫 A1 —— 精确机器名才有这个风险, 现有命名没有)。
    """
    if not ocr:
        return ""
    names = list((known or {}).keys())
    if want_name and want_name not in names:
        names.append(want_name)
    for l in ocr:
        for n in names:
            if _name_score(_win_trim_chevron(l["name"]), n) >= 0.8:
                return l["name"]
    return ""


def _win_file_in_lines(ocr, base: str) -> bool:
    """OCR 文本里核对得到文件名 (主干比对; 小数点和下划线 OCR 时有时不回,
    一并归一掉)。"""
    if not ocr:
        return False

    def squash(s: str) -> str:
        return re.sub(r"[ \t._-]+", "", s or "").lower()

    stem = (base or "").rsplit(".", 1)[0] or (base or "")
    key = squash(stem)
    if len(key) < 4:
        key = squash(base)
    blob = "".join(squash(l["name"]) for l in ocr)
    return bool(key) and key in blob


def _win_classify_local(texts, known: dict, want_name: str) -> str:
    """零成本弹窗分类: 'send' / '' (判不了, 交给下一级)。

    发送弹窗独有、导入弹窗没有的 UIA 特征: 设备选择器结构 (chevron_down
    组, 有宽度守卫) 和下拉框当前值。匹配吃精确(1.0)和机型前缀(0.90),
    不吃 0.8 同位模糊 —— texts 是树里读的权威值, 没有视觉那种同音错字,
    模糊只会白白放大「机型文本撞机名」的风险 (导入弹窗里躺着「A1」)。
    """
    try:
        if ax.selector_frame():
            return "send"
    except Exception:  # noqa: BLE001
        pass
    names = list((known or {}).keys())
    if want_name and want_name not in names:
        names.append(want_name)
    for t in (texts or []):
        tn = _norm_printer_name(str(t))
        if not tn:
            continue
        for n in names:
            if _name_score(tn, n) >= 0.90:
                return "send"
    return ""


def _win_rect_of_current(known: dict, want_name: str):
    """发送弹窗下拉框当前值的矩形 [l,t,r,b] (树里找得到 Text 时)。"""
    names = list((known or {}).keys())
    if want_name and want_name not in names:
        names.append(want_name)
    best, best_key = None, (0.0, 0)
    try:
        items = ax.text_items()
    except Exception:  # noqa: BLE001
        return None
    for it in items:
        t = str(it.get("text") or "")
        r = it.get("rect")
        if not t or not r or len(r) != 4:
            continue
        for n in names:
            s = _name_score(t, n)
            key = (s, len(_norm_printer_name(n)))
            if key > best_key:
                best_key, best = key, r
    return best if best_key[0] >= 0.8 else None


def _win_classify_dialog(img_path: str) -> dict:
    """截图 + 视觉模型读弹窗内容 -> {kind, body, buttons, printers, selected}。

    弹窗正文不进 UIA 树 (2026-10-29 实测), 视觉是唯一内容来源。读不出/
    模型不可用一律返回 kind=unknown, 调用方 fail-closed 取消。

    printers 只填「打印机下拉框里当前显示的那个机名」—— 视觉会把机型
    (A1)、AMS 槽位 (B2) 一起当机名读出来, 混进列表就会误判; 权威核对
    一律走 UIA texts (下拉框当前值在树里, 零 OCR 错字风险)。
    """
    try:
        import bconnect_vision as vision
        prompt = (
            "这是 Bambu Connect 打印软件弹窗的截图。只输出一个 JSON 对象, "
            "不要输出其它文字: {\"kind\": \"导入|打印|选择|其他\", "
            "\"body\": \"弹窗正文逐字原文(标题下的说明文字, 含文件名要原样保留)\", "
            "\"buttons\": [\"弹窗内按钮文字\"], "
            "\"printers\": [\"打印机下拉框里当前显示的那个机名, 逐字; 看不出就空数组\"], "
            "\"selected\": \"能看出被选中/高亮的打印机名, 否则空字符串\"}。"
            "kind 判定: 正文含『您将导入文件』=导入; 标题/正文含『发送打印"
            "任务至』(打印机下拉+发送按钮)=打印; 列出多台打印机网格供点选"
            "=选择。printers 只填下拉框当前值, 不要填机型(A1)或耗材槽位(B2)。"
            "逐字引用, 不要推断补全。")
        js = vision.ask_vision(img_path, prompt)
        m = re.search(r"\{.*\}", js or "", re.S)
        if not m:
            return {"kind": "unknown", "raw": (js or "")[:200]}
        return json.loads(m.group(0))
    except Exception as e:  # noqa: BLE001
        return {"kind": "unknown", "raw": str(e)[:200]}


def _win_parse_options(js: str) -> list[dict]:
    """视觉返回的下拉选项 -> [{name, x, y}]。

    容忍几种形状: [{"name":..,"x":..,"y":..}] / [{"name":..,"point":[x,y]}]
    / ["名字", ...] (无坐标, 无法点, 丢掉)。
    """
    out = []
    m = re.search(r"\{.*\}", js or "", re.S)
    arr = None
    if m:
        try:
            obj = json.loads(m.group(0))
            arr = obj.get("options") if isinstance(obj, dict) else obj
        except Exception:  # noqa: BLE001
            arr = None
    if arr is None:
        m2 = re.search(r"\[.*\]", js or "", re.S)
        if m2:
            try:
                arr = json.loads(m2.group(0))
            except Exception:  # noqa: BLE001
                arr = None
    for it in arr or []:
        if isinstance(it, str):
            continue
        if not isinstance(it, dict):
            continue
        name = str(it.get("name") or it.get("text") or "").strip()
        x = it.get("x")
        y = it.get("y")
        if x is None or y is None:
            pt = it.get("point") or it.get("center")
            if isinstance(pt, (list, tuple)) and len(pt) >= 2:
                x, y = pt[0], pt[1]
        try:
            x = int(float(x))
            y = int(float(y))
        except Exception:  # noqa: BLE001
            continue
        if not name:
            continue
        out.append({"name": name, "x": x, "y": y})
    return out


def _norm_printer_name(s: str) -> str:
    """机名归一: 去掉状态后缀, 再去掉全部空白 + 转小写。

    对齐 Mac 侧 _norm_name 的做法: 云端名「拓竹 A1 宇树」和 Connect 界面
    显示的「拓竹A1宇树」只差空格, 不去空白就永远核不上; 大小写同理。
    状态后缀可能是「宇树 在线」也可能「宇树在线」, 所以先把空白全去掉
    再剥后缀。
    """
    s = "".join((s or "").split()).lower()
    for suf in ("在线", "离线", "打印中", "待机", "等待", "异常"):
        if s.endswith(suf) and len(s) > len(suf):
            return s[: -len(suf)]
    return s


def _name_similarity(a: str, b: str) -> float:
    """两个机名的相似度 (同位字符占比)。视觉读名有同音错字 (实测
    『拓竹A1宇树』->『拓竹A1字树』), 同位比对能把这种错字救回来。

    前缀**不算**满分: 「拓竹A1宇树2」是另一台机, 按前缀放行会误派。
    长度必须相同 —— OCR 错字是**替换**不是插入, 长度不同就是另一台机。
    """
    a = (a or "").strip()
    b = (b or "").strip()
    if not a or not b or len(a) != len(b):
        return 0.0
    same = sum(1 for i in range(len(a)) if a[i] == b[i])
    return same / len(a)


def _name_score(text: str, want: str) -> float:
    """显示名 vs 目标名打分, 0 = 肯定不是这台。

    三种来源的差异都要吃下:
      1.00  归一化后完全一致;
      0.90  显示名**以**目标名结尾 —— Connect 会在机名前面加机型
            (云端叫「宇树」, 下拉里显示「拓竹A1宇树」; 等长比对对它
            是 0 分, 只按相似度核对会永远核不上, 这就是「没有匹配到
            目标」的一个来源);
      0.8+  等长同位相似度 (视觉同音错字)。
    后缀规则要求目标名 ≥2 字且显示名更长, 于是「拓竹A1宇树2」不会
    被当成「宇树」(它结尾是「宇树2」) —— 误派保护还在。
    """
    t, w = _norm_printer_name(text), _norm_printer_name(want)
    if not t or not w:
        return 0.0
    if t == w:
        return 1.0
    if len(w) >= 2 and len(t) > len(w) and t.endswith(w):
        return 0.90
    s = _name_similarity(t, w)
    return 0.8 + 0.19 * s if s >= 0.8 else 0.0


def _win_target_shown(texts, want_name: str, known: dict,
                      serial: str) -> str:
    """弹窗当前机名 -> 目标机? 返回命中的显示名 (没命中返回 "")。

    弹窗里显示的是下拉框当前值, 它必须就是**映射到目标序列号**的那台
    (重名机保护)。做法: 把显示到的每个文本跟**所有**已知机名打分, 取全局
    最高分; 最高分命中的已知名若不属于目标序列号就判不中 —— 这样
    「拓竹A1大宇树」不会被当成本次要的「宇树」。known 为空时退化成
    只跟 want_name 比。
    """
    cur = {str(t).strip() for t in (texts or []) if t and str(t).strip()}
    if not want_name:
        return ""
    names = list((known or {}).keys()) or [want_name]
    if want_name not in names:
        names.append(want_name)
    # 同分时取**更长**的已知名当命中 (更具体): 「拓竹A1大宇树」对「宇树」
    # 和「大宇树」都是后缀命中, 必须认「大宇树」—— 那可能是另一台机。
    best_key, best_text, best_name, best_score = (0.0, 0), "", "", 0.0
    for t in cur:
        for n in names:
            score = _name_score(t, n)
            key = (score, len(_norm_printer_name(n)))
            if key > best_key:
                best_key, best_text, best_name, best_score = key, t, n, score
    if best_score < 0.8:
        return ""
    if known and known.get(best_name) != serial:
        return ""
    return best_text


def _win_wait_target(want_name: str, known: dict, serial: str,
                     timeout: float = 1.5) -> str:
    """轮询 UIA texts 直到目标机名出现 (借 Mac 侧 _wait_target 的做法)。

    点完下拉项之后界面刷新有延迟, 固定 sleep 一读到底会把「已经切过去了」
    判成没切, 白试三轮。这里到超时为止每 150ms 读一次。
    """
    deadline = time.time() + timeout
    while True:
        shown = _win_target_shown(ax.texts(), want_name, known, serial)
        if shown:
            return shown
        if time.time() >= deadline:
            return ""
        time.sleep(0.15)


def _win_pick_printer(shot_path: str, want_name: str, known: dict,
                      serial: str, ocr: list | None = None
                      ) -> tuple[bool, str]:
    """把「发送打印任务至」弹窗里的打印机切到 want_name。

    与 Mac 的 select_device 同构 (2026-10-29 对齐): 定位下拉框 -> 展开 ->
    读选项(名字+坐标) -> 点最像目标的 -> UIA texts 权威核对。
    几何来源: OCR 机名行 (2026-10-29 盒子实测: 树残留会给错位几何, 裁剪图
    空裁 700 字节为证; 全屏 OCR 命中已知机名的那行就是下拉当前值, 像素即
    真相) > UIA 选择器 > UIA 当前值矩形 > 视觉 chevron (可选)。
    选项来源三级: UIA 原生 (Chromium 有时把 option 映射进树) > Windows
    自带 OCR (免费) > 云端视觉 (可选, 配额满/断网就没了)。视觉/OCR 读名
    都可能有错字, 只用来排序候选; 选中与否以 texts 里下拉框当前值为准
    (当前值在树里, 零错字风险)。

    返回 (选中?, 说明)。选不中就让调用方 fail-closed 取消, 绝不盲发。
    """
    g = None
    cx = cy = None
    hit_line = None
    if ocr:
        hit = _win_lines_hit_printer(ocr, known, want_name)
        if hit:
            hit_line = next((l for l in ocr
                             if l["name"] == hit and l.get("w")), None)
        if hit_line is None:
            # 2026-10-29 盒子实测: 下拉当前值是小字+图标, 全屏 zh-Hans OCR
            # 整行漏掉 (「123」没进输出) -> 用读到了的「发送打印任务至」
            # 标题行锚定弹窗, 裁值行区域放大 2.5x 重读。值行恒在标题下方
            # 45~105px、左缘对齐标题 (Connect 布局固定)。
            tline = next((l for l in ocr
                          if "发送打印任务至" in "".join(l["name"].split())
                          and l.get("w")), None)
            if tline:
                tl = tline["x"] - tline["w"] // 2   # 标题左缘
                tt = tline["y"] - tline["h"] // 2   # 标题上缘
                try:
                    from PIL import Image
                    box = (max(0, tl - 10), max(0, tt + 30),
                           tl + 380, tt + 130)
                    im = Image.open(shot_path).crop(box)
                    resample = getattr(getattr(Image, "Resampling", Image),
                                       "LANCZOS")
                    im = im.resize((im.width * 5 // 2, im.height * 5 // 2),
                                   resample)
                    zp = shot_path + ".val.png"
                    im.save(zp, "PNG")
                    vlines = _win_ocr_lines(zp) or []
                except Exception:  # noqa: BLE001
                    vlines = []
                names = list((known or {}).keys())
                if want_name and want_name not in names:
                    names.append(want_name)
                for v in vlines:
                    if not v.get("w"):
                        continue
                    vname = _win_trim_chevron(v["name"])  # 「123 v」-> 「123」
                    scr = {"name": vname,
                           "x": int(box[0] + v["x"] / 2.5),
                           "y": int(box[1] + v["y"] / 2.5),
                           "w": int(v["w"] / 2.5), "h": int(v["h"] / 2.5)}
                    if any(_name_score(vname, n) >= 0.8 for n in names):
                        hit_line = scr
                        break
                _log("picker value-zoom: title=(%d,%d) vlines=%s hit=%s" % (
                    tl, tt, [v["name"][:12] for v in vlines[:6]],
                    hit_line and hit_line["name"]))
    _log("picker geom: hit_line=%s names=%s" % (
        bool(hit_line), [l["name"][:10] for l in (ocr or [])][:14]))
    if hit_line:
        # 下拉当前值行: 矩形反推自中心坐标 (PS OCR 给的是包围盒中心)
        l = hit_line
        g = {"x": float(l["x"] - l["w"] // 2),
             "y": float(l["y"] - l["h"] // 2),
             "w": float(l["w"]), "h": float(l["h"])}
        cx, cy = int(g["x"] + g["w"]) + 24, int(l["y"])
    else:
        frame = None
        try:
            frame = ax.selector_frame()
        except Exception:  # noqa: BLE001
            frame = None
        g = (frame or {}).get("group")
        if g:
            chev = (frame or {}).get("chevron") or {
                "x": g["x"] + g["w"] - 24, "y": g["y"] + g["h"] / 2}
            cx, cy = int(chev["x"]), int(chev["y"])
        else:
            # 选择器结构没进树 (Chromium 懒加载常态): 退当前值文本矩形,
            # 箭头 ≈ 值右缘-24 (与 chevron 组内几何兜底同一偏移)。
            rect = _win_rect_of_current(known, want_name)
            if rect:
                g = {"x": float(rect[0]), "y": float(rect[1]),
                     "w": float(rect[2] - rect[0]), "h": float(rect[3] - rect[1])}
                cx, cy = int(rect[2]) - 24, int((rect[1] + rect[3]) / 2)
            else:
                # 树彻底掏空的最后兜底: 视觉找 chevron (可选)。没有选择器矩形
                # 就没法裁剪做本地 OCR, 选项只能走视觉; 视觉也没有 -> 放弃。
                try:
                    import bconnect_vision as vision
                    full = shot_path + ".full"
                    if ax.screenshot(full):
                        c = vision.ask_coords(
                            full, "打印机名字右边的下拉箭头(小三角/chevron)")
                        if c:
                            cx, cy = int(c[0]), int(c[1])
                except Exception:  # noqa: BLE001
                    pass
                if cx is None:
                    return False, "选择器几何拿不到 (chevron 组/当前值/视觉都空手)"
    n_known = max(3, len(known or {}) + 2)

    def vision_options():
        """云端视觉兜底 (可选): 本地两级都空手才走这, 配额满就直接空。"""
        try:
            import bconnect_vision as vision
            full = shot_path + ".vfull"
            if not ax.screenshot(full):
                return []
            js = vision.ask_vision(
                full,
                "这是打印机下拉列表展开后的截图, 列表每项是一台打印机。"
                "只输出 JSON: {\"options\":[{\"name\":\"逐字机名\","
                "\"x\":123,\"y\":456}]} (x/y 是该项文字中心的像素坐标)")
            return _win_parse_options(js)
        except Exception:  # noqa: BLE001
            return []

    def read_options(tag):
        """点箭头展开 + 读选项 (三级来源)。列表本来开着时点箭头会把它收起,
        这时读不到选项 —— 调用方读不到就再点一次, 不假设当前开合状态。
        """
        if not ax.press_at(cx, cy):
            return None  # None = 点不动, 直接放弃
        time.sleep(1.0)
        if g is None:
            return vision_options()  # 没有选择器矩形, 裁剪OCR做不了
        # 1) UIA 原生选项
        try:
            opts = [{"name": o["name"], "x": int(o["x"]), "y": int(o["y"])}
                    for o in (ax.dropdown_options(g, row_limit=n_known) or [])
                    if o.get("name")]
        except Exception:  # noqa: BLE001
            opts = []
        if opts:
            return opts
        # 2) 本地 OCR: 裁选择器下方区域读行名+行中心
        # (2026-10-29 盒子实测: 选项列表比当前值文本宽得多 —— 值「123」
        # 只有 30px, 列表 315px; 窄裁会把「拓竹A1 xxx」拦腰截断)
        lst = "%s.list%s" % (shot_path, tag)
        rx, ry = int(g["x"]) - 60, int(g["y"] + g["h"]) - 4
        rw, rh = int(g["w"]) + 300, 30 + n_known * 40 + 20
        try:
            from PIL import ImageGrab
            # 同 .zoom 教训: 动态后缀 (.list r0/r1) 必须显式格式
            ImageGrab.grab(bbox=(rx, ry, rx + rw, ry + rh),
                           all_screens=True).save(lst, "PNG")
        except Exception as e:  # noqa: BLE001
            _log("crop shot fail:", str(e)[:60])
            return None
        ocr = _win_ocr_lines(lst)
        if ocr is None:
            return None  # 引擎不可用
        # 裁剪图坐标平移回屏幕; 只留选择器下缘以下的行 (上头是弹窗标题)
        # 选项行尾也可能带 chevron/勾标 (读成 'v'/'√'), 统一摘掉再比对
        keep = [{"name": _win_trim_chevron(o["name"]),
                 "x": o["x"] + rx, "y": o["y"] + ry}
                for o in ocr if o["y"] + ry >= g["y"] + g["h"] - 4]
        _log("picker ocr[%s]: crop=%dx%d+%d+%d raw=%d keep=%d %s" % (
            tag, rw, rh, rx, ry, len(ocr), len(keep),
            [(k["name"][:10], k["x"], k["y"]) for k in keep[:6]]))
        return keep

    tried = set()
    # 每轮只点**一个**候选(最像目标的未试项), 下一轮重新展开重读坐标。
    # 早先版本在内层循环里连着点多个候选: 第一次点没命中后下拉已经收起,
    # 后面那些坐标全是展开态的旧值, 点了也白点 (实测会一直失败)。
    vision_tried = False
    for _round in range(3):
        opts = read_options("r%d" % _round)
        if opts is not None and not opts:
            # 可能是列表本来就开着, 这一点把它收起了 —— 再点一次展开重读
            opts = read_options("r%db" % _round)
        if not opts and not vision_tried:
            vision_tried = True   # 全程至多一次云端视觉, 别把配额打爆
            opts = vision_options()
        if not opts:
            return False, "下拉选项读不出 (UIA/本地OCR/视觉都空手)"
        opts.sort(key=lambda o: -_name_score(o["name"], want_name))
        cand = next((o for o in opts if o["name"] not in tried), None)
        if cand is None:
            break
        tried.add(cand["name"])
        if not ax.press_at(cand["x"], cand["y"]):
            continue
        shown = _win_wait_target(want_name, known, serial)
        if shown:
            return True, "已选中「%s」(下拉框当前值已核对)" % shown
    return False, "候选都点过仍没选中「%s」(试过: %s)" % (
        want_name, ",".join(sorted(tried)))


def _run_win(rec, result: dict, *, path: str, serial: str, dev: dict,
             before_id, stop_before_send: bool, select_only: bool,
             filament: list[str] | None, verbose: bool, t0: float) -> dict:
    """Windows 派单流程 (2026-10-29 P17–P22 真机全链路实测)。

    与 Mac 的差异: 深链直达打印选项页(文件预载), 没有 Mac 的导入弹窗、
    「发送打印任务至」发送页和下拉选机。实测链 (两种行为都要兼容):
      v9(1024x768):    选项页「打印」-> 导入确认弹窗 -> 确认后 ~2s 自动接
                       打印确认弹窗 -> confirm = 真派单 -> 设备详情页。
      当前构建(1920x1080): 导入确认后回选项页(预览出现), 要再按一次
                       「打印」才出打印确认弹窗 -> confirm = 真派单。

    弹窗正文不进 UIA 树 (confirm/cancel 钮名是树里仅有的信号), 内容分类
    = 截图 + 视觉 (_win_classify_dialog)。派单 confirm 前必须在视觉读回的
    弹窗内容里核对到目标机名 (名→序列号反查==serial); 读不出/核对不到/
    选机点选失败一律 press_cancel_strict 放弃 —— 宁可这次换盘失败, 不能
    把任务打进别的机器 (P22 误派教训)。
    """
    base = os.path.basename(path)

    # 1) 选项页 (深链直达; 「打印」钮 = 页面标记)
    if not wait_probe(40, buttons=["打印"]):
        result["error"] = "打印选项页未出现「打印」按钮"
        rec("options-page", False, result["error"])
        return result
    # 文件核对: 选项页文字里必须看得到该文件名, 防止预载失败后按错文件。
    if not wait_probe(8, texts=[base]):
        result["error"] = "选项页文字里核对不到打印文件「%s」" % base
        rec("check-file-page", False, result["error"])
        return result
    rec("options-page", True, "已进选项页, 文件「%s」已预载" % base)
    if filament:
        rec("filament", True, "Windows 选项页无耗材入口(未实现), 已忽略")

    # 2) 目标机在派单前没有 UI 落点, 只能先备好「可核对机名表」:
    #    只收名→序列号反查唯一的机器, 重名机不进表(防误配)。
    want_name = ((dev or {}).get("name") or "").strip()
    known = {}
    for d in cloud.device_list() or []:
        n = (d.get("name") or "").strip()
        s = d.get("serial")   # device_list 已把云端的 dev_id 规范成 serial
        if n and s and cloud.serial_for_name(n) == s:
            known[n] = s

    if stop_before_send:
        # Windows 没有发送页: 最后的安全停靠点 = 选项页(文件已预载、未按
        # 「打印」)。再往下任何一次 confirm 都等于真派单。
        # select_only 不在这里停: 它要继续走到「发送打印任务至」弹窗做完
        # 选机核对再**取消**, 这样测选择器不用真派单。
        rec("stop-before-send", True, "已停在选项页, 未派单")
        result["ok"] = True
        return result

    # 3) 派单: 按「打印」-> 弹窗状态机。弹窗正文不进 UIA 树 (2026-10-29
    #    实测 18s 纹丝不动), 内容分类 = 截图 + 视觉 (_win_classify_dialog);
    #    视觉读不出一律取消 (fail-closed, P22 教训)。
    #    两种实测行为都要兼容: v9 会话导入确认后 ~2s 自动接打印弹窗; 当前
    #    构建(1920x1080)导入确认后回选项页, 要再按一次「打印」才出打印弹窗。
    if not press_text("打印"):
        result["error"] = "点不到「打印」按钮"
        rec("click-print", False, result["error"])
        return result
    rec("click-print", True, "已按「打印」, 等确认弹窗")

    shot_path = os.path.join(tempfile.gettempdir(), "deck_win_dialog.png")
    pressed = 1        # 「打印」按下次数 (上限 2: 首次 + 导入回选项页后一次)
    imported = False
    dispatched = False
    for rnd in range(1, 8):
        # 弹窗出现探测: cancel+confirm 钮对同时在树里 = 有弹层 (选项页/
        # 详情页都没有这对钮)。不能用「导入Gcode 3MF文件」按钮名探弹窗 ——
        # 选项页「浏览换文件」钮同名, 永远假阳性 (v9 教训)。
        d = None
        # 2026-10-29 干跑时间线: 二按前 14.4s 里 12s 是这里空转 —— 导入确认
        # 后明知 ~2s 回选项页, 探测只是确认「没有意外弹窗」。超时不失败:
        # 走 wait_probe 找「打印」按钮兜底, 所以 imported 后只给 3s。
        deadline = time.time() + (25 if rnd == 1 else (3 if imported else 12))
        while time.time() < deadline:
            d = ax.dialog_frame()
            if d:
                break
            time.sleep(0.6)
        if not d:
            # 没弹窗: 已导入且还有一次「打印」额度 -> 再按一次进打印弹窗;
            # 否则交给云端任务回读裁决 (可能没弹框直接派单了)。
            if pressed >= 2 or not wait_probe(6, buttons=["打印"]):
                break
            btn = ax.button_rect("打印")
            if imported and btn:
                # 实测 (2026-10-29 p_press2): 导入确认回选项页后, UIA
                # Invoke 按「打印」哑火 (返回 True 但界面无响应), 物理鼠标
                # 点按钮中心 2s 内必弹「发送打印任务至」。
                ok = ax.press_at((btn[0] + btn[2]) // 2, (btn[1] + btn[3]) // 2)
                how = "mouse"
            else:
                ok = press_text("打印")
                how = "invoke"
                if not ok and btn:
                    ok = ax.press_at((btn[0] + btn[2]) // 2,
                                     (btn[1] + btn[3]) // 2)
                    how = "mouse"
            if not ok:
                result["error"] = "第%d次按「打印」失败" % (pressed + 1)
                rec("click-print", False, result["error"])
                return result
            pressed += 1
            rec("click-print", True,
                "第%d次按「打印」(%s, 进打印确认)" % (pressed, how))
            continue
        time.sleep(1.0)  # 弹窗进场动画/渲染稳定 (分类只读文字, 1.0s 足够)
        # ---- 弹窗分类: 本地 OCR 像素先行 -> UIA 树 -> 云端视觉(可选)。
        # 2026-10-29 实测两条铁律:
        #   (1) UIA 树会残留上一态 —— 导入确认框盖着页面时树里还躺着上一屏
        #       的机器名, 树先行会把导入框骗成「打印」; Chromium 树懒加载/
        #       掏空/残留都是常态, 截图即真相, 所以 OCR 先行, 树只配兜底。
        #   (2) zh-Hans OCR 在 CJK 字间插空格, 子串匹配先剥空白; 全屏 OCR
        #       连背景一起读, 判定顺序 = 发送弹窗专属标记「发送打印任务至」
        #       > 导入标记 > 机名命中 (机名最不可靠, 放最后)。
        #   视觉配额 429 不再卡死链路 —— 它只是最后的可选兜底。
        kind, body, printers, ocr = "", "", [], None
        if not ax.screenshot(shot_path):
            ax.press_cancel_strict()
            result["error"] = "弹窗截图失败, 已取消未派单"
            rec("classify-dialog", False, result["error"])
            return result
        # 分类/锚定只看弹窗: 截中央 1000x660 (弹窗恒居中, ~1/4 像素省一半
        # OCR 时间); 裁剪失败或空手退全屏。
        try:
            from PIL import Image as _Img
            _sw, _sh = _Img.open(shot_path).size
        except Exception:  # noqa: BLE001
            _sw = _sh = 0
        ocr = None
        if _sw:
            ocr = _win_ocr_region(
                shot_path,
                (_sw // 2 - 500, _sh // 2 - 330,
                 _sw // 2 + 500, _sh // 2 + 330))
        if ocr is None:
            ocr = _win_ocr_lines(shot_path)
        if ocr:
            blob = "".join("".join(l["name"].split()) for l in ocr)
            if "发送打印任务至" in blob:
                kind = "打印"
            elif WIN_IMPORT_TEXT in blob or "导入" in blob:
                kind = "导入"
            elif _win_lines_hit_printer(ocr, known, want_name):
                kind = "打印"  # 发送弹窗下拉当前值 (导入弹窗背景无机名)
        elif _win_classify_local(ax.texts(), known, want_name) == "send":
            kind = "打印"  # OCR 引擎不可用才退树签名
        else:
            cls = _win_classify_dialog(shot_path)  # 云端视觉兜底
            kind = str(cls.get("kind") or "unknown")
            body = str(cls.get("body") or "")
            printers = [p for p in (cls.get("printers") or []) if p]
        # OCR 看见了什么带进步骤日志: 远程排障全靠它 (UIA 树掏空是常态)。
        ocr_dbg = ""
        if ocr:
            ocr_dbg = " ocr=[%s]" % "; ".join(
                l["name"][:20] for l in ocr[:12])
        rec("classify-dialog", kind in ("打印", "导入"),
            "kind=%s body=%s printers=%s%s" % (kind, body[:48], printers, ocr_dbg))
        if kind not in ("打印", "导入"):
            # 2026-10-29 修正: OCR/视觉都没认出标记时 kind 是 "" 而不是
            # "unknown", 旧判定 == "unknown" 永远不成立, 空 kind 会掉进
            # 循环底部的兜底分支 —— 行为恰好也是取消, 但报错误导排障方向。
            ax.press_cancel_strict()
            result["error"] = ("弹窗内容判读不出 (UIA/本地OCR/视觉都空手), "
                               "已取消未派单")
            rec("check-target", False, result["error"] + ocr_dbg)
            return result
        if kind == "导入":
            # 文件核对: 视觉正文 / 本地 OCR 都给得到才算数; 全屏 OCR 认不出
            # (小字拆部首) 时裁弹窗放大重读; 两条 OCR 路都不可用才退流程位置
            # —— 文件来自本进程 0.5s 前发的 deeplink, 选项页又已核对过文件名,
            # 这里的 confirm 也不派单, 放行。
            zoom_dbg = ""
            if body:
                file_ok = base in body
            elif ocr is not None:
                file_ok = _win_file_in_lines(ocr, base)
                if not file_ok:
                    zoom = _win_ocr_dialog_lines(shot_path, ax.dialog_frame())
                    if zoom:
                        file_ok = _win_file_in_lines(zoom, base)
                        zoom_dbg = " zoom=[%s]" % "; ".join(
                            l["name"][:20] for l in zoom[:8])
                    else:
                        zoom_dbg = " zoom=none"
            else:
                file_ok = True
            if not file_ok:
                ax.press_cancel_strict()
                result["error"] = ("导入弹窗核对不到文件「%s」, 已取消未派单"
                                   % base)
                rec("check-file", False, result["error"] + ocr_dbg + zoom_dbg)
                return result
            # 导入确认弹窗 (正文含标记 + 文件名核对): strict confirm
            ok = ax.press_confirm_strict()
            if not ok:
                time.sleep(1.5)
                ok = ax.press_confirm_strict()
            if not ok:
                result["error"] = "导入确认弹窗(第%d轮)点不到确认键" % rnd
                rec("click-import", False, result["error"])
                return result
            imported = True
            rec("click-import", True,
                "第%d轮: 已确认导入 (%s核对正文)"
                % (rnd, "视觉" if body else "本地OCR" if ocr is not None
                   else "流程位置"))
            time.sleep(0.8)  # 回选项页; 下一轮探测会兜底等
            continue
        if kind in ("打印", "选择") and want_name:
            # 「发送打印任务至」弹窗: 目标机 = 下拉框当前选中的那台。
            # 权威来源是 UIA texts (下拉框当前值在树里, 零 OCR 错字);
            # 当前值不是目标 → 展开下拉点选目标 (选项不进树, 只能视觉给
            # 坐标; 视觉名只用来排序候选, 选中与否仍以 texts 为准)。
            cur = {t for t in ax.texts() if t}
            shown = _win_target_shown(cur, want_name, known, serial)
            if not shown:
                ok2, why = _win_pick_printer(shot_path, want_name, known,
                                             serial, ocr=ocr)
                rec("select-device", ok2, why)
                if not ok2:
                    ax.press_cancel_strict()
                    result["error"] = ("发送弹窗切机失败: %s, 已取消未派单" % why)
                    rec("check-target", False, result["error"])
                    return result
                # 选完再确认一次: 选机内部已经 _win_wait_target 过, 这里只是
                # 给界面一个刷新窗口, 拿最终值。
                shown = _win_wait_target(want_name, known, serial, timeout=1.0)
                cur = {t for t in ax.texts() if t}
            if not shown:
                # texts 掏空兜底 (Chromium 懒加载常态): 重预热 a11y 再读;
                # 还没有就本地 OCR 全屏, 目标名**逐字**命中才放行 (OCR 有
                # 同音错字风险, 不吃模糊)。序列号门在下面照旧把关。
                try:
                    ax.enable_ax()
                except Exception:  # noqa: BLE001
                    pass
                shown = _win_wait_target(want_name, known, serial, timeout=0.8)
            if not shown:
                full2 = shot_path + ".verify"
                if ax.screenshot(full2):
                    v = _win_ocr_lines(full2)
                    want_n = _norm_printer_name(want_name)
                    for l in (v or []):
                        if _norm_printer_name(l["name"]) == want_n:
                            shown = want_name
                            rec("check-target-ocr", True,
                                "texts 掏空, 本地OCR 逐字命中「%s」" % l["name"])
                            break
            if not shown:
                ax.press_cancel_strict()
                result["error"] = ("发送弹窗当前机名核对不到目标「%s」"
                                   "(弹窗可见: %s), 已取消未派单"
                                   % (want_name, sorted(cur)[:8]))
                rec("check-target", False, result["error"])
                return result
            # 名字对上了还要对序列号 (重名机保护)。查表也按归一化比 (空格/
            # 大小写/状态后缀都不算差异), 与显示名的匹配口径保持一致。
            want_serial = next(
                (s for n, s in known.items()
                 if _norm_printer_name(n) == _norm_printer_name(want_name)),
                None)
            if want_serial != serial:
                ax.press_cancel_strict()
                result["error"] = ("机名「%s」与目标序列号 %s 不一致(已知映射:%s), "
                                   "已取消未派单"
                                   % (want_name, serial, known))
                rec("check-target", False, result["error"])
                return result
            if select_only:
                # 干跑到这里就够: 选择器已把下拉切到目标机并核对过。取消
                # 掉弹窗 = 不派单, 但拿得到「能不能切到这台」的铁证。
                ax.press_cancel_strict()
                result["ok"] = True
                result["selected"] = shown
                rec("select-only", True,
                    "目标「%s」已选中并核对, 按 select_only 取消未派单" % shown)
                return result
            if not ax.press_confirm_strict():
                result["error"] = "目标已核对(「%s」)但点不到确认键" % want_name
                rec("click-dispatch", False, result["error"])
                return result
            dispatched = True
            rec("click-dispatch", True,
                "目标「%s」已核对(UIA 当前值), 已确认派单" % shown)
            break
        # 导入弹窗但文件名对不上 / kind=其他 / 视觉读不出: 一律取消 ——
        # 绝不盲按 confirm (P22 误派教训)。
        ax.press_cancel_strict()
        result["error"] = ("确认弹窗内容无法核对(kind=%s body=%s "
                           "printers=%s), 已取消未派单"
                           % (kind, body[:60], printers))
        rec("check-target", False, result["error"])
        return result

    if not dispatched:
        # 两种可能: (a) 没弹确认框直接派单了 (v9 未观察到此路径, 以云端为准);
        # (b) 按「打印」没反应。云端任务回读裁决。
        task = cloud.latest_task(base, serial, after_id=before_id,
                                 tries=5, wait=3)
        if task:
            result["task"] = task
            result["ok"] = True
            rec("task-created", True,
                "未见确认弹窗但云端已有新任务 id=%s device=%s"
                % (task.get("id"), task.get("device")))
            return result
        result["error"] = "按「打印」后未见可处理的确认弹窗, 云端也未回读到新任务"
        rec("click-dispatch", False, result["error"])
        return result

    # 点下派单确认即 ok (与 Mac 一致: 不等页面切换, AX 旧文字滞留会假等待)。
    result["ok"] = True
    task = cloud.latest_task(base, serial, after_id=before_id, tries=4, wait=2)
    if task:
        result["task"] = task
        if task.get("device") and task["device"] != serial:
            rec("task-created", False, "警告: 任务落到 %s, 期望 %s"
                % (task["device"], serial))
        else:
            rec("task-created", True, "id=%s status=%s device=%s"
                % (task.get("id"), task.get("status"), task.get("device")))
    else:
        rec("task-created", False, "云端暂未回读到新任务(可能还在落库)")
    result["elapsed_total"] = round(time.time() - t0, 2)
    if verbose:
        print("总耗时 %.1fs，结果 ok=%s" % (result["elapsed_total"],
                                           result["ok"]), flush=True)
    return result


def run(path: str, stop_before_send: bool = False,
        serial: str = DEFAULT_DEVICE, verbose: bool = True,
        filament: list[str] | None = None, select_only: bool = False) -> dict:
    steps: list[dict] = []
    t0 = time.time()
    _prev = [t0]
    # SILENT：Connect 收到 deep link 会自己弹到最前（导入弹窗）。记下当前 app，
    # 导入弹窗出现后、点完发送后立刻把焦点压回去，不等到整个流程结束。
    frontmost = _frontmost_app() if SILENT else None

    def rec(step: str, ok: bool, detail: str = "") -> None:
        now = time.time()
        since = now - _prev[0]
        steps.append({"step": step, "ok": ok, "detail": detail,
                      "elapsed": round(now - t0, 2),
                      "since_prev": round(since, 2)})
        _prev[0] = now
        if verbose:
            print("[%s] %s %s  累计 %.1fs / 上步 %.1fs" % (
                "OK" if ok else "FAIL", step, detail,
                now - t0, since), flush=True)

    result = {"ok": False, "file": path, "steps": steps,
              "task": {"id": None, "status": None, "device": None},
              "printer": {"state": None, "percent": None}, "error": None}

    if not os.path.isfile(path):
        result["error"] = "文件不存在: %s" % path
        rec("check-file", False, result["error"])
        return result
    rec("check-file", True, path)

    # 目标机校验：序列号必须在云端注册表且在线，否则别白点三下 UI
    dev = cloud.resolve_device(serial)
    if dev is None:
        result["error"] = "未知序列号 %s（不在云端设备列表）" % serial
        rec("check-device", False, result["error"])
        return result
    if not dev.get("online"):
        result["error"] = "目标打印机离线: %s（%s）" % (dev.get("name"), serial)
        rec("check-device", False, result["error"])
        return result
    rec("check-device", True, "%s 在线" % dev.get("name"))
    if filament:
        rec("filament", True, "指定耗材: %s" % ", ".join(filament))

    # 派单前记下当前最新任务 id，派单后只看比它新的任务（防重复打印读到旧任务）。
    # wait=0：latest_task 的 wait 是「每轮结束后的 sleep」，即便 tries=1 也会白等 5s。
    before = cloud.latest_task(os.path.basename(path), serial, tries=1, wait=0)
    before_id = (before or {}).get("id")

    try:
        rec("ensure-app", True, ensure_app())
        enable_ax()
        rec("enable-ax", True, "AXManualAccessibility=true")
    except Exception as e:  # noqa: BLE001
        if _IS_WIN:
            # 2026-10-29 07:53 实测: Connect 自更新/重启期间窗口短暂消失
            # (探针 8 分钟后确认窗口自己回来了), find_window 找不到不该整单
            # 失败 —— 后面选项页 wait_probe 每 10 轮重设 a11y 并重找窗口,
            # 真不在 40s 自然超时报错。
            rec("enable-ax", False,
                "窗口暂不可见(Connect 可能重启中), 交给选项页等待: %s"
                % str(e)[:60])
        else:
            result["error"] = str(e)
            rec("enable-ax", False, str(e))
            return result

    # 清掉上一轮残留的弹窗（只按 cancel，不动 confirm，避免误派单）。
    if _IS_WIN:
        # Windows: 残留弹窗探测用 cancel+confirm 钮对 (弹窗正文不进 UIA 树,
        # 文字探测永远扑空)。strict cancel, 点不到就留着报给下一步。
        if ax.dialog_frame():
            if ax.press_cancel_strict():
                rec("reset", True, "关闭残留弹窗")
                time.sleep(1.5)
            else:
                rec("reset", False, "有残留弹窗但点不到 cancel")
    else:
        # 一次短路 probe 同时探两个页面标记，替代两次全量 texts() 遍历（省 ~18s）。
        r = ax.probe(texts=[SEND_PAGE, IMPORT_PAGE])
        cleaned = [_PAGE_LABEL[t] for t in (SEND_PAGE, IMPORT_PAGE)
                   if t in r.get("texts", {})]
        if cleaned:
            if press_desc("cancel"):
                rec("reset", True, "关闭残留: " + "/".join(cleaned))
                time.sleep(1.5)
            else:
                rec("reset", False, "有残留但点不到 cancel: " + "/".join(cleaned))

    url = open_deeplink(path)
    rec("deeplink", True, url)

    if _IS_WIN:
        # Windows 实测流程与 Mac 完全不同 (无导入弹窗/无发送页/无下拉选机),
        # 整条链独立成 _run_win, 便于对照与后续维护。
        return _run_win(rec, result, path=path, serial=serial, dev=dev,
                        before_id=before_id,
                        stop_before_send=stop_before_send,
                        select_only=select_only, filament=filament,
                        verbose=verbose, t0=t0)

    # 1) 导入弹窗（短路 probe，~2s vs 全量 ~9s）
    if not wait_probe(30, texts=[IMPORT_PAGE]):
        result["error"] = "导入弹窗未出现"
        rec("click-import", False, result["error"])
        return result
    # SILENT：导入弹窗已出现（Connect 自己弹到了最前），立刻把焦点压回用户原来的 app。
    if SILENT:
        _restore_frontmost(frontmost)
    # desc=confirm 是这颗按钮稳定的英文标识（发送/导入共用）；新弹层的按钮
    # **标题**要几秒才进 AX 树（Electron 懒序列化），按标题点会白重试 ~5s 才
    # 落到 desc 兜底 —— 所以 desc 先行（2026-10-27 换盘导入 5s 优化）。
    if not press_desc("confirm"):
        if not press_text("导入Gcode"):
            result["error"] = "导入弹窗里点不到「导入Gcode 3MF文件」"
            rec("click-import", False, result["error"])
            return result
    rec("click-import", True, "已导入")

    # 2) 打印选项页（等「打印」按钮出现；短路 probe）
    if not wait_probe(40, buttons=["打印"]):
        result["error"] = "打印选项页没出现「打印」按钮"
        rec("click-print", False, result["error"])
        return result
    if not press_text("打印"):
        result["error"] = "点不到「打印」按钮"
        rec("click-print", False, result["error"])
        return result
    rec("click-print", True, "已进入发送页")

    if stop_before_send:
        if not wait_probe(25, texts=[SEND_PAGE]):
            rec("stop-before-send", False, "发送页未出现")
            return result
        rec("stop-before-send", True, "已停在发送页，未派单")
        result["ok"] = True
        return result

    # 3) 发送（关键步：认页面文字 + desc=confirm，不靠按钮名字）
    if not wait_probe(40, texts=[SEND_PAGE]):
        result["error"] = "发送页未出现"
        rec("click-send", False, result["error"])
        return result
    # 目标机复核（2026-10-23 一键换盘误派）：发送页顶部设备选择器显示实际派单目标，
    # 之前从不选机、派单全看 Connect 当前选中的机器。这里按「序列号」精确核对——发送页
    # 只暴露机名，先反查名→唯一序列号再和请求的 serial 比（名可重名/改名，序列号才是
    # 稳定唯一标识）。核对不出唯一序列号也按不匹配处理，绝不把换盘派到别台机器。
    want_name = ((dev or {}).get("name") or "").strip()
    target = ax.send_target_device()
    if target != want_name:
        # 自动选机（2026-10-24）：发送页只显示机名、下拉选项不暴露给 AX，这里用
        # 「读选择器几何 + 逐行点选 + 读回机名验证」选机，不依赖下拉行序（全程零视觉）。
        switched = select_device(want_name, cur_target=target)
        rec("select-device", switched,
            "目标「%s」→「%s」" % (target or "?", want_name))
        if switched:
            target = want_name          # 已校验过，省一次 AX 读
        else:
            target = ax.send_target_device()
    # 目标机复核（序列号精确核对，名可重名/改名，序列号才是稳定唯一标识）：
    # 即便 select_device 没切成功，这里仍按「反查不到唯一序列号 = 不匹配」处理，
    # 绝不把换盘派到别台机器。
    target_serial = cloud.serial_for_name(target) if target else None
    if target_serial != serial:
        press_desc("cancel")
        why = ("发送页读不到目标机名" if not target
               else ("目标「%s」反查不到唯一序列号" % target) if not target_serial
               else "目标「%s」(序列号 %s) ≠ 期望「%s」(序列号 %s)"
                    % (target, target_serial, want_name or "?", serial))
        result["error"] = ("目标打印机不匹配/无法精确核对：%s。"
                           "请在 Bambu Connect 里把打印目标切到「%s」后再试"
                           % (why, want_name or serial))
        rec("check-target", False, result["error"])
        return result
    rec("check-target", True,
        "目标「%s」序列号 %s == 期望 %s" % (target or "?", target_serial, serial))
    if select_only:
        # 只验「自动选机」，不派单（CLI 测试用）：已停到发送页并切好目标机。
        result["ok"] = True
        rec("select-only", True, "已切到目标「%s」且不派单" % (target or "?"))
        return result
    if not press_desc("confirm"):
        if not press_text("发送"):
            result["error"] = "点不到「发送」按钮（desc=confirm 与文字均失败）"
            rec("click-send", False, result["error"])
            return result
    # 成功判定 = 点下了「发送」按钮（Connect 以合法身份派单）。不再用 gone_probe
    # 等「发送页离开」——Electron 切页后旧页文字常滞留在 AX 树里，gone_probe 会一直
    # 「看得到发送页」→ 误报「未离开」，即便真发成功了。点下发送即 ok=True，尽快
    # 返回、释放服务端 busy 锁，用户可立即再下停止/暂停等控制。
    result["ok"] = True
    rec("click-send", True, "已点发送（派单成功，不等页面离开）")
    # SILENT：点完发送立刻把焦点压回用户原来的 app（AXPress 一般不抢焦点，这里兜底，
    # 防止发送后 Connect 再弹到最前）。
    if SILENT:
        _restore_frontmost(frontmost)
    # 给 Connect 一小拍真正派单，再回读任务列表（只记日志，不阻塞成功判定）。
    time.sleep(0.8)

    # 4) 派单后做一次「快照」回读（tries=1 不轮询、wait=0 不阻塞），只用于
    #    记日志 / 校验目标机，绝不阻塞成功判定。
    task = cloud.latest_task(os.path.basename(path), serial,
                             after_id=before_id, tries=1, wait=0)
    if task:
        result["task"] = task
        if serial and task.get("device") and task["device"] != serial:
            rec("task-created", False,
                "警告：任务落到 %s，期望 %s（Connect 当前选中机可能不对）" % (
                    task["device"], serial))
        else:
            rec("task-created", True,
                "id=%s status=%s device=%s" % (
                    task["id"], task["status"], task["device"]))
    else:
        rec("task-created", False,
            "任务列表暂未回读到（刚发送，云端可能还在落库）")

    result["elapsed_total"] = round(time.time() - t0, 2)
    if verbose:
        print("总耗时 %.1fs，结果 ok=%s" % (result["elapsed_total"], result["ok"]),
              flush=True)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    ap.add_argument("--serial", required=True,
                    help="目标打印机序列号（必填，避免误派到别的机器）")
    ap.add_argument("--filament", help="指定耗材（逗号分隔，如 PLA,PETG）")
    ap.add_argument("--json", action="store_true", help="只输出 JSON")
    ap.add_argument("--stop-before-send", action="store_true",
                    help="只到发送页，不点发送（不真打印）")
    ap.add_argument("--select-only", action="store_true",
                    help="只自动选机到目标打印机，不派单（测试选机用）")
    ap.add_argument("--list-buttons", action="store_true")
    ap.add_argument("--dump", action="store_true", help="按钮+文字")
    args = ap.parse_args()

    if args.list_buttons or args.dump:
        enable_ax()
        print(json.dumps(dump() if args.dump else {"buttons": list_buttons()},
                         ensure_ascii=False, indent=2))
        return 0

    if not args.file:
        ap.error("--file 必填")

    fil = [x for x in (args.filament.split(",") if args.filament else []) if x]
    res = run(args.file, stop_before_send=args.stop_before_send,
              serial=args.serial, verbose=not args.json, filament=fil or None,
              select_only=args.select_only)
    print(json.dumps(res, ensure_ascii=False, indent=None if args.json else 2))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
