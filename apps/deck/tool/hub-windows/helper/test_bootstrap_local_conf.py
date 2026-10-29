"""bootstrap_local_conf 的离线自测 (2026-10-29)。

要锁的三件事:
1. 中文打印机名原样透传 (曾经的 GBK 二次编码坑)。
2. 旧 printers.json 里的 ip 被保留, 名字以 hub.json 为准。
3. 落盘是 UTF-8 无 BOM, helper 的 json.load 不会炸。

跑法: python3 -I test_bootstrap_local_conf.py
"""
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import bootstrap_local_conf as blc  # noqa: E402

FAILS = []


def check(label, got, want):
    ok = got == want
    print(('PASS ' if ok else 'FAIL ') + label, '| got:', got, 'want:', want)
    if not ok:
        FAILS.append(label)


HUB = {
    'settings': {'helperToken': 'tok-abc', 'hubPort': 8787},
    'printers': [
        {'serial': '03919C440800189', 'name': '宇树', 'ip': '192.168.100.111'},
        {'serial': '03900D642905133', 'name': '嘉兴', 'ip': '192.168.100.117'},
        {'serial': '03919D4A0803769', 'name': '123', 'ip': '192.168.100.110'},
    ],
    'cameras': [
        {'id': 'c_1', 'name': '萤石 CTQ6X-200w'},
    ],
}

with tempfile.TemporaryDirectory() as td:
    hub_path = os.path.join(td, 'hub.json')
    with open(hub_path, 'w', encoding='utf-8') as f:
        json.dump(HUB, f, ensure_ascii=False)

    home = os.path.join(td, 'home')
    os.makedirs(os.path.join(home, '.bambudeck'))

    # 1) 干净环境: 中文名透传, 无 ip
    helper, printers = blc.build(hub_path, home=home)
    check('helper token', helper['token'], 'tok-abc')
    check('helper url', helper['url'], 'http://127.0.0.1:8799')
    check('打印机台数', len(printers), 3)
    check('中文名透传', printers['03919C440800189']['name'], '宇树')
    check('默认不带 ip', 'ip' in printers['03919C440800189'], False)

    # 2) 旧文件里的 ip 保留, 名字以 hub.json 为准 (旧名字是坏的)
    old = {'03919C440800189': {'name': '', 'ip': '10.0.0.9'}}
    with open(os.path.join(home, '.bambudeck', 'printers.json'), 'w',
              encoding='utf-8') as f:
        json.dump(old, f, ensure_ascii=False)
    _, printers = blc.build(hub_path, home=home)
    check('旧 ip 被保留', printers['03919C440800189'].get('ip'), '10.0.0.9')
    check('坏名字被 hub.json 覆盖',
          printers['03919C440800189']['name'], '宇树')
    check('没有旧记录的机器不带 ip', 'ip' in printers['03900D642905133'], False)

    # 3) 落盘: UTF-8 无 BOM, helper 的 json.load 能读
    p = os.path.join(home, '.bambudeck', 'helper.json')
    blc._write_json(p, helper)
    raw = open(p, 'rb').read()
    check('落盘无 BOM', raw[:3] != b'\xef\xbb\xbf', True)
    check('落盘是 UTF-8', json.loads(raw.decode('utf-8'))['token'], 'tok-abc')

    # 4) 带 BOM 的 hub.json 也能读 (PowerShell Set-Content 的产物)
    hub_bom = os.path.join(td, 'hub_bom.json')
    with open(hub_bom, 'w', encoding='utf-8-sig') as f:
        json.dump(HUB, f, ensure_ascii=False)
    _, printers2 = blc.build(hub_bom, home=home)
    check('带 BOM 的 hub.json 可读', printers2['03919C440800189']['name'], '宇树')

    # 5) 坏掉的旧 printers.json 不该让整个 bootstrap 崩
    with open(os.path.join(home, '.bambudeck', 'printers.json'), 'w',
              encoding='utf-8') as f:
        f.write('{ broken json')
    _, printers3 = blc.build(hub_path, home=home)
    check('坏旧文件不阻断', printers3['03919C440800189']['name'], '宇树')

print()
print('== %s ==' % ('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
