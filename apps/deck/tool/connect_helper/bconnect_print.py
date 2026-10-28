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


_IS_WIN = os.name == "nt"  # Windows 移植 (2026-10-28): 进程探测/启动走 tasklist/exe


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
    r = subprocess.run(["osascript", "-e", 'tell application "%s" to activate' % APP],
                       capture_output=True, text=True, timeout=30)
    return r.returncode == 0


def _screen_mean(x: int, y: int, w: int, h: int) -> float | None:
    """截一小块屏幕，返回平均亮度（判断下拉是否真的展开了）。

    为什么需要：下拉是 JS 浮层，AX 树里完全看不到（展开前后树结构一模一样），
    而刚切到发送页时注入的点击会被吞掉（浮层不出现）。与其猜 sleep 多长，不如
    用「展开前后这块矩形亮度变了没有」做确定性判断。截图为 BMP，纯 Python 解码。
    """
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


def _ocr_dropdown_rows(group: dict, row_limit: int) -> list[tuple[str, int, int]]:
    """截图已展开的下拉浮层 + 本地 OCR，返回 [(文字, 屏幕 x, 屏幕 y)]。

    读不到（截图没权限 / 没有 swiftc / 识别失败）返回空列表，调用方退回逐行试。
    一次读取覆盖整个列表，打印机再多也只花一次 OCR 的时间（2026-10-25 用户反馈：
    逐行试选在机器多时太慢）。
    """
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
