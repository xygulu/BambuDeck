#!/usr/bin/env python3
"""稳的 AX 遍历器（JXA 手动递归），替代不可靠的 `entire contents`。

背景（2026-10-21 实测，Bambu Connect 2.5.0-beta.15 / Electron）：
  - `entire contents of window 1` 会间歇返回 0 个元素，即使窗口有子元素；
    这是 Electron/Chromium 的 AX 树在页面切换时重建导致的。
  - 靠它找按钮 → 间歇性「找不到按钮」→ 就是发送点不动的根因。
  - 解法：用 UI elements 逐层递归，自己收集；并在每次轮询前重置 AXManualAccessibility。

用法：
  python bconnect_ax.py                 # dump 当前所有按钮
  python bconnect_ax.py --press 发送     # 按文字点
  python bconnect_ax.py --press-desc confirm
"""
from __future__ import annotations

import json
import subprocess
import sys

APP = "Bambu Connect"

# 快速路径：直接调 AX API（ctypes），比 osascript/System Events 快 20 倍以上
# （同样一棵树 0.1~0.2s vs 4~6s）。仅当本进程已获「辅助功能」授权且 Connect 在跑
# 时可用；否则下面各函数自动回退到原来的 System Events 老路径。
try:
    import bconnect_axfast as _fast
except Exception:  # noqa: BLE001  （缺库/无 ctypes 时不影响老路径）
    _fast = None


def _fast_ok() -> bool:
    return _fast is not None and _fast.available()

# JXA：手动递归 walk UI elements，收集 AXButton 的信息
_WALK_JS = r"""
function run(argv) {
  var appName = argv[0];
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var out = [];

  function s(v) {
    if (v === null || v === undefined) return "";
    try { return String(v); } catch (e) { return ""; }
  }

  function walk(el, depth) {
    if (depth > 14 || out.length > 400) return;
    var kids;
    try { kids = el.uiElements(); } catch (e) { return; }
    var n = 0;
    try { n = kids.length; } catch (e) { return; }
    for (var i = 0; i < n; i++) {
      var k = kids[i], role = "";
      try { role = s(k.role()); } catch (e) { continue; }
      if (role === "AXButton") {
        var lbl = "";
        try { lbl += s(k.name()); } catch (e) {}
        try { lbl += s(k.value()); } catch (e) {}
        var sub = [];
        try {
          var cs = k.uiElements();
          for (var j = 0; j < cs.length; j++) {
            try { lbl += s(cs[j].name()); } catch (e) {}
            try { lbl += s(cs[j].value()); } catch (e) {}
          }
        } catch (e) {}
        var d = "", pos = [], size = [];
        try { d = s(k.description()); } catch (e) {}
        try { pos = k.position(); } catch (e) {}
        try { size = k.size(); } catch (e) {}
        out.push({ label: lbl, desc: d, pos: pos, size: size, path: [depth, i] });
      }
      walk(k, depth + 1);
    }
  }

  var wins;
  try { wins = proc.windows(); } catch (e) { return JSON.stringify({ error: "no windows: " + e, buttons: [] }); }
  for (var w = 0; w < wins.length; w++) { walk(wins[w], 0); }
  return JSON.stringify({ buttons: out });
}
"""

