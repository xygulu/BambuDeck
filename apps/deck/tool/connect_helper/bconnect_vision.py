#!/usr/bin/env python3
"""bconnect_vision.py —— 多供应商、多类型的模型接入（OpenAI 兼容）。

不只视觉模型：同一个配置结构可放任意「类型」的模型（vision / chat / …），
每类独立指定 provider + base_url + api_key + model。Connect UI 自动化用到的是
vision 类：把截图发给视觉模型「看图判断」（当前选中哪台打印机、暂停/停止键在哪）。
chat 类预留给自然语言命令解析、状态总结等文本任务。

供应商预设（都走 OpenAI 兼容 /chat/completions）：
  百炼(bailian)  阿里云 DashScope   https://dashscope.aliyuncs.com/compatible-mode/v1
  minimax        MiniMax          https://api.minimax.chat/v1
  deepseek       DeepSeek         https://api.deepseek.com/v1
  openai         OpenAI           https://api.openai.com/v1
  custom         自定义            自填 base_url

配置：~/.bambudeck/models.json
  {"vision": {"provider":"minimax","base_url":"…","api_key":"…","model":"minimax-m3"},
   "chat":   {"provider":"…",     "base_url":"…","api_key":"…","model":"…"}}
api_key 只写本地、0600、不打印、不落日志。

用法：
  python bconnect_vision.py --list-providers
  python bconnect_vision.py --init --type vision --provider minimax --key sk-… --model minimax-m3
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
        "vision_models": ["qwen-vl-max", "qwen-vl-plus", "qwen3-vl-plus", "qwen3-vl-max"],
        "chat_models": ["qwen-max", "qwen-plus", "qwen-turbo"],
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


def resolve_model(model_type: str, models: dict | None = None) -> dict:
    """返回 {provider, base_url, api_key, model, thinking}；base_url 缺省取供应商预设。"""
    m = dict((models if models is not None else load_models()).get(model_type) or {})
    provider = m.get("provider") or "custom"
    preset = PROVIDERS.get(provider, PROVIDERS["custom"])
    if not m.get("base_url"):
        m["base_url"] = preset["base_url"]
    # thinking：MiniMax-M3 关掉推理、直接回答案（快）。OpenAI 兼容侧默认开推理，
    # 必须显式 {"type":"disabled"} 才关；Anthropic 侧 M3 默认就是关的。
    # 注：MiniMax-M3.1-Flash / M2.x 关不掉 thinking，别选它们做「看图找坐标」。
    if "thinking" not in m:
        m["thinking"] = "disabled" if provider == "minimax" else None
    return m


# ---------------------------------------------------------------- 调用
def _strip_think(text: str) -> str:
    """MiniMax-M3 等推理模型会先输出 <think>…</think> 再输出正文，剥掉思考段。"""
    return re.sub(r"<\s*think\s*>.*?<\s*/\s*think\s*>", "", text,
                  flags=re.DOTALL | re.IGNORECASE).strip()


def _call(base_url: str, key: str, model: str, messages: list,
          max_tokens: int = 2048, thinking: str | None = None) -> str:
    base = (base_url or "").rstrip("/")
    if not base:
        raise RuntimeError("未配置模型 base_url（%s）" % INFO)
    if not model:
        raise RuntimeError("未配置模型 model（%s）" % INFO)
    payload = {"model": model, "messages": messages, "max_tokens": max_tokens}
    if thinking:
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
    """把一张图 + 问题发给视觉模型，返回文本回答。"""
    c = resolve_model(model_type)
    content = [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": _image_data_uri(image_path)}},
    ]
    return _call(c["base_url"], c.get("api_key") or "", c.get("model") or "",
                 [{"role": "user", "content": content}], max_tokens,
                 thinking=c.get("thinking"))


def ask_text(prompt: str, model_type: str = "chat", max_tokens: int = 2048) -> str:
    """纯文本对话。"""
    c = resolve_model(model_type)
    return _call(c["base_url"], c.get("api_key") or "", c.get("model") or "",
                 [{"role": "user", "content": prompt}], max_tokens,
                 thinking=c.get("thinking"))


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

    if a.init:
        mtype = a.type or "vision"
        models = load_models()
        entry = dict(models.get(mtype) or {})
        if a.provider:
            entry["provider"] = a.provider
        if a.base_url:
            entry["base_url"] = a.base_url
        if a.key:
            entry["api_key"] = a.key
        if a.model:
            entry["model"] = a.model
        entry = resolve_model(mtype, {mtype: entry})
        models[mtype] = entry
        print("已写入 %s" % save_models(models))
        print("  [%s] provider=%s base_url=%s model=%s api_key=%s" % (
            mtype, entry.get("provider"), entry.get("base_url"),
            entry.get("model"),
            (entry.get("api_key") or "")[:6] + "…" if entry.get("api_key") else "(空)"))
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
