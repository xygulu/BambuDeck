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


if __name__ == "__main__":
    import sys
    verify = "--verify" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        print(__doc__)
        print("已知打印机:")
        for c in known_printers():
            print("  %s  %s" % (c["serial"], c["name"]))
        sys.exit(1)
    print(json.dumps(control(args[0], args[1], verify=verify), ensure_ascii=False, indent=2))