_PRESS_JS = r"""
function run(argv) {
  var appName = argv[0], mode = argv[1], want = argv[2];
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var hit = null;

  function s(v) {
    if (v === null || v === undefined) return "";
    try { return String(v); } catch (e) { return ""; }
  }

  function label(k) {
    var lbl = "";
    try { lbl += s(k.name()); } catch (e) {}
    try { lbl += s(k.value()); } catch (e) {}
    try {
      var cs = k.uiElements();
      for (var j = 0; j < cs.length; j++) {
        try { lbl += s(cs[j].name()); } catch (e) {}
        try { lbl += s(cs[j].value()); } catch (e) {}
      }
    } catch (e) {}
    return lbl;
  }

  function walk(el, depth) {
    if (hit || depth > 14) return;
    var kids;
    try { kids = el.uiElements(); } catch (e) { return; }
    for (var i = 0; i < kids.length; i++) {
      if (hit) return;
      var k = kids[i], role = "";
      try { role = s(k.role()); } catch (e) { continue; }
      if (role === "AXButton") {
        var ok = false;
        if (mode === "desc") {
          var d = "";
          try { d = s(k.description()); } catch (e) {}
          ok = (d === want);
        } else {
          ok = (label(k).indexOf(want) >= 0);
        }
        if (ok) { hit = k; return; }
      }
      walk(k, depth + 1);
    }
  }

  var wins;
  try { wins = proc.windows(); } catch (e) { return "no_windows"; }
  for (var w = 0; w < wins.length && !hit; w++) { walk(wins[w], 0); }
  if (!hit) return "notfound";
  try {
    hit.actions.byName("AXPress").perform();
    return "pressed";
  } catch (e) {
    try { hit.click(); return "clicked"; } catch (e2) { return "failed: " + e2; }
  }
}
"""


def _osa_js(js: str, *args: str, timeout: int = 120) -> tuple[int, str, str]:
    cmd = ["osascript", "-l", "JavaScript", "-e", js]
    if args:
        cmd.append("--")
        cmd.extend(args)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def enable_ax() -> bool:
    """Electron 的 web 内容需要显式打开 AX；窗口重建后要重设。"""
    if _fast_ok():
        return _fast.enable_ax()
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to tell process "%s" '
         'to set value of attribute "AXManualAccessibility" to true' % APP],
        capture_output=True, text=True, timeout=60)
    return r.returncode == 0


def buttons() -> list[dict]:
    if _fast_ok():
        return _fast.buttons()
    rc, out, err = _osa_js(_WALK_JS, APP)
    if rc != 0:
        raise RuntimeError("AX dump 失败: %s" % (err or out))
    try:
        data = json.loads(out)
    except ValueError:
        raise RuntimeError("AX dump 返回非 JSON: %s" % out[:200])
    return data.get("buttons", [])


def labels() -> list[str]:
    return [b["label"] for b in buttons() if b.get("label")]


_TEXT_JS = r"""
function run(argv) {
  var se = Application("System Events");
  var proc = se.processes.byName(argv[0]);
  var out = [];
  function s(v){ if(v===null||v===undefined) return ""; try{return String(v);}catch(e){return "";} }
  function walk(el, d) {
    if (d > 14 || out.length > 300) return;
    var kids; try { kids = el.uiElements(); } catch(e){ return; }
    for (var i=0;i<kids.length;i++){
      var k=kids[i], role="";
      try{ role=s(k.role()); }catch(e){ continue; }
      if (role==="AXStaticText"||role==="AXHeading"||role==="AXTextField"||role==="AXTextArea"){
        var t=""; try{t=s(k.value());}catch(e){}
        if(!t){ try{t=s(k.name());}catch(e){} }
        if(t) out.push(t);
      }
      walk(k, d+1);
    }
  }
  var ws; try{ ws=proc.windows(); }catch(e){ return "[]"; }
  for(var w=0; w<ws.length; w++) walk(ws[w], 0);
  return JSON.stringify(out);
}
"""


def texts() -> list[str]:
    """当前界面所有可见文字（用于判断停在哪一页）。"""
    if _fast_ok():
        return _fast.texts()
    rc, out, err = _osa_js(_TEXT_JS, APP)
    if rc != 0:
        return []
    try:
        return json.loads(out)
    except ValueError:
        return []


def has_text(want: str) -> bool:
    return any(want in t for t in texts())


def press_text(want: str) -> bool:
    if _fast_ok() and _fast.press_text(want):
        return True
    rc, out, _ = _osa_js(_PRESS_JS, APP, "text", want)
    return rc == 0 and out in ("pressed", "clicked")


def press_desc(desc: str) -> bool:
    if _fast_ok() and _fast.press_desc(desc):
        return True
    rc, out, _ = _osa_js(_PRESS_JS, APP, "desc", desc)
    return rc == 0 and out in ("pressed", "clicked")


