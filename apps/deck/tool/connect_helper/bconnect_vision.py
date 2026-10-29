#!/usr/bin/env python3
"""bconnect_vision.py —— 多供应商、多类型的模型接入（OpenAI 兼容）。

不只视觉模型：同一个配置结构可放任意「类型」的模型（vision / chat / …），
每类独立指定 provider + base_url + api_key + model。Connect UI 自动化用到的是
vision 类：把截图发给视觉模型「看图判断」（当前选中哪台打印机、暂停/停止键在哪）。
chat 类预留给自然语言命令解析、状态总结等文本任务。

供应商预设（都走 OpenAI 兼容 /chat/completions）：
  百炼(bailian)  阿里云 DashScope   https://dashscope.aliyuncs.com/compatible-mode/v1
  百炼套餐       Token Plan(北京)  https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1
  minimax        MiniMax          https://api.minimax.chat/v1
  deepseek       DeepSeek         https://api.deepseek.com/v1
  openai         OpenAI           https://api.openai.com/v1
  custom         自定义            自填 base_url

配置：~/.bambudeck/models.json
  {"vision": {"provider":"minimax","base_url":"…","api_key":"…","model":"minimax-m3"},
   "chat":   {"provider":"…",     "base_url":"…","api_key":"…","model":"…"}}
api_key 只写本地、0600、不打印、不落日志。

同一个类型可以配成**列表** = 一个模型队列，从头试到尾：
  {"vision": [
     {"provider":"minimax","model":"minimax-m3","api_key":"…"},
     {"provider":"bailian-token","model":"qwen3.8-flash","api_key":"…"}]}
队列是动态的：谁不可用就沉到队尾，谁成功就升到队首（顺序落盘），
所以「今天没额度」的那家只会在别人都挂时再被探一次。
（2026-10-29：视觉检测/换盘被配额 429 卡死，单供应商没有退路。）

用法：
  python bconnect_vision.py --list-providers
  python bconnect_vision.py --init --type vision --provider minimax --key sk-… --model minimax-m3
  python bconnect_vision.py --init --append --provider bailian --key sk-… --model qwen3.8-flash
  python bconnect_vision.py --show
  python bconnect_vision.py --vision /path/shot.png "图里是哪台打印机？有没有暂停键？"
  python bconnect_vision.py --text "把这段话总结成一句"
"""
from __future__ import annotations

import argparse
import base64
import json
import mimetypes
import os
import re
import struct
import sys
import threading
import urllib.error
import urllib.request

INFO = os.path.expanduser("~/.bambudeck/models.json")

# 模型类型（配置里按这些 key 存；可自行扩展）
MODEL_TYPES = {
    "vision": "视觉（看图判断）",
    "chat": "文本对话",
}

# 供应商预设：base_url 为 OpenAI 兼容根地址；vision_models/chat_models 为建议模型（可覆盖）
PROVIDERS = {
    "bailian": {
        "name": "百炼 (阿里云 DashScope)",
        "base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        # 备用视觉默认用 flash：看图找坐标要的是快，flash 够用且便宜。
        "vision_models": ["qwen3.8-flash", "qwen3.8-max",
                          "qwen3-vl-plus", "qwen-vl-max"],
        "chat_models": ["qwen3.8-flash", "qwen-max", "qwen-plus"],
    },
    # 百炼「Token Plan」订阅的 key 是 sk-sp- 开头, 只能打华北2(北京)的
    # token-plan 域名; 拿去打 dashscope.aliyuncs.com 一律 401 (实测 2026-10-29)。
    "bailian-token": {
        "name": "百炼 Token Plan (华北2 北京)",
        "base_url":
            "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        "vision_models": ["qwen3.8-flash", "qwen3.8-max"],
        "chat_models": ["qwen3.8-flash", "qwen3.8-max"],
    },
    "minimax": {
        "name": "MiniMax",
        "base_url": "https://api.minimax.chat/v1",
        # 实测 /models：M3.1-Flash/M2.x 无法关闭 thinking；M3 可 thinking:disabled。
        "vision_models": ["MiniMax-M3", "MiniMax-M3.1-Flash", "MiniMax-M2.7"],
        "chat_models": ["MiniMax-M3", "MiniMax-M3.1-Flash", "MiniMax-M2.7-highspeed"],
    },
    "deepseek": {
        "name": "DeepSeek",
        "base_url": "https://api.deepseek.com/v1",
        # 注：官方 API 目前只有文本模型，无视觉；视觉需自部署 VL 或走兼容网关。
        "vision_models": [],
        "chat_models": ["deepseek-chat", "deepseek-reasoner"],
    },
    "openai": {
        "name": "OpenAI",
        "base_url": "https://api.openai.com/v1",
        "vision_models": ["gpt-4o", "gpt-4o-mini"],
        "chat_models": ["gpt-4o", "gpt-4o-mini"],
    },
    "custom": {
        "name": "自定义 (OpenAI 兼容)",
        "base_url": "",
        "vision_models": [],
        "chat_models": [],
    },
}


