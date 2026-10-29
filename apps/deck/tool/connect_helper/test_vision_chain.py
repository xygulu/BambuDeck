"""视觉模型「主用 + 备用」链路自测 (2026-10-29)。

需求来源: 视觉模型再加一个阿里云百炼 / qwen3.8-flash 做备用 ——
其中一个不可用(429/超时/401)时调用另一个, 别让整条链路停摆。

跑法: python3 -I test_vision_chain.py   (不需要网络/真机)
"""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import bconnect_vision as bv  # noqa: E402

# 第一件事就把配置路径挪到临时目录：下面的假 key 一旦被「成功即排到队首」
# 的落盘逻辑写回去，就会把真机上的 ~/.bambudeck/models.json 覆盖成测试数据
# (2026-10-29 踩过：盒子上的真 key 被测试里写废了)。
bv.INFO = str(Path(tempfile.mkdtemp(prefix="models-guard")) / "models.json")

FAILS = []
CALLS = []
REAL_CALL = bv._call  # 步骤 4-7 会把它换成假实现
REAL_LOAD = bv.load_models


def check(label, got, want):
    ok = got == want
    print(('PASS ' if ok else 'FAIL ') + label, '| got:', got, 'want:', want)
    if not ok:
        FAILS.append(label)


def use(models):
    """让被测代码读我们给的配置, 不碰 ~/.bambudeck/models.json。"""
    bv.load_models = lambda: models


PRIMARY = {"provider": "minimax", "model": "MiniMax-M3", "api_key": "sk-primary-123456"}
BACKUP = {"provider": "bailian-token", "model": "qwen3.8-flash",
          "api_key": "sk-backup-abcdef"}

# 1) 单条老格式仍然可用
chain = bv.resolve_chain("vision", {"vision": PRIMARY})
check('单 dict -> 1 条', len(chain), 1)
check('单 dict 模型名', chain[0]["model"], "MiniMax-M3")
check('单 dict 补 base_url',
      chain[0]["base_url"], "https://api.minimax.chat/v1")