# 按「屏幕坐标」定位按钮并 AXPress（用于无名字/无描述的纯图标按钮，如暂停/停止）。
_PRESS_AT_JS = r"""
function run(argv) {
  var appName = argv[0], tx = parseFloat(argv[1]), ty = parseFloat(argv[2]);
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var hit = null;
  function walk(el, depth) {
    if (hit || depth > 14) return;
    var kids;
    try { kids = el.uiElements(); } catch (e) { return; }
    for (var i = 0; i < kids.length; i++) {
      if (hit) return;
      var k = kids[i], role = "";
      try { role = String(k.role()); } catch (e) { continue; }
      if (role === "AXButton") {
        var pos = [], size = [];
        try { pos = k.position(); } catch (e) {}
        try { size = k.size(); } catch (e) {}
        if (pos.length >= 2 && size.length >= 2) {
          var x = pos[0], y = pos[1], w = size[0], h = size[1];
          if (tx >= x - 3 && tx <= x + w + 3 && ty >= y - 3 && ty <= y + h + 3) {
            hit = k; return;
          }
        }
      }
      walk(k, depth + 1);
    }
  }
  var ws;
  try { ws = proc.windows(); } catch (e) { return "no_windows"; }
  for (var w = 0; w < ws.length && !hit; w++) { walk(ws[w], 0); }
  if (!hit) return "notfound";
  try { hit.actions.byName("AXPress").perform(); return "pressed"; }
  catch (e) {
    try { hit.click(); return "clicked"; }
    catch (e2) { return "failed: " + e2; }
  }
}
"""


def press_at(x: float, y: float) -> bool:
    """点「包含 (x,y)」的按钮（屏幕坐标，含 3px 容差）。"""
    if _fast_ok() and _fast.press_at(x, y):
        return True
    rc, out, _ = _osa_js(_PRESS_AT_JS, APP, str(x), str(y))
    return rc == 0 and out in ("pressed", "clicked")


# 点「包含 (x,y)」的任意可点元素（AXButton/AXLink/AXCell/AXImage/…），
# 取最小（最深）的那个。纯图标按钮、面包屑链接、打印机卡片都用它。
_PRESS_ANY_AT_JS = r"""
function run(argv) {
  var appName = argv[0], tx = parseFloat(argv[1]), ty = parseFloat(argv[2]);
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var CLICKABLE = { AXButton: 1, AXLink: 1, AXCell: 1, AXImage: 1,
                    AXRadioButton: 1, AXCheckBox: 1, AXPopUpButton: 1, AXMenuItem: 1 };
  var best = null, bestArea = 1e9;
  function walk(el, depth) {
    if (depth > 16) return;
    var kids;
    try { kids = el.uiElements(); } catch (e) { return; }
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i], role = "";
      try { role = String(k.role()); } catch (e) { continue; }
      var pos = [], size = [];
      try { pos = k.position(); } catch (e) {}
      try { size = k.size(); } catch (e) {}
      if (pos.length >= 2 && size.length >= 2 && size[0] > 0 && size[1] > 0) {
        var x = pos[0], y = pos[1], w = size[0], h = size[1];
        if (tx >= x && tx <= x + w && ty >= y && ty <= y + h) {
          if (CLICKABLE[role]) {
            var area = w * h;
            if (area < bestArea) { bestArea = area; best = k; }
          }
        }
      }
      walk(k, depth + 1);
    }
  }
  var ws;
  try { ws = proc.windows(); } catch (e) { return "no_windows"; }
  for (var w = 0; w < ws.length; w++) { walk(ws[w], 0); }
  if (!best) return "notfound";
  try { best.actions.byName("AXPress").perform(); return "pressed"; }
  catch (e1) {
    try { best.click(); return "clicked"; }
    catch (e2) { return "failed: " + e2; }
  }
}
"""


def press_at_any(x: float, y: float) -> bool:
    """点「包含 (x,y)」的任意可点元素（屏幕坐标，取最深）。"""
    if _fast_ok() and _fast.press_at_any(x, y):
        return True
    rc, out, _ = _osa_js(_PRESS_ANY_AT_JS, APP, str(x), str(y))
    return rc == 0 and out in ("pressed", "clicked")


