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

# --- 空白/大小写归一 (对齐 Mac 侧 _norm_name) -------------------------------
check('归一: 去空白', bp._norm_printer_name('拓竹 A1 宇树'), '拓竹a1宇树')
check('归一: 去空白+状态后缀', bp._norm_printer_name('宇树 在线'), '宇树')
check('归一: 后缀无空格', bp._norm_printer_name('宇树在线'), '宇树')
check('空格差异也算同一台',
      bp._win_target_shown({'拓竹A1宇树'}, '拓竹 A1 宇树',
                           {'拓竹 A1 宇树': S_YUSHU}, S_YUSHU), '拓竹A1宇树')
check('大小写差异也算同一台',
      bp._win_target_shown({'A1-Jiaxing'}, 'a1-jiaxing',
                           {'a1-jiaxing': S_OTHER}, S_OTHER), 'A1-Jiaxing')
check('状态后缀不影响打分', bp._name_score('宇树 在线', '宇树'), 1.0)

# --- 本地 OCR 解析 (PowerShell 输出) ----------------------------------------
arr = ('[{"t":"拓竹A1宇树","x":100,"y":200,"w":120,"h":20},'
       '{"t":"123","x":100,"y":240,"w":60,"h":20}]')
check('OCR: 数组', bp._win_ocr_parse(arr),
      [{'name': '拓竹A1宇树', 'x': 100, 'y': 200, 'w': 120, 'h': 20},
       {'name': '123', 'x': 100, 'y': 240, 'w': 60, 'h': 20}])
check('OCR: 单对象也收', bp._win_ocr_parse('{"t":"123","x":1,"y":2,"w":3,"h":4}'),
      [{'name': '123', 'x': 1, 'y': 2, 'w': 3, 'h': 4}])
check('OCR: 空列表', bp._win_ocr_parse('[]'), [])
check('OCR: ERR=引擎不可用', bp._win_ocr_parse('ERR: no engine'), None)
check('OCR: 空输出', bp._win_ocr_parse(''), [])
check('OCR: 坐标缺=丢行',
      bp._win_ocr_parse('[{"t":"abc","x":1,"y":2},{"t":"def"}]'),
      [{'name': 'abc', 'x': 1, 'y': 2, 'w': 0, 'h': 0}])

# --- 本地分类 / 行命中 / 文件核对 --------------------------------------------
check('本地分类: 树里有已知名=send',
      bp._win_classify_local(['拓竹A1宇树', 'B2'], KNOWN, '宇树'), 'send')
check('本地分类: 机型文本不撞 (导入弹窗)',
      bp._win_classify_local(['A1', 'PLA', '11m', '0.4'], KNOWN, '宇树'), '')
check('本地分类: 空树', bp._win_classify_local([], KNOWN, '宇树'), '')
check('本地分类: 别机的机型前缀名也足以判定=send (目标对错由核对管)',
      bp._win_classify_local(['拓竹A1大宇树'], {'大宇树': S_OTHER}, '宇树'), 'send')
check('行命中: OCR 里有机名',
      bp._win_lines_hit_printer([{'name': '拓竹A1宇树', 'x': 0, 'y': 0}],
                                KNOWN, '宇树'), '拓竹A1宇树')
check('行命中: 导入弹窗文本不撞',
      bp._win_lines_hit_printer([{'name': 'A1', 'x': 0, 'y': 0},
                                 {'name': 'PLA', 'x': 0, 'y': 0}],
                                KNOWN, '宇树'), '')
check('行命中: OCR 空', bp._win_lines_hit_printer([], KNOWN, '宇树'), '')
check('文件核对: 命中主干',
      bp._win_file_in_lines([{'name': '导入 auto plate swap.3mf'}],
                            'auto_plate_swap.3mf'), True)
check('文件核对: 没有就是没有',
      bp._win_file_in_lines([{'name': '您将导入文件 其他.3mf'}],
                            'auto_plate_swap.3mf'), False)
check('文件核对: OCR 不可用', bp._win_file_in_lines(None, 'a.3mf'), False)

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
