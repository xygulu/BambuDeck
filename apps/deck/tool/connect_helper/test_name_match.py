"""机名匹配规则离线自测 (2026-10-29)。

真机没上线前先锁行为: 机型前缀容忍、同音错字、同前缀别机、状态后缀。
跑法: python3 -I test_name_match.py  (不需要 Windows/Connect, 纯函数)
"""
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# 打桩: 只测纯函数, 不碰 UIA/视觉/云端
for name in ('bconnect_ax', 'bconnect_vision', 'bconnect_cloud', 'bconnect_uia'):
    m = types.ModuleType(name)
    m.__getattr__ = lambda attr: (lambda *a, **k: None)  # noqa: ARG005
    sys.modules[name] = m
for name in ('paho', 'paho.mqtt', 'paho.mqtt.client'):
    sys.modules.setdefault(name, types.ModuleType(name))

import bconnect_print as bp  # noqa: E402

S_YUSHU = '03919C440800189'
S_123 = '03919D4A0803769'
S_OTHER = '03900D642905133'

KNOWN = {
    '宇树': S_YUSHU,
    '123': S_123,
    '嘉兴': S_OTHER,
}

cases = []


def check(label, got, want):
    ok = got == want
    cases.append((ok, label, got, want))


# --- _name_score -----------------------------------------------------------
check('完全一致=1.0', bp._name_score('宇树', '宇树'), 1.0)
check('带状态后缀仍算一致', bp._name_score('宇树 在线', '宇树'), 1.0)
check('机型前缀+完整名', bp._name_score('拓竹A1宇树', '宇树'), 0.90)
check('机型前缀(带空格)', bp._name_score('拓竹A1 宇树', '宇树'), 0.90)
check('同前缀别机 宇树2', bp._name_score('拓竹A1宇树2', '宇树'), 0.0)
check('相似度: 视觉同音错字', round(bp._name_score('拓竹A1字树', '拓竹A1宇树'), 3),
      round(0.8 + 0.19 * (5 / 6), 3))
check('相似度: 别机同前缀不算', bp._name_score('拓竹A1宇树2', '拓竹A1宇树'), 0.0)
check('长度不同=0 (无后缀规则命中)', bp._name_score('宇', '宇树'), 0.0)

# --- _win_target_shown -----------------------------------------------------
check('弹窗显示目标(裸名)', bp._win_target_shown({'宇树', 'B2'}, '宇树', KNOWN, S_YUSHU), '宇树')
check('弹窗显示目标(机型前缀)', bp._win_target_shown({'拓竹A1宇树', 'B2'}, '宇树', KNOWN, S_YUSHU),
      '拓竹A1宇树')
check('弹窗还是上一台的 123', bp._win_target_shown({'123', 'B2'}, '宇树', KNOWN, S_YUSHU), '')
check('弹窗显示别机的同前缀名', bp._win_target_shown({'拓竹A1宇树2'}, '宇树', KNOWN, S_YUSHU), '')
check('弹窗空文本', bp._win_target_shown(set(), '宇树', KNOWN, S_YUSHU), '')
check('known 为空时只按目标名比',
      bp._win_target_shown({'拓竹A1宇树'}, '宇树', {}, S_YUSHU), '拓竹A1宇树')
check('大宇树不算宇树(全局最高分属别机)',
      bp._win_target_shown({'拓竹A1大宇树'}, '宇树', {'宇树': S_YUSHU, '大宇树': S_OTHER},
                           S_YUSHU), '')
check('序列号不符时拒认', bp._win_target_shown({'宇树'}, '宇树', {'宇树': S_OTHER}, S_YUSHU), '')

# --- _win_parse_options ----------------------------------------------------
js = '{"options":[{"name":"拓竹A1宇树","x":100,"y":200},{"name":"123","point":[5,6]}]}'
check('选项解析', bp._win_parse_options(js),
      [{'name': '拓竹A1宇树', 'x': 100, 'y': 200}, {'name': '123', 'x': 5, 'y': 6}])
check('选项解析: 纯字符串丢弃', bp._win_parse_options('{"options":["abc"]}'), [])

# --- 候选排序 --------------------------------------------------------------
opts = [{'name': '拓竹A1宇树2', 'x': 1, 'y': 1},
        {'name': '拓竹A1 123', 'x': 2, 'y': 2},
        {'name': '拓竹A1宇树', 'x': 3, 'y': 3}]
opts.sort(key=lambda o: -bp._name_score(o['name'], '宇树'))
check('候选排序: 目标排第一', opts[0]['name'], '拓竹A1宇树')

bad = 0
for ok, label, got, want in cases:
    print(('PASS ' if ok else 'FAIL ') + label + ('' if ok else f'  got={got!r} want={want!r}'))
    bad += 0 if ok else 1
print(f'\n{len(cases) - bad}/{len(cases)} passed')
sys.exit(1 if bad else 0)