# 按 description/name 点任意可点元素（面包屑「我的打印机」、导航「设备/打印」等 AXLink）。
_PRESS_DESC_JS = r"""
function run(argv) {
  var appName = argv[0], want = argv[1];
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var hit = null;
  function s(v) { if (v === null || v === undefined) return ""; try { return String(v); } catch (e) { return ""; } }
  function walk(el, depth) {
    if (hit || depth > 16) return;
    var kids;
    try { kids = el.uiElements(); } catch (e) { return; }
    for (var i = 0; i < kids.length; i++) {
      if (hit) return;
      var k = kids[i], role = "";
      try { role = s(k.role()); } catch (e) { continue; }
      if (role === "AXButton" || role === "AXLink" || role === "AXCell" ||
          role === "AXImage" || role === "AXRadioButton" || role === "AXCheckBox" ||
          role === "AXPopUpButton" || role === "AXMenuItem") {
        var d = "", n = "";
        try { d = s(k.description()); } catch (e) {}
        try { n = s(k.name()); } catch (e) {}
        if (d === want || n === want || d.indexOf(want) >= 0 || n.indexOf(want) >= 0) { hit = k; return; }
      }
      walk(k, depth + 1);
    }
  }
  var ws;
  try { ws = proc.windows(); } catch (e) { return "no_windows"; }
  for (var w = 0; w < ws.length && !hit; w++) { walk(ws[w], 0); }
  if (!hit) return "notfound";
  try { hit.actions.byName("AXPress").perform(); return "pressed"; }
  catch (e1) {
    try { hit.click(); return "clicked"; }
    catch (e2) { return "failed: " + e2; }
  }
}
"""


def click_desc(want: str) -> bool:
    """按 description/name 点任意可点元素（用于 AXLink 导航）。"""
    if _fast_ok() and _fast.press_desc_any(want):
        return True
    rc, out, _ = _osa_js(_PRESS_DESC_JS, APP, want)
    return rc == 0 and out in ("pressed", "clicked")


# 短路探测：一次递归遍历，同时找多个文字/按钮，找到即停。
# 比 texts()+buttons() 两次全量遍历快（全量 ~9s/次，短路 ~2s）。
_PROBE_JS = r"""
function run(argv) {
  var appName = argv[0], spec = JSON.parse(argv[1]);
  var wt = spec.texts || [], wb = spec.buttons || [];
  var ft = {}, fb = {}, needT = wt.length, needB = wb.length;
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  function s(v){ if(v===null||v===undefined) return ""; try{return String(v);}catch(e){return "";} }
  function done(){ return needT === 0 && needB === 0; }
  function walk(el, depth) {
    if (done() || depth > 16) return;
    var kids;
    try { kids = el.uiElements(); } catch(e){ return; }
    for (var i=0;i<kids.length;i++){
      if (done()) return;
      var k=kids[i], role="";
      try{ role=s(k.role()); }catch(e){ continue; }
      if (needT>0 && (role==="AXStaticText"||role==="AXHeading"||role==="AXTextField"||role==="AXTextArea")){
        var t=""; try{ t=s(k.value())||s(k.name()); }catch(e){}
        if (t) {
          for (var a=0;a<wt.length;a++){
            if (ft[wt[a]]===undefined && t.indexOf(wt[a])>=0){ ft[wt[a]]=t; needT--; }
          }
        }
      }
      if (needB>0 && role==="AXButton"){
        var lbl="", d="";
        try{ lbl=s(k.name())+s(k.value()); }catch(e){}
        try{ d=s(k.description()); }catch(e){}
        try { var cs=k.uiElements(); for(var j=0;j<cs.length;j++){ lbl+=s(cs[j].name())+s(cs[j].value()); } } catch(e){}
        var full = lbl + d;
        for (var b=0;b<wb.length;b++){
          if (fb[wb[b]]===undefined && full.indexOf(wb[b])>=0){
            var pos=[], size=[];
            try{ pos=k.position(); }catch(e){}
            try{ size=k.size(); }catch(e){}
            fb[wb[b]]={label:full, pos:pos, size:size}; needB--;
          }
        }
      }
      walk(k, depth+1);
    }
  }
  var ws; try{ ws=proc.windows(); }catch(e){ return "no_windows"; }
  for(var w=0; w<ws.length && !done(); w++) walk(ws[w], 0);
  return JSON.stringify({texts: ft, buttons: fb});
}
"""


