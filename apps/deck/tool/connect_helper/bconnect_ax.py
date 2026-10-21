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
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to tell process "%s" '
         'to set value of attribute "AXManualAccessibility" to true' % APP],
        capture_output=True, text=True, timeout=60)
    return r.returncode == 0


def buttons() -> list[dict]:
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
    rc, out, _ = _osa_js(_PRESS_JS, APP, "text", want)
    return rc == 0 and out in ("pressed", "clicked")


def press_desc(desc: str) -> bool:
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
    spec = json.dumps({"texts": texts or [], "buttons": buttons or []})
    rc, out, err = _osa_js(_PROBE_JS, APP, spec)
    if rc != 0 or out in ("no_windows", ""):
        return {"texts": {}, "buttons": {}}
    try:
        return json.loads(out)
    except ValueError:
        return {"texts": {}, "buttons": {}}


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


def press_control(name: str, command: str) -> dict:
    """一次遍历：确认在 name 详情页 + 定位并点击控制按钮（pause/resume/stop）。

    返回 {"pressed": bool, "coord": [x,y], "reason": str}。reason 供上层决定是否导航：
      not_on_detail（不在详情页）/ wrong_printer（别的打印机详情）/ idle_no_skip（空闲无跳过）。"""
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
