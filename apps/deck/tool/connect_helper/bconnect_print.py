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
import json
import os
import subprocess
import sys
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
import bconnect_ax as ax  # noqa: E402
import bconnect_cloud as cloud  # noqa: E402


# ---------------------------------------------------------------- 应用控制
def _frontmost_app() -> str | None:
    """当前最前 app 名。SILENT 模式下 Connect 收到 deep link 会自己弹到最前，
    用它把焦点还给用户原来的 app。"""
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first process '
         'whose frontmost is true'],
        capture_output=True, text=True, timeout=30)
    return (r.stdout or "").strip() or None


def _restore_frontmost(prev: str | None) -> None:
    """把焦点还给 prev（若不是 Connect）。绝不抛异常。"""
    if not prev or prev == APP:
        return
    try:
        subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % prev],
                       capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        pass


def app_running() -> bool:
    r = subprocess.run(["pgrep", "-f",
                        "%s.app/Contents/MacOS/%s" % (APP, APP)],
                       capture_output=True, text=True)
    return bool(r.stdout.strip())


def ensure_app(timeout: int = 30) -> str:
    """确保 Connect 在跑；默认并置前，BAMBU_SILENT=1 时保持后台。返回 'already'/'launched'。"""
    if app_running():
        if not SILENT:
            subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % APP],
                           capture_output=True, text=True)
        return "already"
    subprocess.run(["open", "-a", "/Applications/%s.app" % APP], check=False)
    for _ in range(timeout):
        time.sleep(1)
        if app_running():
            time.sleep(3)
            if not SILENT:
                subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % APP],
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
def _poll(fn, timeout: float, interval: float = 1.0) -> bool:
    """轮询条件；每轮都重设 AX（窗口重建后不加会读到空树）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        ax.enable_ax()
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
        ax.enable_ax()
        if ax.press_text(marker):
            return True
        time.sleep(0.8)
    return False


def press_desc(desc: str, tries: int = 3) -> bool:
    for _ in range(tries):
        ax.enable_ax()
        if ax.press_desc(desc):
            return True
        time.sleep(0.8)
    return False


def press_confirm_after(marker: str, timeout: float = 20.0) -> bool:
    """仅在确认页面文字出现后才按 confirm，避免误触别的弹窗。"""
    if not wait_text(marker, timeout):
        return False
    return press_desc("confirm")


def wait_probe(timeout: float, texts=(), buttons=(),
               interval: float = 1.0) -> bool:
    """短路探测轮询：一次遍历同时找多个文字/按钮，找到即停（~2s vs 全量 ~9s）。

    只有全部目标都命中才返回 True。每轮重设 AX（窗口重建后不加会读到空树）。
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        ax.enable_ax()
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
               interval: float = 1.0, confirm: int = 2) -> bool:
    """轮询直到目标文字/按钮连续 `confirm` 次都不出现。

    必须连续多次确认「消失」：Electron 页面切换时会重建 AX 树，瞬时返回空树
    （看起来「文字没了」），单次空读不能算「已离开」（会误判为已发送成功）。
    """
    deadline = time.time() + timeout
    streak = 0
    while time.time() < deadline:
        ax.enable_ax()
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


def run(path: str, stop_before_send: bool = False,
        serial: str = DEFAULT_DEVICE, verbose: bool = True,
        filament: list[str] | None = None) -> dict:
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
        result["error"] = str(e)
        rec("enable-ax", False, str(e))
        return result

    # 清掉上一轮残留的弹窗（只按 cancel，不动 confirm，避免误派单）。
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

    # 1) 导入弹窗（短路 probe，~2s vs 全量 ~9s）
    if not wait_probe(30, texts=[IMPORT_PAGE]):
        result["error"] = "导入弹窗未出现"
        rec("click-import", False, result["error"])
        return result
    # SILENT：导入弹窗已出现（Connect 自己弹到了最前），立刻把焦点压回用户原来的 app。
    if SILENT:
        _restore_frontmost(frontmost)
    if not press_text("导入Gcode"):
        if not press_desc("confirm"):
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
              serial=args.serial, verbose=not args.json, filament=fil or None)
    print(json.dumps(res, ensure_ascii=False, indent=None if args.json else 2))
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