def probe(texts: list[str] | None = None, buttons: list[str] | None = None) -> dict:
    """一次短路遍历，同时找多个文字/按钮；找到即停。

    返回 {"texts": {want: 命中文字}, "buttons": {want: {label,pos,size}}}。
    找不到的 want 不出现在对应 dict 里。"""
    if _fast_ok():
        return _fast.probe(list(texts or []), list(buttons or []))
    spec = json.dumps({"texts": texts or [], "buttons": buttons or []})
    rc, out, err = _osa_js(_PROBE_JS, APP, spec)
    if rc != 0 or out in ("no_windows", ""):
        return {"texts": {}, "buttons": {}}
    try:
        return json.loads(out)
    except ValueError:
        return {"texts": {}, "buttons": {}}


# 发送页目标机名：设备选择器 AXGroup 的 description 形如「{名} chevron_down」。
# 读它来确定打印/换盘实际会派到哪台（2026-10-23 一键换盘误派：之前从不选机，
# 派单目标全看 Connect 当前选中的机器）。
_SEND_TARGET_JS = r"""
function run(argv) {
  var se = Application("System Events");
  var proc = se.processes.byName(argv[0]);
  var hit = "";
  function s(v){ if(v===null||v===undefined) return ""; try{return String(v);}catch(e){return "";} }
  function walk(el, d) {
    if (hit || d > 18) return;
    var kids;
    try { kids = el.uiElements(); } catch(e){ return; }
    for (var i=0;i<kids.length;i++){
      if (hit) return;
      var k = kids[i], role="", desc="";
      try{ role=s(k.role()); }catch(e){}
      try{ desc=s(k.description()); }catch(e){}
      if (role === "AXGroup" && desc.indexOf("chevron_down") >= 0) {
        hit = desc.replace("chevron_down", "").trim();
        return;
      }
      walk(k, d+1);
    }
  }
  var ws;
  try { ws = proc.windows(); } catch(e){ return ""; }
  for (var w=0; w<ws.length && !hit; w++) walk(ws[w], 0);
  return hit;
}
"""


def send_target_device() -> str:
    """发送页当前目标打印机名；不在发送页/读不到时返回空串。"""
    if _fast_ok():
        return _fast.send_target_device()
    rc, out, _ = _osa_js(_SEND_TARGET_JS, APP)
    if rc != 0:
        return ""
    return (out or "").strip()


# 发送页设备选择器（下拉）的几何信息 + 真实鼠标点击。
# 下拉选项不暴露在 macOS AX 树（AXShowMenu/AXRows/children 都读不到选项），
# 只能靠「真实鼠标点击像素坐标」选机。这里读两个锚：
#   group  = 含 chevron_down 的 AXGroup 的 {x,y,w,h}（用于算下拉项坐标）
#   chevron = 下拉箭头 AXImage 的中心 (x,y)（用于展开下拉）
_SELECTOR_JS = r"""
function run(argv) {
  var se = Application("System Events");
  var proc = se.processes.byName(argv[0]);
  var group = null, chevron = null;
  function s(v){ if(v===null||v===undefined) return ""; try{return String(v);}catch(e){return "";} }
  function walk(el, d) {
    if ((group && chevron) || d > 18) return;
    var kids;
    try { kids = el.uiElements(); } catch(e){ return; }
    for (var i=0;i<kids.length;i++){
      if (group && chevron) return;
      var k = kids[i], role="", desc="";
      try{ role=s(k.role()); }catch(e){}
      try{ desc=s(k.description()); }catch(e){}
      if (!group && role === "AXGroup" && desc.indexOf("chevron_down") >= 0) {
        var pos=[], size=[];
        try{ pos=k.position(); }catch(e){}
        try{ size=k.size(); }catch(e){}
        group = {x:pos[0], y:pos[1], w:size[0], h:size[1]};
      } else if (!chevron && role === "AXImage" && desc === "chevron_down") {
        var p=[], sz=[];
        try{ p=k.position(); }catch(e){}
        try{ sz=k.size(); }catch(e){}
        chevron = {x:p[0]+sz[0]/2, y:p[1]+sz[1]/2};
      }
      walk(k, d+1);
    }
  }
  var ws; try{ ws=proc.windows(); }catch(e){ return "null"; }
  for(var w=0; w<ws.length && !(group && chevron); w++) walk(ws[w], 0);
  return JSON.stringify({group: group, chevron: chevron});
}
"""


