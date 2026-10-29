"""Windows 选机 (发送弹窗下拉) 纯逻辑自测 (2026-10-29)。

真机回归来源: 盒子换盘日志
    picker value-zoom: vlines=['123 v', 'PEI', ...] hit=None
    picker geom: hit_line=False
    picker ocr[r0]: crop=520x250+790+182 raw=0 keep=0 []
当前值「123」被 OCR 读成「123 v」(chevron 当字母 v), 机名比对长度敏感
-> 0 分 -> 拿不到选择器几何 -> 裁图空 -> select-device 失败。
跑法: python3 -I test_win_pick.py  (不需要 Windows/Connect/真机)
"""
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

for name in ('bconnect_ax', 'bconnect_vision', 'bconnect_cloud',
             'bconnect_uia'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda attr: (lambda *a, **k: None)  # noqa: ARG005
    sys.modules[name] = m

import bconnect_print as bp  # noqa: E402

FAILS = []


def check(label, got, want):
    ok = got == want
    print(('PASS ' if ok else 'FAIL ') + label, '| got:', got, 'want:', want)
    if not ok:
        FAILS.append(label)


KNOWN = {'123': '03919D4A0803769',
         '拓竹A1宇树': '03919C440800189',
         '嘉兴': '03900D642905133'}

# 1) chevron 尾巴摘掉 (真机实测的几种写法)
for raw, want in (('123 v', '123'), ('123 V', '123'), ('123 v ', '123'),
                  ('123∨', '123'), ('123 ⌄', '123'),
                  ('拓竹A1宇树 v', '拓竹A1宇树'),
                  ('嘉兴 V', '嘉兴')):
    check('摘 chevron %r' % raw, bp._win_trim_chevron(raw), want)

# 2) 不误伤: 正常名字/别的文本保持原样
for raw in ('123', 'PEI', '打印进度', 'Bambu Connect Beta', '拓竹A1宇树'):
    check('不动 %r' % raw, bp._win_trim_chevron(raw), raw)

# 3) 回归: 不摘时「123 v」对「123」是 0 分 (长度敏感, 防误派)
check('未摘时 0 分', bp._name_score('123 v', '123'), 0.0)
check('摘后满分',
      bp._name_score(bp._win_trim_chevron('123 v'), '123'), 1.0)

# 4) 发送弹窗分类: 当前值是别的机器也要认得出来 (它提供选择器几何)
ocr = [{'name': '发送打印任务至', 'x': 585, 'y': 334, 'w': 200, 'h': 20},
       {'name': '123 v', 'x': 700, 'y': 380, 'w': 40, 'h': 18},
       {'name': 'PEI', 'x': 700, 'y': 420, 'w': 30, 'h': 18}]
check('认出「123 v」是已知机器',
      bp._win_lines_hit_printer(ocr, KNOWN, '拓竹A1宇树'), '123 v')

# 5) 安全网还在: 长度不同的机器名仍然不匹配
check('拓竹A1宇树2 不算 拓竹A1宇树',
      bp._name_score('拓竹A1宇树2', '拓竹A1宇树'), 0.0)
check('陌生名字不给分',
      bp._name_score(bp._win_trim_chevron('AK47 v'), '123'), 0.0)

print()
print('== %s ==' % ('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
