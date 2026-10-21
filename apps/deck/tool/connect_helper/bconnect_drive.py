#!/usr/bin/env python3
"""bconnect_drive.py —— 控制（暂停/继续/停止）的统一驱动 + CLI。

原则（2026-10-21 定）：
  - 打印机匹配：名称+序列号 正则打「已知注册表」（printers.json + 云端设备表），
    纯内存、毫秒级，不靠 AX/视觉。
    更精确的「按序列号校验当前页」：详情页右上角三点菜单 → 关于打印机 里有序列号，
    留作后续校验钩子（当前为测速不读 UI）。
  - 定位：AX 短路遍历 probe()（找到即停），不跑全量 buttons()/texts()（~9s/次）。
  - 点击：System Events AX（CGEvent 对 Electron 不生效）。
  - 控制按钮：以「跳过」为锚 + 固定偏移（Connect 图标稳定）。
    实测布局：跳过[864,302]宽52 → 暂停[924,302] 停止[962,302]，中心 y=318。

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

# 控制按钮相对「跳过」锚左边的固定偏移（像素）。
_OFF_PAUSE = 75    # 暂停/继续中心 = 跳过左边 + 75
_OFF_STOP = 113    # 停止中心     = 跳过左边 + 113

_CMDS = {
    "pause": "pause", "暂停": "pause",
    "resume": "resume", "continue": "resume", "继续": "resume",
    "stop": "stop", "停止": "stop",
}


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
def _enter(name: str) -> bool:
    """回到列表 → 点 name 卡片进详情（正向标记：列表有「设备名称」表头）。"""
    for _ in range(3):
        if ax.probe(texts=["设备名称"])["texts"].get("设备名称"):
            break
        ax.click_desc("我的打印机")
        time.sleep(1.5)
    if not ax.probe(texts=["设备名称"])["texts"].get("设备名称"):
        return False
    if not ax.click_desc(name):
        return False
    time.sleep(2.0)
    return True


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
            r = ax.press_control(name, cmd)
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
        for _ in range(5):
            time.sleep(1.0)
            if ax.press_desc("confirm") or ax.press_at(987, 548):
                confirmed = True
                break
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