def fast_available() -> bool:
    return _fast_ok()


def app_ready() -> bool:
    """Connect 在最前且窗口已拿到键盘焦点（能接收合成点击）。"""
    if _fast_ok():
        return _fast.frontmost() and _fast.app_focused()
    return True


def selector_frame() -> dict | None:
    """发送页设备选择器的几何信息 {group:{x,y,w,h}, chevron:{x,y}}；读不到返回 None。"""
    if _fast_ok():
        info = _fast.send_info()
        if not info:
            return None
        return {"group": info["group"], "chevron": info.get("chevron")}
    rc, out, _ = _osa_js(_SELECTOR_JS, APP)
    if rc != 0 or out in ("null", ""):
        return None
    try:
        data = json.loads(out)
    except ValueError:
        return None
    if not data.get("group"):
        return None
    return {"group": data["group"], "chevron": data["chevron"]}


_CLICK_JS = r"""
ObjC.import('CoreGraphics');
function run(argv) {
  var x = parseFloat(argv[0]);
  var y = parseFloat(argv[1]);
  var pt = $.CGPointMake(x, y);
  var down = $.CGEventCreateMouseEvent($(), $.kCGEventLeftMouseDown, pt, $.kCGMouseButtonLeft);
  var up = $.CGEventCreateMouseEvent($(), $.kCGEventLeftMouseUp, pt, $.kCGMouseButtonLeft);
  $.CGEventPost($.kCGHIDEventTap, down);
  $.CGEventPost($.kCGHIDEventTap, up);
  return "ok";
}
"""


def click_at(x: float, y: float, timeout: int = 15) -> bool:
    """真实鼠标点击屏幕坐标。

    下拉选项不暴露在 AX 树（AX 点不动），也不能用 System Events 的 `click at`
    —— 它要先把屏幕坐标反解成前台 app 的 UI 元素再点，遇到 Chrome 等复杂内容会挂死。
    这里改用 CoreGraphics CGEvent 直接注入鼠标按下/抬起，不经过 AX 解析，快且稳。
    注意：点的是「该坐标上最顶层窗口」，所以调用前需确保 Connect 窗口在最前。
    """
    if _fast_ok():
        return _fast.click_at(x, y)
    rc, _out, _err = _osa_js(_CLICK_JS, str(x), str(y), timeout=timeout)
    return rc == 0