# 2) 列表 = 主用在前, 备用在后
chain = bv.resolve_chain("vision", {"vision": [PRIMARY, BACKUP]})
check('列表 -> 2 条', len(chain), 2)
check('主用在前', chain[0]["model"], "MiniMax-M3")
check('备用在后', chain[1]["model"], "qwen3.8-flash")
check('备用走百炼 Token Plan base_url', chain[1]["base_url"],
      "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
check('百炼默认不开 thinking', chain[1]["thinking"], "disabled")

# 3) 半截配置(没有 model)直接跳过, 不浪费一次超时
chain = bv.resolve_chain("vision", {"vision": [
    {"provider": "minimax"}, BACKUP]})
check('跳过无 model 条目', [c["model"] for c in chain], ["qwen3.8-flash"])

# 4) 主用正常 -> 只调一次
CALLS.clear()
use({"vision": [PRIMARY, BACKUP]})


def ok_call(base_url, key, model, messages, max_tokens=2048, thinking=None, provider=""):
    CALLS.append(model)
    return "答案:" + model


bv._call = ok_call
check('主用可用', bv._call_chain("vision", [{"role": "user", "content": "hi"}], 64), "答案:MiniMax-M3")
check('只调了主用', CALLS, ["MiniMax-M3"])

# 5) 主用 429 -> 自动换备用, 结果来自备用
CALLS.clear()


def quota_then_ok(base_url, key, model, messages, max_tokens=2048, thinking=None, provider=""):
    CALLS.append(model)
    if model == "MiniMax-M3":
        raise RuntimeError("模型 HTTP 429: tokenplan 用量不足")
    return "答案:" + model


bv._call = quota_then_ok
check('429 后换备用', bv._call_chain("vision", [{"role": "user", "content": "hi"}], 64), "答案:qwen3.8-flash")
check('两家都试过', CALLS, ["MiniMax-M3", "qwen3.8-flash"])

# 6) 全都挂 -> 汇总报错, 且报错里不能出现 key
CALLS.clear()


def always_fail(base_url, key, model, messages, max_tokens=2048, thinking=None, provider=""):
    CALLS.append(model)
    raise RuntimeError("模型 HTTP 401: invalid_api_key")


bv._call = always_fail
err = ""
try:
    bv._call_chain("vision", [{"role": "user", "content": "hi"}], 64)
except RuntimeError as e:
    err = str(e)
check('全挂时抛错', err.startswith("所有模型都失败"), True)
check('报错含两家标签', ("minimax/MiniMax-M3" in err and
                    "bailian-token/qwen3.8-flash" in err), True)
check('报错不含 key', ("sk-primary" in err or "sk-backup" in err), False)

# 7) 一个都没配 -> 明确的配置报错
use({"vision": []})
err = ""
try:
    bv._call_chain("vision", [{"role": "user", "content": "hi"}], 64)
except RuntimeError as e:
    err = str(e)
check('没配置时提示', "未配置模型" in err, True)

# 8) 打码: 只露前 6 位
line = bv._mask_entry(BACKUP)
check('打码露前 6 位', "sk-bac" in line, True)
check('打码不含全 key', "sk-backup-abcdef" in line, False)

# 9) 预设里百炼首选 flash
check('百炼视觉首选', bv.PROVIDERS["bailian"]["vision_models"][0], "qwen3.8-flash")

bv._call = REAL_CALL

# 10) 关推理的请求体: 两家参数名不一样, 发错了要么报 400 要么慢到超时
SENT = []


class _Resp:
    def __init__(self, body):
        self._b = body

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def fake_urlopen(req, timeout=None):
    import json as _json
    SENT.append(_json.loads(req.data.decode()))
    return _Resp(_json.dumps(
        {"choices": [{"message": {"content": "好"}}]}).encode())


bv.urllib.request.urlopen = fake_urlopen
bv._call("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
         "k", "qwen3.8-flash", [{"role": "user", "content": "hi"}], 16,
         thinking="disabled", provider="bailian-token")
check('百炼发 enable_thinking=false', SENT[-1].get("enable_thinking"), False)
check('百炼不带 thinking 字段', "thinking" in SENT[-1], False)

bv._call("https://api.minimax.chat/v1", "k", "MiniMax-M3",
         [{"role": "user", "content": "hi"}], 16,
         thinking="disabled", provider="minimax")
check('MiniMax 发 thinking.type', SENT[-1].get("thinking"), {"type": "disabled"})
check('MiniMax 不带 enable_thinking', "enable_thinking" in SENT[-1], False)
check('Token Plan 预设首选', bv.PROVIDERS["bailian-token"]["vision_models"][0],
      "qwen3.8-flash")

# 11) 动态队列: 成功的升到最前并落盘, 下次先试它
import json as _json  # noqa: E402
import tempfile  # noqa: E402

bv.load_models = REAL_LOAD
bv._call = REAL_CALL
Path(bv.INFO).write_text(_json.dumps(
    {"vision": [PRIMARY, BACKUP]}, ensure_ascii=False), encoding="utf-8")


def write_models_file(chain):
    Path(bv.INFO).write_text(_json.dumps({"vision": chain}, ensure_ascii=False),
                             encoding="utf-8")


def read_order():
    d = _json.loads(Path(bv.INFO).read_text(encoding="utf-8"))
    return [e["model"] for e in d["vision"]]


TRIED = []


def first_fails(base_url, key, model, messages, max_tokens=2048, thinking=None,
                provider=""):
    TRIED.append(model)
    if model == "MiniMax-M3":
        raise RuntimeError("模型 HTTP 429: 用量不足")
    return "答案:" + model


bv._call = first_fails
check('备用顶上', bv._call_chain("vision", [], 64), "答案:qwen3.8-flash")
check('成功后落盘到最前', read_order(), ["qwen3.8-flash", "MiniMax-M3"])

# 下一次: 直接先问队列最前那个, 不再白等一次 429
TRIED.clear()
check('第二次仍用可用的那个', bv._call_chain("vision", [], 64), "答案:qwen3.8-flash")
check('只调了一次', TRIED, ["qwen3.8-flash"])

# 主力恢复: 队列最前的挂了 -> 沉底; 后面的顶上
write_models_file([BACKUP, PRIMARY])


def flip(base_url, key, model, messages, max_tokens=2048, thinking=None,
         provider=""):
    TRIED.append(model)
    if model == "qwen3.8-flash":
        raise RuntimeError("模型 HTTP 503: 网关不可用")
    return "答案:" + model


bv._call = flip
TRIED.clear()
check('前面的挂了轮到后面', bv._call_chain("vision", [], 64), "答案:MiniMax-M3")
check('沉底后重排', read_order(), ["MiniMax-M3", "qwen3.8-flash"])

print()
print('== %s ==' % ('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
