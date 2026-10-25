#!/usr/bin/env python3
"""bconnect_drive.py —— 控制（暂停/继续/停止）的统一驱动 + CLI。

原则（2026-10-21 定）：
  - 打印机匹配：名称+序列号 正则打「已知注册表」（printers.json + 云端设备表），
    纯内存、毫秒级，不靠 AX/视觉。
    更精确的「按序列号校验当前页」：详情页右上角三点菜单 → 关于打印机 里有序列号，
    留作后续校验钩子（当前为测速不读 UI）。
  - 定位：AX 快路径（bconnect_axfast，ctypes 直读，一次全树 ~0.02~0.3s）短路，
    不可用时回退 System Events。不跑全量 buttons()/texts()（osascript 下 ~9s/次）。
  - 点击：AXPress（CGEvent 对 Electron 控件不生效）。
  - 控制按钮：以「跳过」为锚，取同行、空 label、约 30x32 的两个图标按钮，
    按 x 排序第 1 个=pause/resume、第 2 个=stop。全程不等固定时长，全部轮询就绪标记。

用法：
  python bconnect_drive.py <打印机标识> <pause|resume|stop>
  python bconnect_drive.py <打印机标识> speed <1-4>     # 静音/标准/运动/狂暴
  python bconnect_drive.py <打印机标识> --speed-probe   # 打印控制行的 AX 几何（排查用）
  打印机标识 = 名称或序列号（可部分，正则匹配）
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import time

import bconnect_ax as ax
import bconnect_cloud as cloud
import bconnect_vision as vis

LAN_CONF = os.path.expanduser("~/.bambudeck/printers.json")
SHOT = "/tmp/connect_drive.png"

_CMDS = {
    "pause": "pause", "暂停": "pause",
    "resume": "resume", "continue": "resume", "继续": "resume",
    "stop": "stop", "停止": "stop",
}

# 云端 device_list() 的 print_status：这几类表示「机器认为自己有活儿在身」。
# 只用来做交叉校验（AX 说空闲但云端说在打印 → 再走一次慢路径确认），
# 数据来自已缓存 45s 的设备表，不额外发请求。
_BUSY_STATES = {"RUNNING", "PAUSE", "PREPARE", "SLICING", "SLICER"}


def _cloud_busy(serial: str) -> bool:
    d = cloud.resolve_device(serial) or {}
    return str(d.get("print_status") or "").upper() in _BUSY_STATES


def shot(path: str = SHOT) -> str:
    subprocess.run(["screencapture", "-x", path], check=False)
    return path


# ---------------------------------------------------------------- 打印机匹配（正则）
def known_printers() -> list[dict]:
    """合并本地 LAN 配置 + 云端设备表 → [{serial, name}]。name 以云端为准（Connect 显示云端名）。"""
    reg: dict[str, dict] = {}
    try:
        with open(LAN_CONF) as f:
            for serial, v in json.load(f).items():
                reg[serial] = {"serial": serial, "name": (v or {}).get("name") or serial}
    except Exception:
        pass
    try:
        for d in cloud.device_list():
            serial = d.get("serial")
            if not serial:
                continue
            reg[serial] = {
                "serial": serial,
                "name": d.get("name") or reg.get(serial, {}).get("name") or serial,
            }
    except Exception:
        pass
    return list(reg.values())


def resolve_printer(identifier: str) -> dict | None:
    """identifier（名称/序列号，可部分）→ {serial, name}。正则匹配，毫秒级。

    优先级：精确（序列号/名称）> 序列号包含 > 名称包含。多命中/无命中返回 None。"""
    pat = (identifier or "").strip()
    if not pat:
        return None
    cands = known_printers()
    exact = [c for c in cands if c["serial"] == pat or c["name"] == pat]
    if len(exact) == 1:
        return exact[0]
    try:
        rx = re.compile(re.escape(pat), re.I)
    except re.error:
        rx = re.compile(re.escape(pat))
    for key in ("serial", "name"):
        hits = [c for c in cands if rx.search(c[key])]
        if len(hits) == 1:
            return hits[0]
    return None


# ---------------------------------------------------------------- 导航
def _enter(name: str, timeout: float = 4.0) -> bool:
    """回到列表 → 点 name 卡片进详情（正向标记：列表有「设备名称」表头）。

    轮询就绪标记而不是固定 sleep（AX 快路径一次探测 ~0.02s）：列表出现、卡片点
    完都立刻返回；详情页真正可用与否交给 control() 里的 _wait_control 轮询，
    比原来「点完卡片固定等 2s」快且更稳。
    """
    deadline = time.time() + timeout
    on_list = False
    while time.time() < deadline:
        if ax.probe(texts=["设备名称"])["texts"].get("设备名称"):
            on_list = True
            break
        ax.click_desc("我的打印机")
        time.sleep(0.25)
    if not on_list:
        return False
    return ax.click_desc(name)


def _wait_control(name: str, cmd: str, serial: str, timeout: float = 3.0,
                  dwell: float = 0.8) -> dict:
    """进详情页后轮询控制按钮（页面渲染有先后，不靠固定 sleep）。

    「空闲」下结论要谨慎：刚点完卡片时机器名可能已经进 AX 树、控制行还没渲染完，
    这时看到 idle_no_skip 不代表真空闲。所以：
      - 云端说在打印 → 一直轮询到控件出现或超时（超时后交给调用方慢路径复核）；
      - 云端说空闲 → 也要连续观察满 dwell（0.8s）再收工，避免发布页瞬间误判。
    真正按到控件就立刻返回（正常打印中 ~0.2s）。
    """
    start = time.time()
    deadline = start + timeout
    busy = _cloud_busy(serial)
    r: dict = {"pressed": False, "reason": "not_on_detail"}
    while True:
        r = ax.press_control(name, cmd)
        if r.get("pressed"):
            return r
        idle = r.get("reason") == "idle_no_skip"
        if idle and not busy and time.time() - start >= dwell:
            return r
        if time.time() >= deadline:
            return r
        time.sleep(0.12)


# ---------------------------------------------------------------- 控制
def control(identifier: str, command: str, verify: bool = False) -> dict:
    t0 = time.time()
    steps: dict[str, float] = {}

    def mark(k: str) -> None:
        steps[k] = round(time.time() - t0, 2)

    cmd = _CMDS.get((command or "").strip().lower(), command)
    if cmd not in ("pause", "resume", "stop"):
        return {"ok": False, "error": "未知动作 %r（pause/resume/stop）" % command}

    dev = resolve_printer(identifier)
    mark("match")
    if not dev:
        known = ", ".join("%s(%s)" % (c["name"], c["serial"]) for c in known_printers())
        return {"ok": False, "error": "未匹配到打印机 %r；已知：%s" % (identifier, known)}
    serial, name = dev["serial"], dev["name"]

    ax.enable_ax()

    # 一次遍历：确认在 name 详情页 + 定位并点击控制按钮（真实控制在此触发）
    r = ax.press_control(name, cmd)
    if not r.get("pressed") and r.get("reason") in ("not_on_detail", "wrong_printer"):
        if _enter(name):
            r = _wait_control(name, cmd, serial)
    # 交叉校验：云端说在打印、AX 快路径却说空闲 → 快路径可能漏了控件，用慢路径再确认
    # （只在矛盾时发生，正常路径零额外开销）
    if not r.get("pressed") and r.get("reason") == "idle_no_skip" and _cloud_busy(serial):
        r = ax.press_control(name, cmd, slow=True)
    mark("click")

    if not r.get("pressed"):
        reason = r.get("reason")
        if reason == "idle_no_skip":
            return {"ok": False, "error": "%s 空闲/无控制按钮（暂停/停止只在打印中出现）" % name}
        # 兜底：视觉找按钮坐标（AX 找不到时）
        btn = {"pause": "暂停", "resume": "继续", "stop": "停止"}[cmd]
        shot()
        c = vis.ask_coords(SHOT, btn)
        if c and ax.press_at(*c):
            r = {"pressed": True, "coord": list(c), "method": "vision"}
        else:
            return {"ok": False, "error": "点击 %s 失败（%s）" % (cmd, reason)}

    # stop 需要二次确认：点停止后弹「您确定要停止此次打印吗？」。对话框按钮 label 为空、
    # desc=cancel/confirm/close（确认 ~987,548）。等框弹出后点 confirm（desc 精确匹配，
    # 别用 label——会撞「取消打印」标题）。pause/resume 是 toggle，无需确认。
    if cmd == "stop":
        confirmed = False
        deadline = time.time() + 3.0
        while time.time() < deadline:
            if ax.press_desc("confirm") or ax.press_at(987, 548):
                confirmed = True
                break
            time.sleep(0.12)  # 快路径一次探测 ~0.02s，框一出现就能立刻确认
        if not confirmed:
            return {"ok": False,
                    "error": "停止确认框未出现或找不到「确认」按钮（打印可能仍在进行）",
                    "command": cmd, "printer": name, "serial": serial,
                    "elapsed": round(time.time() - t0, 2), "steps": steps}
        mark("confirm")

    out = {"ok": True, "command": cmd, "printer": name, "serial": serial,
           "method": r.get("method", "ax"), "coord": r.get("coord"),
           "elapsed": round(time.time() - t0, 2), "steps": steps}

    # 校验（可选）：只影响返回时间，不影响真实控制时刻。
    if verify:
        st = cloud.cloud_state(serial, seconds=3)
        mark("verify")
        pst = st.get("print", st)
        out["gcode_state"] = pst.get("gcode_state")

    return out


# ---------------------------------------------------------------- 速度档位
# Connect 设备页有一档位切换（静音/标准/运动/狂暴）。点它等于让 **Connect** 去发
# print_speed —— 这是唯一不需要签名的路：App 自己经 LAN/云 MQTT 发的 print_speed
# 固件会拦（84033543）或者收下不改档。
#
# 页面结构（从 Connect 的 asar 反解，2026-10-26）：控制行里是「速度图标 + NN%」
# 的一个 div（百分比 = state.spd_mag，静音 50 / 标准 100 / 运动 124 / 狂暴 166），
# 点开是 antd Dropdown，菜单项文字才是档位名。两个坑：
#   1. 它不是 AXButton，AXPress 点不动 —— 必须注入真实鼠标点击（click_at），
#      而这就需要 Connect 在最前（服务端会先 activate 再还原焦点）。
#   2. 空闲时 Connect 把整块包进 tooltip，onClick 都不挂：只有 RUNNING/PAUSE/
#      PREPARE/SLICING 才能改档（UI 上那句 "This is only takes effect during
#      printing"）。空闲直接如实报错，别去乱点。
_SPEED_LABELS = {
    1: ("静音", "Silent"),
    2: ("标准", "Standard"),
    3: ("运动", "Sport"),
    4: ("狂暴", "Ludicrous"),
}
_SPEED_NAMES = tuple(x for pair in _SPEED_LABELS.values() for x in pair)
_SPEED_PCT = {1: 50, 2: 100, 3: 124, 4: 166}
_PCT_RX = re.compile(r"^(\d{1,3})%$")
_NUM_RX = re.compile(r"^(\d{1,3})$")
_LAMP_NAMES = ("LED灯", "Lamp")


def activate_connect() -> bool:
    """把 Connect 置前。CGEvent 点的是最顶层窗口，它不在前就点空。

    服务进程调 /command 前会自己置前；CLI 直接跑的时候也要。
    """
    if ax.app_ready():
        return True
    try:
        r = subprocess.run(["osascript", "-e",
                            'tell application "%s" to activate' % ax.APP],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False


def _ctr(item: dict) -> tuple[float, float]:
    pos, size = item.get("pos") or [0, 0], item.get("size") or [0, 0]
    return pos[0] + size[0] / 2.0, pos[1] + size[1] / 2.0


def _cy(t: dict) -> float:
    return t["pos"][1] + t["size"][1] / 2.0


def _percent_items(items: list[dict]) -> list[dict]:
    """AX 树里「NN%」是两段文字（数字 + 单独的 %），同一行、紧挨着 —— 拼起来。"""
    out = []
    for num in items:
        m = _NUM_RX.match(num["text"].strip())
        if not m or num["size"][0] <= 0:
            continue
        right = num["pos"][0] + num["size"][0]
        for p in items:
            if p["text"].strip() != "%":
                continue
            if abs(_cy(p) - _cy(num)) > 6:
                continue
            # 实测数字和「%」是两段独立文字, 位置会重叠 1pt 左右
            # (124 的宽度算到 1091, % 从 1090 开始), 所以允许一点负间隙。
            if not (-6 <= p["pos"][0] - right <= 12):
                continue
            out.append({
                "text": m.group(1) + "%",
                "pos": list(num["pos"]),
                "size": [p["pos"][0] + p["size"][0] - num["pos"][0],
                         num["size"][1]],
                "value": int(m.group(1)),
            })
            break
    return out


def _speed_trigger() -> dict | None:
    """控制面板里那个「速度图标 + NN%」的触发器。

    实测（2026-10-26, A1 打印中）：控制面板一行是 [速度 124%] [LED灯] [热床]，
    打印进度百分比在页面更上面。所以用「LED灯」锚定行、取同行最近的那个
    百分比 —— 不能只看值（100% 可能是打印进度）。
    """
    items = ax.text_items()
    pcts = _percent_items(items)
    if not pcts:
        return None
    lamp = next((t for t in items if t["text"].strip() in _LAMP_NAMES), None)
    if lamp:
        row = [c for c in pcts if abs(_cy(c) - _cy(lamp)) <= 20]
        if row:
            return min(row, key=lambda c: abs(c["pos"][0] - lamp["pos"][0]))
    # 没有 LED灯（老版本/英文界面没渲染）: 值是档位百分比且只有一个才认。
    known = [c for c in pcts if c["value"] in set(_SPEED_PCT.values())]
    return known[0] if len(known) == 1 else None


def _speed_menu() -> list[dict]:
    """档位菜单项（静音/标准/运动/狂暴）的文字元素；菜单没开就是空。"""
    return [t for t in ax.text_items()
            if t["text"].strip() in _SPEED_NAMES and t["size"][0] > 0]


def _same_rects(a: list[dict], b: list[dict]) -> bool:
    return (len(a) == len(b) and
            all(x["text"] == y["text"] and x["pos"] == y["pos"] and x["size"] == y["size"]
                for x, y in zip(a, b)))


def _wait_menu(timeout: float) -> list[dict]:
    """等档位菜单出现 **并且几何稳定** 再返回。

    antd 下拉有几十毫秒的下滑进场动画, 刚出现时读到的位置是动画中间态,
    拿它去点会点空 (和发送页设备下拉踩过的坑一样)。连续两次读到同一组
    几何才算就绪。
    """
    deadline = time.time() + timeout
    prev = None
    while time.time() < deadline:
        m = _speed_menu()
        if m and prev is not None and _same_rects(m, prev):
            return m
        prev = m or None
        time.sleep(0.2)
    return _speed_menu()


def _close_speed_menu() -> bool:
    """收起还开着的档位菜单。

    Esc 实测关不掉（antd 下拉不响应 Esc），改成点「打印进度」标题这类静态
    文字: 点浮层外面就关，而标题本身点了没有任何动作。
    """
    if not _speed_menu():
        return True
    ax.press_escape()
    time.sleep(0.2)
    if not _speed_menu():
        return True
    items = ax.text_items()
    title = next((t for t in items if t["text"].strip() == "打印进度"), None)
    if title:
        ax.click_at(*_ctr(title))
    else:
        # 英文界面没有中文标题: 往左点一段页面空白处。
        pct = next((t for t in items if _PCT_RX.match(t["text"].strip())), None)
        if pct:
            ax.click_at(max(40.0, pct["pos"][0] - 260.0), _ctr(pct)[1])
    time.sleep(0.25)
    return not _speed_menu()


def probe_speed() -> dict:
    """诊断: 打印控制行里的百分比/档位菜单元素（几何），排查「找不到控件」。"""
    trig = _speed_trigger()
    items = ax.text_items()
    return {
        "trigger": trig,
        "percent_items": [t for t in items if _PCT_RX.match(t["text"].strip())],
        "menu_items": [t for t in items if t["text"].strip() in _SPEED_NAMES],
        "skip": next((t for t in items if "跳过" in t["text"]), None),
        "fast": ax.fast_available(),
    }


def set_speed(identifier: str, level: int) -> dict:
    """切速度档位（1 静音 / 2 标准 / 3 运动 / 4 狂暴），走 Connect 自动化。"""
    t0 = time.time()
    steps: dict[str, float] = {}

    def mark(k: str) -> None:
        steps.setdefault(k, round(time.time() - t0, 2))

    if level not in (1, 2, 3, 4):
        return {"ok": False, "error": "速度档位只能是 1-4"}
    dev = resolve_printer(identifier)
    if not dev:
        known = ", ".join("%s(%s)" % (c["name"], c["serial"]) for c in known_printers())
        return {"ok": False, "error": "未匹配到打印机 %r；已知：%s" % (identifier, known)}
    serial, name = dev["serial"], dev["name"]

    # Connect 只在有活儿在身时允许改档（空闲时 onClick 根本没挂）。
    if not _cloud_busy(serial):
        return {"ok": False,
                "error": "%s 当前不在打印/暂停中: Bambu Connect 只在打印中才能"
                         "改速度档位（固件也是这么处理的）" % name,
                "printer": name, "serial": serial,
                "elapsed": round(time.time() - t0, 2), "steps": steps}

    ax.enable_ax()
    # 档位在详情页；已经在详情页就别乱点列表（少一次跳转）。
    trig = _speed_trigger()
    if not trig:
        _enter(name)
        deadline = time.time() + 4.0
        while time.time() < deadline and not (trig := _speed_trigger()):
            time.sleep(0.12)
    mark("enter")
    if not trig:
        return {"ok": False,
                "error": "%s 的设备页上没找到调速控件（Connect 版本或页面不同？）"
                         % name,
                "printer": name, "serial": serial,
                "elapsed": round(time.time() - t0, 2), "steps": steps}

    # 触发器上的百分比就是当前档位（spd_mag），已经是这一档就不用点。
    m = _PCT_RX.match(trig["text"].strip())
    before = int(m.group(1)) if m else None
    want = _SPEED_PCT[level]
    if before == want:
        return {"ok": True, "command": "speed", "level": level,
                "printer": name, "serial": serial, "method": "already",
                "from": trig["text"].strip(), "to": trig["text"].strip(),
                "elapsed": round(time.time() - t0, 2), "steps": steps}

    # 1) 点开档位菜单。刚激活 Connect 时第一次注入点击可能被窗口还没 key 吞掉，
    #    所以失败就再点一次（不用固定 sleep）。
    activate_connect()
    menu: list[dict] = []
    for attempt, wait in ((1, 2.0), (2, 3.0)):
        if attempt == 2:
            trig = _speed_trigger() or trig
        ax.click_at(*_ctr(trig))
        menu = _wait_menu(wait)
        if menu:
            break
    mark("open")
    if not menu:
        shot()
        # 视觉兜底: 让模型找控制行里那个百分比（只在 AX 出错时才会走到这里）。
        c = vis.ask_coords(SHOT, "控制栏里的速度百分比（例如 100%）")
        if c:
            ax.click_at(*c)
            menu = _wait_menu(2.0)
    if not menu:
        return {"ok": False,
                "error": "%s 的调速菜单点不开（Connect 窗口没在前台，或不在打印中?）"
                         % name,
                "printer": name, "serial": serial,
                "elapsed": round(time.time() - t0, 2), "steps": steps}

    # 2) 菜单里点目标档。界面中文优先，英文版退回英文名。
    #
    #    点完菜单应该立刻收起来；还开着就说明这一下点空了（进场动画期间
    #    AX 报的几何可能已经是终点、画面还在缩放），重读几何再点一次。
    target = _SPEED_LABELS[level][0]
    opts = [t for t in menu if t["text"].strip() == target]
    if not opts:
        target = _SPEED_LABELS[level][1]
        opts = [t for t in menu if t["text"].strip() == target]
    delivered = False
    for _ in range(2):
        if opts:
            time.sleep(0.3)  # 等下拉进场动画落定
            ax.click_at(*_ctr(opts[0]))
        else:
            shot()
            c = vis.ask_coords(SHOT, target)
            if not c:
                return {"ok": False, "error": "档位菜单里没找到「%s」" % target,
                        "printer": name, "serial": serial,
                        "elapsed": round(time.time() - t0, 2), "steps": steps}
            ax.click_at(*c)
        time.sleep(0.4)
        if not _speed_menu():
            delivered = True
            break
        opts = [t for t in _wait_menu(1.0) if t["text"].strip() in
                (_SPEED_LABELS[level][0], _SPEED_LABELS[level][1])]
    mark("click")
    if not delivered:
        _close_speed_menu()
        return {"ok": False,
                "error": "点了两次「%s」，菜单都没收起（点击没落到 Connect 上）"
                         % target,
                "printer": name, "serial": serial,
                "elapsed": round(time.time() - t0, 2), "steps": steps}

    # 3) 尽量确认: 界面上的百分比要绕一大圈才回来
    #    (Connect → 云 → 打印机 → 云 → MQTT → Connect), 实测 9.4 秒才变,
    #    有时 20 秒都还没刷新。所以只等 3 秒: 变了就 confirmed=True,
    #    没变不算失败 —— 权威确认由调用方用局域网状态帧里的 spd_lvl 做
    #    (那条是打印机直报的, 秒级)。
    changed, now_txt = False, None
    deadline = time.time() + 3.0
    while time.time() < deadline:
        t = _speed_trigger()
        mm = _PCT_RX.match(((t or {}).get("text") or "").strip())
        if mm:
            now_txt = t["text"].strip()
            if int(mm.group(1)) == want or (before is not None and
                                            int(mm.group(1)) != before):
                changed = True
                break
        time.sleep(0.15)
    mark("verify")
    _close_speed_menu()  # 菜单没关掉就收起来，别挡住后面的操作
    return {
        "ok": True,
        "command": "speed",
        "level": level,
        "printer": name,
        "serial": serial,
        "method": "ax",
        "from": trig["text"].strip(),
        "to": now_txt,
        "confirmed": changed,
        "elapsed": round(time.time() - t0, 2),
        "steps": steps,
        **({} if changed else
           {"note": "已在 Connect 点选「%s」；界面百分比约 10 秒才刷新，"
                    "档位确认请看局域网状态帧的 spd_lvl" % target}),
    }


if __name__ == "__main__":
    import sys
    verify = "--verify" in sys.argv
    speed_probe = "--speed-probe" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if speed_probe:
        if args:
            d = resolve_printer(args[0])
            if d:
                ax.enable_ax()
                _enter(d["name"])
        print(json.dumps(probe_speed(), ensure_ascii=False, indent=2))
        sys.exit(0)
    if len(args) < 2:
        print(__doc__)
        print("已知打印机:")
        for c in known_printers():
            print("  %s  %s" % (c["serial"], c["name"]))
        sys.exit(1)
    if args[1].strip() in ("speed", "速度"):
        if len(args) < 3:
            print("用法: python bconnect_drive.py <打印机标识> speed <1-4>")
            sys.exit(1)
        print(json.dumps(set_speed(args[0], int(args[2]))
                         if args[2].isdigit() else
                         {"ok": False, "error": "速度档位只能是 1-4"},
                         ensure_ascii=False, indent=2))
        sys.exit(0)
    print(json.dumps(control(args[0], args[1], verify=verify), ensure_ascii=False, indent=2))