# 控制按钮：一次遍历同时「确认在 name 详情页 + 找跳过锚 + 找图标按钮 + 点」。
# 比 probe()+press_at() 两次遍历省 ~2s。图标按钮无 label，靠 (size≈30×32, y=跳过.y) 识别。
# 不遍历按钮子元素（「跳过」label 在按钮自身，不在子节点），进一步省时。
_PRESS_CONTROL_JS = r"""
function run(argv) {
  var appName = argv[0], name = argv[1], cmd = argv[2];
  var se = Application("System Events");
  var proc = se.processes.byName(appName);
  var nameFound = false, skip = null, icons = [];
  function s(v){ if(v===null||v===undefined) return ""; try{return String(v);}catch(e){return "";} }
  function done(){ return nameFound && skip && icons.length >= 2; }
  function walk(el, depth) {
    if (done() || depth > 16) return;
    var kids;
    try { kids = el.uiElements(); } catch(e){ return; }
    for (var i=0;i<kids.length;i++){
      if (done()) return;
      var k=kids[i], role="";
      try{ role=s(k.role()); }catch(e){ continue; }
      if (!nameFound && (role==="AXStaticText"||role==="AXHeading"||role==="AXTextField"||role==="AXTextArea")){
        var t=""; try{ t=s(k.value())||s(k.name()); }catch(e){}
        if (t && t.indexOf(name)>=0) nameFound = true;
      }
      if (role==="AXButton"){
        var lbl=""; try{ lbl=s(k.name())+s(k.value()); }catch(e){}
        var pos=[], size=[];
        try{ pos=k.position(); }catch(e){}
        try{ size=k.size(); }catch(e){}
        if (!skip && lbl.indexOf("跳过")>=0){
          skip = {ref:k, pos:pos, size:size};
        } else if (skip && lbl==="" && pos.length>=2 && size.length>=2 &&
                   size[0]>=28 && size[0]<=32 && size[1]>=30 && size[1]<=34 &&
                   pos[1]===skip.pos[1]){
          icons.push({ref:k, pos:pos, size:size});
        }
      }
      walk(k, depth+1);
    }
  }
  var ws; try{ ws=proc.windows(); }catch(e){ return JSON.stringify({pressed:false, reason:"no_windows"}); }
  for(var w=0; w<ws.length && !done(); w++) walk(ws[w], 0);
  if (!skip) return JSON.stringify({pressed:false, reason: nameFound ? "idle_no_skip" : "not_on_detail"});
  if (!nameFound) return JSON.stringify({pressed:false, reason:"wrong_printer"});
  if (icons.length < 2) return JSON.stringify({pressed:false, reason:"no_icons"});
  icons.sort(function(a,b){ return a.pos[0]-b.pos[0]; });
  var tgt = (cmd==="stop") ? icons[1] : icons[0];
  try {
    tgt.ref.actions.byName("AXPress").perform();
    return JSON.stringify({pressed:true, coord:[tgt.pos[0]+tgt.size[0]/2, tgt.pos[1]+tgt.size[1]/2]});
  } catch(e) {
    try { tgt.ref.click(); return JSON.stringify({pressed:true, coord:[tgt.pos[0]+tgt.size[0]/2, tgt.pos[1]+tgt.size[1]/2]}); }
    catch(e2){ return JSON.stringify({pressed:false, reason:"press_failed:"+e2}); }
  }
}
"""


def press_control(name: str, command: str, slow: bool = False) -> dict:
    """一次遍历：确认在 name 详情页 + 定位并点击控制按钮（pause/resume/stop）。

    返回 {"pressed": bool, "coord": [x,y], "reason": str}。reason 供上层决定是否导航：
      not_on_detail（不在详情页）/ wrong_printer（别的打印机详情）/ idle_no_skip（空闲无跳过）。

    快路径（ctypes 直读 AX）一次遍历 ~0.3s；osascript 版本同样一次遍历要 8s 左右
    （每个属性一次 AppleEvent 往返），只有快路径不可用、或调用方要求 slow 时才走慢路径。
    """
    if _fast_ok() and not slow:
        try:
            r = _fast.press_control(name, command)
        except Exception:  # noqa: BLE001  快路径异常不影响功能，回退慢路径
            r = None
        if r and not str(r.get("reason", "")).startswith("err:"):
            return r
    rc, out, err = _osa_js(_PRESS_CONTROL_JS, APP, name, command)
    if rc != 0 or out in ("", "no_windows"):
        return {"pressed": False, "reason": "err:%s" % (err or out)}
    try:
        return json.loads(out)
    except ValueError:
        return {"pressed": False, "reason": "bad_json:" + out[:120]}


def main() -> int:
    argv = sys.argv[1:]
    enable_ax()
    if "--press" in argv:
        want = argv[argv.index("--press") + 1]
        print("press_text(%r) ->" % want, press_text(want))
        return 0
    if "--press-desc" in argv:
        want = argv[argv.index("--press-desc") + 1]
        print("press_desc(%r) ->" % want, press_desc(want))
        return 0
    bs = buttons()
    print("buttons(%d):" % len(bs))
    for b in bs:
        print("  [%s] desc=%s pos=%s" % (b["label"], b["desc"], b["pos"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
