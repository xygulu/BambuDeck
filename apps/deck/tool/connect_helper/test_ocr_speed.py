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
fake_lines([l for l in DETAIL_LINES if l['name'] != '打印中']
           + [{'name': '在线', 'x': 168, 'y': 133}])
check('明确空闲返回 None', drv._ocr_speed_trigger('宇树'), None)
# 状态行整行漏读(没有「打印中」也没有「在线」)不算空闲, 继续找触发器
fake_lines([l for l in DETAIL_LINES if l['name'] != '打印中'])
check('状态漏读不当空闲', bool(drv._ocr_speed_trigger('宇树')), True)

# 3) 异行百分比(风扇)不能被选中
fake_lines(DETAIL_LINES + [{'name': '100%', 'x': 1200, 'y': 620}])
t = drv._ocr_speed_trigger('宇树')
check('异行百分比不被选', round(t['x']) if t else None, 1349)

# 4) 同行多个百分比取最靠近 LED灯 的
fake_lines(DETAIL_LINES + [{'name': '50%', 'x': 1250, 'y': 507}])
t = drv._ocr_speed_trigger('宇树')
check('同行多百分比取靠近 LED', round(t['x']) if t else None, 1349)

# 4b) 真机实测回归 (2026-10-29 探针): 温度行在 y=487 有孤立「0」,
#     速度在 y=507 是「124 ％」(全角)。必须选中 124%, 不能选温度那个 0。
REAL_LINES = [
    {'name': '打印进度', 'x': 64, 'y': 191},
    {'name': '拓竹A1宇树', 'x': 66, 'y': 132},
    {'name': '打印中', 'x': 196, 'y': 267},
    {'name': '0', 'x': 1445, 'y': 487},      # 温度行 (干扰)
    {'name': '0', 'x': 1325, 'y': 487},      # 温度行 (干扰)
    {'name': 'LED 灯', 'x': 1446, 'y': 507},
    {'name': '124 ％', 'x': 1325, 'y': 507},  # 真正的速度 (全角 ％)
]
fake_lines(REAL_LINES)
t = drv._ocr_speed_trigger('拓竹A1宇树')
check('真机回归: 选中速度而非温度',
      (t['text'], round(t['x']), round(t['y'])) if t else None,
      ('124 ％', 1325, 507))

# 4c) 同样的干扰, 但速度%只是纯数字 "124" (OCR 丢了 % 号)
NO_SIGN = [dict(l) for l in REAL_LINES]
for l in NO_SIGN:
    if l['name'] == '124 ％':
        l['name'] = '124'
fake_lines(NO_SIGN)
t = drv._ocr_speed_trigger('拓竹A1宇树')
check('真机回归: 无%号时也不选温度',
      (t['text'], round(t['y'])) if t else None, ('124', 507))

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

# 6b) 详情页判定: 多信号任一成立 (OCR 每帧行数在 19~36 浮动, 标题会漏读)
for sig, want in (('打印进度', True), ('LED灯', True), ('跳过', True),
                  ('已暂停', True), ('打印', False), ('', False)):
    check('详情页判定 %r' % sig, drv._ocr_on_detail(sig), want)

# 6b2) 状态判定: 只有明确读到空闲标记才算 idle, 漏读=unknown
for blob, want in (('打印中', 'printing'), ('已暂停', 'paused'),
                   ('在线', 'idle'), ('拓竹A1宇树LED灯124％', 'unknown')):
    check('状态判定 %r' % blob, drv._ocr_state(blob), want)

# 6c) 机名漏读兜底: 全屏 3 帧都没有机名 -> 走标题区放大重读
NO_NAME = [l for l in REAL_LINES if l['name'] != '拓竹A1宇树']
fake_lines(NO_NAME)
drv.time.sleep = lambda *_a, **_k: None
drv._ocr_header_name = lambda n: n == '拓竹A1宇树'
_ls, _blob, ok = drv._ocr_sense('拓竹A1宇树')
check('机名靠标题区放大救回', ok, True)
_ls, _blob, ok = drv._ocr_sense('别的机器')
check('标题区也不是这台 -> 拒绝', ok, False)

# 6d) 全屏有 3 帧都读不到机名时, 触发器仍能工作
t = drv._ocr_speed_trigger('拓竹A1宇树')
check('名字靠放大时触发器可用',
      (t['text'], round(t['x'])) if t else None, ('124 ％', 1325))

# 7) 档位映射齐全 (level 1-4)
for lv in (1, 2, 3, 4):
    check('level %d 有标签' % lv, bool(drv._SPEED_LABELS.get(lv)), True)
    check('level %d 有百分比' % lv, drv._SPEED_PCT.get(lv) is not None, True)

print()
print('== %s ==' % ('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
