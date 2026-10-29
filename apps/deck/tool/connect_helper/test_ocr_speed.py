"""Windows OCR 调速逻辑离线自测 (2026-10-29)。

打真鼠标之前先把纯逻辑锁住: 触发器锚点 (LED灯 行左边的百分比)、
菜单项坐标换算 (zoom 2.5x 反算)、确认判定。
合成 OCR 行取自 2026-10-29 详情页实测标定。
跑法: python3 -I test_ocr_speed.py  (不需要 Windows/Connect/真机)
"""
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# 打桩: 顶层 import 的云端/视觉模块会联网, 这里只要纯函数
for name in ('bconnect_ax', 'bconnect_vision', 'bconnect_cloud',
             'bconnect_uia', 'bconnect_print'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda attr: (lambda *a, **k: None)  # noqa: ARG005
    sys.modules[name] = m
# bconnect_print._name_score 是真逻辑, 但驱动要 import 它 -> 换成真模块
del sys.modules['bconnect_print']
import bconnect_print as bp  # noqa: E402

import bconnect_drive as drv  # noqa: E402

# 详情页实测标定: 打印进度 (64,191); 拓竹A1宇树 (66,132); 打印中 (196,267);
# 进度 % (1055,330); 速度 100% (1349,507); LED灯 (1446,507)
DETAIL_LINES = [
    {'name': '打印进度', 'x': 64, 'y': 191},
    {'name': '拓竹A1宇树', 'x': 66, 'y': 132},
    {'name': '打印中', 'x': 196, 'y': 267},
    {'name': '44%', 'x': 1055, 'y': 330},
    {'name': '100%', 'x': 1349, 'y': 507},
    {'name': 'LED灯', 'x': 1446, 'y': 507},
]

FAILS = []


def check(label, got, want):
    ok = got == want
    print(('PASS ' if ok else 'FAIL ') + label, '| got:', got, 'want:', want)
    if not ok:
        FAILS.append(label)


def fake_lines(lines):
    drv._ocr_lines = lambda: lines


# 1) 触发器 = LED灯 行左侧同行的百分比
fake_lines(DETAIL_LINES)
t = drv._ocr_speed_trigger('宇树')
check('触发器文本', t['text'] if t else None, '100%')
check('触发器 x', round(t['x']) if t else None, 1349)
check('触发器 y', round(t['y']) if t else None, 507)

# 2) 不是这台机 / 不在详情页 / 空闲 -> None
fake_lines(DETAIL_LINES)
check('别的机器返回 None', drv._ocr_speed_trigger('别的机器'), None)
fake_lines([{'name': '打印', 'x': 228, 'y': 47}])
check('非详情页返回 None', drv._ocr_speed_trigger('宇树'), None)
fake_lines([l for l in DETAIL_LINES if l['name'] != '打印中'])
check('空闲返回 None', drv._ocr_speed_trigger('宇树'), None)

# 3) 异行百分比(风扇)不能被选中
fake_lines(DETAIL_LINES + [{'name': '100%', 'x': 1200, 'y': 620}])
t = drv._ocr_speed_trigger('宇树')
check('异行百分比不被选', round(t['x']) if t else None, 1349)

# 4) 同行多个百分比取最靠近 LED灯 的
fake_lines(DETAIL_LINES + [{'name': '50%', 'x': 1250, 'y': 507}])
t = drv._ocr_speed_trigger('宇树')
check('同行多百分比取靠近 LED', round(t['x']) if t else None, 1349)

# 5) 全角 ％ / 缺 % 号 / 中间带空格 都要认
for variant in ('100％', '100', '100 %'):
    ls = [dict(l) for l in DETAIL_LINES]
    for l in ls:
        if l['name'] == '100%':
            l['name'] = variant
    fake_lines(ls)
    t = drv._ocr_speed_trigger('宇树')
    check('变体 %r 可识别' % variant, bool(t) and t['text'] == variant, True)

# 6) 菜单坐标换算: crop box=(1219,512), zoom 2.5x, 反算回原图
#    zoom (340,45) -> 原图 (1219+340/2.5, 512+45/2.5) = (1355, 530)
BOX = (1219, 512)
ZOOM = 2.5
for name, zx, zy, want in (('静音', 340.0, 45.0, (1355, 530)),
                           ('标准', 340.0, 105.0, (1355, 554)),
                           ('运动', 340.0, 165.0, (1355, 578)),
                           ('狂暴', 340.0, 225.0, (1355, 602))):
    x = BOX[0] + zx / ZOOM
    y = BOX[1] + zy / ZOOM
    check('菜单 %s 坐标反算' % name, (round(x), round(y)), want)

# 7) 档位映射齐全 (level 1-4)
for lv in (1, 2, 3, 4):
    check('level %d 有标签' % lv, bool(drv._SPEED_LABELS.get(lv)), True)
    check('level %d 有百分比' % lv, drv._SPEED_PCT.get(lv) is not None, True)

print()
print('== %s ==' % ('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