# ---------------------------------------------------------------- 配置
def load_models() -> dict:
    try:
        with open(INFO, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_models(models: dict) -> str:
    os.makedirs(os.path.dirname(INFO), exist_ok=True)
    # 显式 utf-8: 模型名是中文, ensure_ascii=False 直接写中文; 用系统默认
    # 编码在 Windows 上就是 GBK, 存进去再读出来就是乱码
    # (2026-10-29 踩过同款坑: 盒子配置里的中文全被二次编码)。
    with open(INFO, "w", encoding="utf-8") as f:
        json.dump(models, f, ensure_ascii=False, indent=2)
    os.chmod(INFO, 0o600)
    return INFO


# 默认关推理的供应商（关法见 _call）
_THINKING_OFF = {"minimax", "bailian", "bailian-token"}


def resolve_model(model_type: str, models: dict | None = None) -> dict:
    """返回 {provider, base_url, api_key, model, thinking}；base_url 缺省取供应商预设。"""
    m = dict((models if models is not None else load_models()).get(model_type) or {})
    provider = m.get("provider") or "custom"
    preset = PROVIDERS.get(provider, PROVIDERS["custom"])
    if not m.get("base_url"):
        m["base_url"] = preset["base_url"]
    # thinking：MiniMax-M3 / qwen3.8 这类推理模型默认先想再说，看图找坐标
    # 会被思考段拖慢（甚至 max_tokens 全烧在思考上、正文为空）。必须显式关。
    # 两家关法不一样：MiniMax 用 {"thinking":{"type":"disabled"}}，
    # 百炼/通义用 "enable_thinking": false（2026-10-29 实测 token-plan 有效）。
    # 注：MiniMax-M3.1-Flash / M2.x 关不掉 thinking，别选它们做「看图找坐标」。
    if "thinking" not in m:
        m["thinking"] = "disabled" if provider in _THINKING_OFF else None
    return m


def _mask_entry(c: dict) -> str:
    """一行展示一条配置。key 只露前 6 位 —— 打日志/截图都不能带出整把。"""
    key = (c.get("api_key") or "")
    shown = (key[:6] + "…") if key else "(空)"
    return "provider=%s model=%s base_url=%s api_key=%s" % (
        c.get("provider"), c.get("model"), c.get("base_url"), shown)


def _raw_entries(model_type: str, models: dict | None = None) -> list:
    """配置值既可以是单个 dict（老格式），也可以是 list（主用+备用）。"""
    raw = (models if models is not None else load_models()).get(model_type)
    if isinstance(raw, list):
        return raw
    if isinstance(raw, dict):
        return [raw]
    return []


def resolve_chain(model_type: str, models: dict | None = None) -> list[dict]:
    """按顺序返回可用的模型配置。第一个是主用，其余是备用。

    没有 model 名的条目直接跳过 —— 半截配置不能当成「可以调用」，
    否则每次都会先失败一次再换下一个，白等一轮超时。
    """
    return [resolve_model(model_type, {model_type: e})
            for e in _raw_entries(model_type, models)
            if isinstance(e, dict) and (e.get("model") or "").strip()]


# ---------------------------------------------------------------- 调用
def _strip_think(text: str) -> str:
    """MiniMax-M3 等推理模型会先输出 <think>…</think> 再输出正文，剥掉思考段。"""
    return re.sub(r"<\s*think\s*>.*?<\s*/\s*think\s*>", "", text,
                  flags=re.DOTALL | re.IGNORECASE).strip()


def _call(base_url: str, key: str, model: str, messages: list,
          max_tokens: int = 2048, thinking: str | None = None,
          provider: str = "") -> str:
    base = (base_url or "").rstrip("/")
    if not base:
        raise RuntimeError("未配置模型 base_url（%s）" % INFO)
    if not model:
        raise RuntimeError("未配置模型 model（%s）" % INFO)
    payload = {"model": model, "messages": messages, "max_tokens": max_tokens}
    if thinking:
        if provider.startswith("bailian"):
            # 百炼/通义：顶层开关，false 才是不想
            payload["enable_thinking"] = False
        else:
            # OpenAI 兼容侧关推理：{"thinking": {"type": "disabled"}}
            payload["thinking"] = {"type": thinking}
    req = urllib.request.Request(
        base + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            js = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        raise RuntimeError("模型 HTTP %s: %s" % (e.code, raw[:400])) from e
    try:
        msg = js["choices"][0]["message"]
        content = msg.get("content")
        # 部分供应商把 content 拆成 parts 列表
        if isinstance(content, list):
            content = "".join(p.get("text", "") for p in content
                              if isinstance(p, dict))
        content = (content or "").strip()
        if not content:
            rc = msg.get("reasoning_content") or ""
            raise RuntimeError(
                "模型只回了思考没回正文（thinking 未关闭）。思考片段: %s" % rc[:200])
        return _strip_think(content)
    except (KeyError, IndexError) as e:
        raise RuntimeError(
            "模型返回异常: %s" % json.dumps(js, ensure_ascii=False)[:400]) from e


def _image_data_uri(path: str) -> str:
    mime = mimetypes.guess_type(path)[0] or "image/png"
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return "data:%s;base64,%s" % (mime, b64)


def ask_vision(image_path: str, prompt: str, model_type: str = "vision",
               max_tokens: int = 2048) -> str:
    """把一张图 + 问题发给视觉模型，返回文本回答。主用失败自动换备用。"""
    content = [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": _image_data_uri(image_path)}},
    ]
    return _call_chain(model_type, [{"role": "user", "content": content}],
                       max_tokens)


def ask_text(prompt: str, model_type: str = "chat", max_tokens: int = 2048) -> str:
    """纯文本对话。主用失败自动换备用。"""
    return _call_chain(model_type, [{"role": "user", "content": prompt}],
                       max_tokens)


def _call_chain(model_type: str, messages: list, max_tokens: int) -> str:
    """按队列顺序挨个试，失败的排到后面，第一个成功的排到最前。

    队列是动态的（2026-10-29）：今天没额度的模型不该每次调用都先白等一轮
    超时。成功的那个落盘到最前，下次直接先试它；不可用的自然沉到最后，
    等前面都挂了再轮到它 —— 它自己也借那次机会重新探活。
    """
    chain = resolve_chain(model_type)
    if not chain:
        raise RuntimeError("未配置模型（%s 的 %s 段）" % (INFO, model_type))
    errors = []
    for i, c in enumerate(chain):
        label = "%s/%s" % (c.get("provider") or "custom", c.get("model"))
        try:
            reply = _call(c["base_url"], c.get("api_key") or "",
                          c.get("model") or "", messages,
                          max_tokens, thinking=c.get("thinking"),
                          provider=c.get("provider") or "")
        except Exception as e:  # noqa: BLE001
            errors.append("%s: %s" % (label, e))
            if i + 1 < len(chain):
                print("[vision] %s 不可用，排到队列后面: %s" % (label, e),
                      file=sys.stderr)
            continue
        if i:
            _promote(model_type, c)
        return reply
    raise RuntimeError("所有模型都失败 —— " + " | ".join(errors))


_ORDER_LOCK = threading.Lock()


def _promote(model_type: str, entry: dict) -> None:
    """把刚成功的那条挪到队列最前并落盘。落盘失败不影响这次调用。"""
    try:
        with _ORDER_LOCK:
            models = load_models()
            entries = _raw_entries(model_type, models)
            if len(entries) < 2:
                return
            want = (entry.get("provider"), entry.get("model"))
            idx = next((i for i, e in enumerate(entries)
                        if (e.get("provider"), e.get("model")) == want), -1)
            if idx <= 0:
                return
            entries.insert(0, entries.pop(idx))
            models[model_type] = entries
            save_models(models)
            print("[vision] %s/%s 可用，已排到最前"
                  % (want[0] or "custom", want[1]), file=sys.stderr)
    except Exception as e:  # noqa: BLE001
        print("[vision] 调整队列顺序失败(不影响本次结果): %s" % e,
              file=sys.stderr)


# ---------------------------------------------------------------- 坐标
def _image_size(path: str) -> tuple[int, int]:
    """读 PNG 宽高（screencapture 默认 PNG）；读不出回 (0, 0)。"""
    try:
        with open(path, "rb") as f:
            head = f.read(26)
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            w, h = struct.unpack(">II", head[16:24])
            return w, h
    except Exception:
        pass
    return 0, 0


def ask_coords(image_path: str, target: str, model_type: str = "vision") -> tuple[int, int] | None:
    """直接问「target 按钮的像素坐标」，返回 (x, y)；失败/解析不出返回 None。

    要点：传全屏截图（不是裁剪图）+ 报图像尺寸，模型才给得出可用坐标。
    解析不出返回 None。"""
    w, h = _image_size(image_path)
    dim = ("这是 %dx%d 的屏幕截图。" % (w, h)) if w and h else ""
    ans = ask_vision(
        image_path,
        dim + "图中「%s」中心的像素坐标是多少？只回答 x,y 两个数字。" % target,
        model_type=model_type)
    m = re.search(r"(\d+)\s*[,，]\s*(\d+)", ans)
    if m:
        return int(m.group(1)), int(m.group(2))
    return None


# ---------------------------------------------------------------- CLI
def main() -> int:
    ap = argparse.ArgumentParser(description="多供应商多类型模型接入")
    ap.add_argument("--list-providers", action="store_true")
    ap.add_argument("--init", action="store_true")
    ap.add_argument("--append", action="store_true",
                    help="追加为备用（不覆盖主用），配合 --init 使用")
    ap.add_argument("--show", action="store_true", help="显示当前配置（key 打码）")
    ap.add_argument("--type", help="模型类型: vision/chat/…（默认 vision）")
    ap.add_argument("--provider", help="供应商: bailian/minimax/deepseek/openai/custom")
    ap.add_argument("--key", help="API key")
    ap.add_argument("--model", help="模型名")
    ap.add_argument("--base-url", help="自定义 base_url（覆盖供应商预设）")
    ap.add_argument("--vision", nargs=2, metavar=("IMAGE", "PROMPT"), help="看图提问")
    ap.add_argument("--text", help="文本提问")
    a = ap.parse_args()

    if a.list_providers:
        for k, v in PROVIDERS.items():
            print("%-9s %-26s %s" % (k, v["name"], v["base_url"] or "(自填)"))
            print("           视觉: %s" % (", ".join(v["vision_models"]) or "—"))
            print("           文本: %s" % (", ".join(v["chat_models"]) or "—"))
        return 0

    if a.show:
        models = load_models()
        for mtype in (a.type,) if a.type else MODEL_TYPES:
            chain = resolve_chain(mtype, models)
            if not chain:
                print("[%s] (未配置)" % mtype)
                continue
            print("[%s] %d 个" % (mtype, len(chain)))
            for i, c in enumerate(chain):
                print("  %d. %s" % (i + 1, _mask_entry(c)))
        return 0

    if a.init:
        mtype = a.type or "vision"
        models = load_models()
        cur = models.get(mtype)
        if a.append:
            chain = [dict(e) for e in _raw_entries(mtype, models)]
            entry = {}
        else:
            # 覆盖主用；备用原样留着
            chain = [dict(e) for e in _raw_entries(mtype, models)]
            entry = chain[0] if chain else {}
        if a.provider:
            entry["provider"] = a.provider
        if a.base_url:
            entry["base_url"] = a.base_url
        if a.key:
            entry["api_key"] = a.key
        if a.model:
            entry["model"] = a.model
        entry = resolve_model(mtype, {mtype: entry})
        if a.append:
            chain.append(entry)
        else:
            chain = [entry] + chain[1:]
        # 只有一个就用老的单 dict 格式，读起来清爽；多于一->列表
        models[mtype] = chain if len(chain) > 1 else (chain[0] if chain else {})
        print("已写入 %s" % save_models(models))
        for i, c in enumerate(resolve_chain(mtype, models)):
            print("  %d. %s" % (i + 1, _mask_entry(c)))
        return 0

    try:
        if a.vision:
            print(ask_vision(a.vision[0], a.vision[1]))
        elif a.text:
            print(ask_text(a.text))
        else:
            ap.error("需要 --vision / --text / --list-providers / --init")
    except Exception as e:  # noqa: BLE001
        print("错误: %s" % e)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
