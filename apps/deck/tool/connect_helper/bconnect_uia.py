# -*- coding: utf-8 -*-
"""Bambu Connect Windows UIA 底层 (2026-10-28)。

bconnect_ax.py 的 Windows 等价物: 驱动 Bambu Connect (Electron/Chromium) 的
UIA 控件树。deploy 时把本文件同时拷成 bconnect_ax.py, 上层
bconnect_drive/bconnect_service/bconnect_print 无需改动。

实测结构 (RDP 会话, 1920x955):
  窗口      Pane 'Bambu Connect (Beta)' class=Chrome_WidgetWin_1
  列表页    Text '设备名称 ↑'(排序框) = 在列表的标记; 卡片 = Hyperlink '<名> 热床: ..'
  详情页    Text '打印进度' = 在详情的标记; Text '<名>' + '在线';
            打印中: Button '跳过' + 同行两个无名图标按钮 (绿⏸=暂停, 红■=停止, 按 x 排序)
  停止确认  结构待真机验证 (press_desc 会打日志列出候选)
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import time

_user32 = ctypes.windll.user32


def _hwnd_of(w) -> int | None:
    try:
        return int(w.handle)
    except Exception:  # noqa: BLE001
        return None

_EXE = os.path.expandvars(
    r"%LOCALAPPDATA%\Programs\bambu-connect\Bambu Connect.exe")
_WIN_CLASS = 'Chrome_WidgetWin_1'
_CTRL_ROW_DY = 6          # 控制行 y 容差 (px)
_CTRL_ROW_H = (24, 40)    # 控制图标按钮高度范围

_wrap = None              # 缓存的主窗口 wrapper
_poked = False            # Chromium a11y 已预热


def _log(*a):
    try:
        print('[uia]', *a, flush=True)
    except Exception:
        pass


def _safe(fn, default=None):
    try:
        return fn()
    except Exception:
        return default


# ---------------------------------------------------------------- 窗口
def find_window(timeout: float = 20.0):
    """桌面顶层窗口里找 Bambu Connect 主窗口 (Electron: Chrome_WidgetWin_1)。"""
    from pywinauto import Desktop
    end = time.time() + timeout
    fallback = None
    while time.time() < end:
        try:
            wins = Desktop(backend='uia').windows(top_level_only=True)
        except Exception:
            wins = []
        for w in wins:
            ei = w.element_info
            if ei.class_name != _WIN_CLASS:
                continue
            named = 'bambu' in (ei.name or '').lower()
            hwnd = _hwnd_of(w)
            iconic = bool(hwnd is not None and _user32.IsIconic(hwnd))
            if named and iconic:
                # 最小化时 UIA IsOffscreen=True、几何 -32000、Chromium 会把
                # a11y 树降级 —— 先还原再用（2026-10-28 实测：最小化让窗口
                # 匹配不上、全树遍历 20s+，控制流程耗尽看门狗预算）。
                # (UIAWrapper 没有 is_iconic/restore，直接走 user32。)
                try:
                    _user32.ShowWindow(hwnd, 9)  # SW_RESTORE
                    time.sleep(1.5)
                except Exception:  # noqa: BLE001
                    pass
                named = 'bambu' in (w.element_info.name or '').lower()
            if named:
                return w
            visible = (hwnd is not None and bool(_user32.IsWindowVisible(hwnd))) \
                or bool(_safe(w.is_visible))
            if not visible or iconic:
                continue
            r = _safe(w.rectangle)
            if fallback is None and r and (r.right - r.left) > 300 \
                    and (r.bottom - r.top) > 300:
                fallback = w
        time.sleep(1.0)
    return fallback


def enable_ax() -> bool:
    """等价 macOS 的 AXManualAccessibility: 找窗口 + 预热 Chromium a11y。"""
    global _wrap, _poked
    w = find_window(timeout=8 if _wrap is not None else 20)
    if w is None:
        return False
    _wrap = w
    if not _poked:
        _safe(lambda: w.children())  # 浅碰一次, 触发 renderer a11y
        time.sleep(1.5)
        _poked = True
    return True


def app_ready() -> bool:
    global _wrap
    w = find_window(timeout=3)
    if w is not None:
        _wrap = w
    return w is not None


def fast_available() -> bool:
    return True


def launch() -> bool:
    """启动 Connect (登录态复用已有)。"""
    out = subprocess.run(['tasklist', '/fi', 'imagename eq Bambu Connect.exe'],
                         capture_output=True, text=True).stdout
    if 'Bambu Connect.exe' not in out:
        os.makedirs(os.path.dirname(_EXE), exist_ok=True)
        subprocess.Popen([_EXE], cwd=os.path.dirname(_EXE))
    return app_ready()


# ---------------------------------------------------------------- 遍历
def _snapshot():
    """一遍全量遍历 -> [(wrapper, type, name, auto, rect)]。"""
    from pywinauto import Desktop
    global _wrap
    if _wrap is None and not enable_ax():
        return []
    try:
        wins = Desktop(backend='uia').windows(top_level_only=True)
        for w in wins:
            if w.element_info.class_name == _WIN_CLASS \
                    and 'bambu' in (w.element_info.name or '').lower():
                _wrap = w
                break
        root = _wrap
        if root is None:
            return []
    except Exception:
        return []
    out = []

    def walk(c, depth, maxdepth=16, maxnodes=8000):
        if depth > maxdepth or len(out) > maxnodes:
            return
        try:
            kids = c.children()
        except Exception:
            return
        for k in kids:
            ei = k.element_info
            out.append((k, ei.control_type, ei.name, ei.automation_id,
                        _safe(k.rectangle)))
            walk(k, depth + 1, maxdepth, maxnodes)

    walk(root, 0)
    return out


def _click(c) -> bool:
    """优先 UIA Invoke(不动鼠标), 失败退真实点击。"""
    if _safe(lambda: c.invoke()) is True:
        return True
    try:
        c.click_input()
        return True
    except Exception as e:
        _log('click_input fail:', e)
        return False


# ---------------------------------------------------------------- 读
def texts() -> list[str]:
    return [n for (_, t, n, _, _) in _snapshot() if t == 'Text' and n]


def text_items() -> list[dict]:
    return [{'text': n, 'rect': [r.left, r.top, r.right, r.bottom]}
            for (_, t, n, _, r) in _snapshot() if t == 'Text' and n and r]


def labels() -> list[str]:
    return [n for (_, t, n, _, _) in _snapshot()
            if t in ('Button', 'MenuItem', 'Hyperlink', 'Image', 'Group')
            and n]


def buttons() -> list[dict]:
    out = []
    for (_, t, n, au, r) in _snapshot():
        if t == 'Button' and r:
            out.append({'name': n or '', 'desc': au or '',
                        'rect': [r.left, r.top, r.right, r.bottom]})
    return out


def has_text(want: str) -> bool:
    return want in texts()


def probe(texts: list[str] | None = None,
          buttons: list[str] | None = None) -> dict:
    """一次遍历确认若干文本/按钮是否在树上 (drive._enter 用)。"""
    snap = _snapshot()
    tset = {n for (_, t, n, _, _) in snap if t == 'Text' and n}
    bset = {n for (_, t, n, _, _) in snap
            if t in ('Button', 'MenuItem', 'Hyperlink') and n}
    return {
        # 文本用子串匹配: 标记常带装饰后缀 (列表头实际是「设备名称 ↑」,
        # 精确匹配永远 False, 2026-10-28 实测把 _enter 卡死在列表探测上)
        'texts': {t: any(t in n for n in tset) for t in (texts or [])},
        'buttons': {b: (b in bset) for b in (buttons or [])},
    }


# ---------------------------------------------------------------- 点击
def _find_named(want: str):
    for (c, t, n, au, r) in _snapshot():
        if n == want or au == want:
            if t in ('Button', 'MenuItem', 'Hyperlink', 'Text', 'Image',
                     'Group', 'ListItem', 'Pane', 'Document'):
                return c
    return None


def _find_named_prefix(want: str):
    """宽松兜底: 卡片文本是「<名> 热床: .. 状态」拼接, 名字在前。

    startswith 而不是 in —— 避免撞上正文里恰好包含名字的长句
    (如停止确认框标题「您确定要…」)。(2026-10-28)
    """
    if not want:
        return None
    cands = [x for x in _snapshot() if x[2] and x[2].startswith(want)]
    for prefer in ('Hyperlink', 'Button', 'MenuItem', 'Text', 'ListItem'):
        for (c, t, n, au, r) in cands:
            if t == prefer:
                return c
    return cands[0][0] if cands else None


def press_text(want: str) -> bool:
    c = _find_named(want)
    return bool(c and _click(c))


def press_desc(desc: str) -> bool:
    c = _find_named(desc)
    if c is None:
        c = _find_named_prefix(desc)
    if c is not None:
        return _click(c)
    # 停止确认框兜底: 名字可能是 确定/确认 (结构待真机验证, 打日志摸清)
    for alt in ('确定', '确认', 'OK', '是'):
        c = _find_named(alt)
        if c is not None:
            _log('press_desc fallback named', alt)
            return _click(c)
    return False


def click_desc(want: str) -> bool:
    return press_desc(want)


def press_at(x: float, y: float) -> bool:
    from pywinauto import mouse
    try:
        mouse.click(coords=(int(x), int(y)))
        return True
    except Exception as e:
        _log('press_at fail:', e)
        return False


def click_at(x: float, y: float, timeout: int = 15) -> bool:
    return press_at(x, y)


def press_escape() -> bool:
    from pywinauto import keyboard
    try:
        keyboard.send_keys('{ESC}')
        return True
    except Exception as e:
        _log('press_escape fail:', e)
        return False


# ---------------------------------------------------------------- 控制
def press_control(name: str, cmd: str, slow: bool = False) -> dict:
    """详情页控制行: '跳过' 锚点 + 同行无名图标按钮 [暂停, 停止] (x 序)。

    返回 {pressed, reason, method, coord} —— 与 macOS 版契约一致。"""
    snap = _snapshot()
    tset = {n for (_, t, n, _, _) in snap if t == 'Text' and n}
    if '打印进度' not in tset:
        return {'pressed': False, 'reason': 'not_on_detail'}
    if name not in tset:
        return {'pressed': False, 'reason': 'wrong_printer'}

    skip = None
    for (c, t, n, _, r) in snap:
        if t == 'Button' and n == '跳过' and r:
            skip = (c, r)
            break
    if skip is None:
        return {'pressed': False, 'reason': 'idle_no_skip'}
    ry = skip[1]
    ymid = (ry.top + ry.bottom) / 2
    slots = []
    for (c, t, n, _, r) in snap:
        if t != 'Button' or n or not r:
            continue
        h = r.bottom - r.top
        if abs((r.top + r.bottom) / 2 - ymid) <= _CTRL_ROW_DY \
                and _CTRL_ROW_H[0] <= h <= _CTRL_ROW_H[1]:
            slots.append((r.left, c))
    slots.sort(key=lambda p: p[0])
    if not slots:
        return {'pressed': False, 'reason': 'idle_no_skip'}
    c = slots[0][1] if cmd in ('pause', 'resume') else slots[-1][1]
    r = _safe(lambda: c.rectangle())
    ok = _click(c)
    return {'pressed': bool(ok), 'method': 'uia',
            'coord': [r.left, r.top] if r else None,
            'reason': None if ok else 'click_fail'}


# ---------------------------------------------------------------- 发送页 (阶段3)
def send_target_device() -> str:
    return ''  # TODO(阶段3): 读发送页当前选中设备


def selector_frame() -> dict | None:
    return None  # TODO(阶段3): 发送页设备下拉几何


if __name__ == '__main__':
    # 冒烟: 只读, 不点击
    ok = enable_ax()
    print('window:', ok, repr(_wrap.element_info.name) if ok else None)
    if ok:
        t = texts()
        print('texts:', len(t), t[:14])
        print('probe 打印进度:', probe(texts=['打印进度']))
        print('buttons:', len(buttons()))
