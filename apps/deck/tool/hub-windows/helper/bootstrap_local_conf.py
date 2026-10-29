# -*- coding: utf-8 -*-
"""派生 helper 用的本地配置 (2026-10-29)。

从包内 config\\hub.json 派生 ~/.bambudeck/helper.json 与 printers.json。
原来这段逻辑在 PowerShell 里 (bootstrap_helper.ps1), 但有两个坑:

1. **PowerShell 5.1 的 Get-Content 不带 -Encoding 时按系统 ANSI 解码**
   (中文机器 = GBK) → hub.json 里的 UTF-8 中文 (打印机名) 被解成乱码,
   写进 printers.json 后 helper 的「名字↔序列号」映射全乱。2026-10-29
   实测: 盒子上 printers.json 的名字已经变成 U+E076 私有区字符。
2. PowerShell 的读-改-写逻辑没法在开发机上验证 (没有 pwsh)。

改成 Python: 编码显式、逻辑可离线自测。bootstrap_helper.ps1 现在只做
「找 runtime 里的 python 并调它」, 不再碰编码。

用法: python bootstrap_local_conf.py [hub.json 路径]
"""
from __future__ import annotations

import json
import os
import sys

HUB_DEFAULT = r"C:\deck-hub-windows\config\hub.json"


def _read_json(path: str) -> dict:
    # utf-8-sig: 容忍 BOM (PowerShell Set-Content -Encoding UTF8 会带 BOM)
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def _write_json(path: str, obj: dict) -> None:
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    # utf-8 不带 BOM: helper 用 json.load 读, BOM 会直接炸
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)


def build(hub_path: str, home: str | None = None) -> tuple[dict, dict]:
    """返回 (helper.json 内容, printers.json 内容)。不落盘, 便于自测。"""
    hub = _read_json(hub_path)
    home = home or os.path.expanduser("~")

    helper = {"url": "http://127.0.0.1:8799",
              "token": str((hub.get("settings") or {}).get("helperToken") or "")}

    # 旧 printers.json 里的 ip 要保留: helper 有 ip 就优先走 LAN 直发,
    # 覆盖掉会让那条路的机器退化成 15s 超时才 fallback 到 Connect。
    # 名字一律以 hub.json 为准 —— 旧文件里的名字可能就是被 GBK 解码搞坏的。
    old_ip: dict[str, str] = {}
    lan_path = os.path.join(home, ".bambudeck", "printers.json")
    if os.path.exists(lan_path):
        try:
            with open(lan_path, encoding="utf-8-sig") as f:
                for serial, v in (json.load(f) or {}).items():
                    if isinstance(v, dict) and v.get("ip"):
                        old_ip[str(serial)] = str(v["ip"])
        except Exception:
            pass

    printers: dict[str, dict] = {}
    for p in hub.get("printers") or []:
        serial = str(p.get("serial") or "")
        if not serial:
            continue
        entry = {"name": str(p.get("name") or "")}
        if serial in old_ip:
            entry["ip"] = old_ip[serial]
        printers[serial] = entry
    return helper, printers


def main() -> int:
    hub_path = sys.argv[1] if len(sys.argv) > 1 else HUB_DEFAULT
    try:
        helper, printers = build(hub_path)
    except Exception as e:  # noqa: BLE001
        print("bootstrap failed: %s" % e)
        return 1
    home = os.path.expanduser("~")
    d = os.path.join(home, ".bambudeck")
    _write_json(os.path.join(d, "helper.json"), helper)
    _write_json(os.path.join(d, "printers.json"), printers)
    print("helperToken_set=%s printers=%d"
          % (bool(helper["token"]), len(printers)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
