#!/usr/bin/env python3
"""bconnect_cloud.py —— 云端共享层（登录态 / 设备注册表 / 云 MQTT 状态 / 任务匹配）。

把 bconnect_print.py / bconnect_helper.py 里重复的云端逻辑收拢到一处，服务化后
多个命令（打印 / 状态 / 目标机校验）共用同一套：

  - load_session()   读登录态 token（不打印凭证）
  - resolve_uid()    uid 获取链：JWT payload → GET /my/profile。CN 短信登录返回
                     144 字符非 JWT token、响应里无 uid，必须走 profile 兜底
  - device_list()    /v1/iot-service/api/user/bind → serial↔name/access_code/online
  - cloud_state()    云 MQTT pushall 只读快照（gcode_state/进度/温度）
  - latest_task()    派单后回读任务列表；支持 after_id 只看新任务（防读到上一轮残留）

安全：不打印任何 token/key；uid 只缓存在内存，不落盘。
"""
from __future__ import annotations

import base64
import json
import os
import ssl
import time
import uuid
import urllib.error
import urllib.request

import paho.mqtt.client as mqtt

HERE = os.path.dirname(os.path.abspath(__file__))
SESSION_FILE = os.environ.get(
    "BAMBU_SESSION", os.path.join(HERE, "creds", "cloud_session.json"))
# 登录态实际放在 ~/.bambudeck/ 下（凭证不进仓库）。没设 BAMBU_SESSION 时
# 自动认这个位置，CLI 直接跑就不用每次带环境变量。
if not os.path.exists(SESSION_FILE):
    _HOME_SESSION = os.path.expanduser("~/.bambudeck/cloud_session.json")
    if os.path.exists(_HOME_SESSION):
        SESSION_FILE = _HOME_SESSION
API = os.environ.get("BAMBU_API", "https://api.bambulab.cn")
MQTT_HOST = "cn.mqtt.bambulab.com"
MQTT_PORT = 8883

CONNECT_HEADERS = {
    "Content-Type": "application/json",
    "User-Agent": "BambuConnect/v2.5.0-beta.15",
    "x-bbl-client-type": "connect",
    "x-bbl-client-name": "BambuConnect",
    "x-bbl-client-version": "v2.5.0-beta.15",
    "x-bbl-language": "zh-CN",
    "x-bbl-os-type": "macos",
    "x-connect-api-acton": "sign",
}

# /my/profile 用 slicer 客户端头（与 BambuHelper cloudFetchUserId 一致）
SLICER_HEADERS = {
    "Content-Type": "application/json",
    "User-Agent": "bambu_network_agent/01.09.05.01",
    "X-BBL-Client-Name": "OrcaSlicer",
    "X-BBL-Client-Type": "slicer",
    "X-BBL-Client-Version": "01.09.05.51",
    "X-BBL-Language": "zh-CN",
}

_uid_cache: str | None = None
_token_cache: str | None = None


# ---------------------------------------------------------------- 登录态
def load_session() -> str:
    """读登录态 token。uid 不在文件里，需另调 resolve_uid()。"""
    global _token_cache
    if _token_cache:
        return _token_cache
    with open(SESSION_FILE, encoding="utf-8") as f:
        sess = json.load(f)
    tok = sess.get("accessToken") or sess.get("token") or sess.get("refresh")
    if not tok:
        raise RuntimeError("登录态缺失: %s" % SESSION_FILE)
    _token_cache = tok
    return tok


def _extract_uid_jwt(token: str) -> str | None:
    parts = token.split(".")
    if len(parts) != 3:
        return None
    p = parts[1].replace("-", "+").replace("_", "/")
    p += "=" * (-len(p) % 4)
    try:
        m = json.loads(base64.b64decode(p))
        return m.get("uid") or m.get("sub") or m.get("user_id")
    except Exception:
        return None


def resolve_uid(token: str | None = None) -> str | None:
    """uid 获取链：JWT → /my/profile。CN 短信 token 非 JWT，走 profile。"""
    global _uid_cache
    if _uid_cache:
        return _uid_cache
    token = token or load_session()
    uid = _extract_uid_jwt(token)
    if not uid:
        st, js = _http("GET", "/v1/user-service/my/profile",
                       headers=SLICER_HEADERS, token=token)
        if st == 200 and isinstance(js, dict):
            uid = js.get("uidStr") or js.get("uid") or js.get("sub")
    if uid:
        _uid_cache = str(uid)
    return _uid_cache


# ---------------------------------------------------------------- 通用 HTTP
def _http(method: str, path: str, *, headers=None, body=None,
          params=None, token=None) -> tuple[int, dict]:
    h = dict(headers or CONNECT_HEADERS)
    if token:
        h["Authorization"] = "Bearer " + token
    url = API + path
    if params:
        url += "?" + "&".join("%s=%s" % (k, v) for k, v in params.items())
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw[:300]}


# ---------------------------------------------------------------- 设备注册表
_DEVS_CACHE: dict = {"t": 0.0, "devs": [], "ttl": 45.0}

# 名称↔序列号双向映射缓存 (反馈 2026-10-23): 只按「列表指纹」变化重建。
# 打印机增删/改名时指纹变 → 映射立即重建；列表没变就原样复用，不做无谓更新。
_MAP_CACHE: dict = {"fp": None, "by_serial": {}, "by_name": {}}


def device_list(force: bool = False) -> list[dict]:
    """云端设备注册表。每项: serial/name/online/access_code/model/print_status。

    带 45 秒内存缓存：切模式/改访问码后最多 45 秒自动跟上（force=True 立即刷新）。
    """
    now = time.time()
    if (not force and _DEVS_CACHE["devs"]
            and now - _DEVS_CACHE["t"] < _DEVS_CACHE["ttl"]):
        return _DEVS_CACHE["devs"]
    token = load_session()
    _, js = _http("GET", "/v1/iot-service/api/user/bind", token=token)
    devs = (js.get("devices") if isinstance(js, dict) else None) or []
    out = []
    for d in devs:
        if not isinstance(d, dict):
            continue
        out.append({
            "serial": d.get("dev_id"),
            "name": d.get("name"),
            "online": bool(d.get("online")),
            "access_code": d.get("dev_access_code"),
            "model": d.get("dev_product_name") or d.get("dev_model_name"),
            "print_status": d.get("print_status"),
        })
    _DEVS_CACHE.update(t=time.time(), devs=out)
    return out


def resolve_device(serial: str, force: bool = False) -> dict | None:
    for d in device_list(force=force):
        if d.get("serial") == serial:
            return d
    return None


# ---------------------------------------------------------------- 名称↔序列号映射
def _list_fingerprint(devs: list[dict]) -> tuple:
    """设备列表指纹：按 (serial, name) 排序去重。

    增删打印机或改名都会让指纹变化；仅在线状态/访问码变化不影响指纹
    （那类高频变化走 device_list 的 45s TTL，不必重建映射）。
    """
    return tuple(sorted(
        (d.get("serial"), (d.get("name") or "").strip()) for d in devs))


def _build_mapping(devs: list[dict]) -> dict:
    by_serial: dict[str, str] = {}
    by_name: dict[str, str | None] = {}
    for d in devs:
        s = d.get("serial")
        n = (d.get("name") or "").strip()
        if not s:
            continue
        by_serial.setdefault(s, n)
        if not n:
            continue
        # 重名 → 反查歧义（置 None，与旧 serial_for_name「不唯一不反查」语义一致）
        by_name[n] = None if n in by_name else s
    return {"by_serial": by_serial, "by_name": by_name}


def ensure_mapping(force: bool = False) -> dict:
    """刷新并返回名称↔序列号双向映射。

    force 只控制底层设备列表是否强制重拉（走 device_list 的 TTL）；映射本身
    只看「列表指纹」——只有列表变了（打印机增删/改名）才重建，列表没变就
    原样复用缓存（反馈 2026-10-23：无变化不更新，变化及时更新）。
    """
    devs = device_list(force=force)
    fp = _list_fingerprint(devs)
    if fp != _MAP_CACHE["fp"]:
        _MAP_CACHE.update(_build_mapping(devs))
        _MAP_CACHE["fp"] = fp
    return _MAP_CACHE


def name_for_serial(serial: str) -> str | None:
    """按序列号快速取当前正确名称（O(1)，映射未过期时命中）。"""
    return ensure_mapping()["by_serial"].get(serial)


def serial_for_name(name: str) -> str | None:
    """按设备名反查序列号（精确匹配，名重复/找不到返回 None）。

    Connect 发送页只显示目标机「名」，要精确核对是不是用户点的那台，得把名
    翻回唯一序列号再比（名可重名/改名，序列号才是稳定唯一标识）。
    """
    n = (name or "").strip()
    if not n:
        return None
    return ensure_mapping()["by_name"].get(n)


def access_code(serial: str, force: bool = False) -> str | None:
    """按序列号取当前有效访问码。

    为什么要从云端拿：关掉/打开「仅局域网模式」会重置访问码，
    本机写死的旧码立刻失效（表现为 MQTT rc=135 Not authorized）。
    """
    return (resolve_device(serial, force=force) or {}).get("access_code")


# ---------------------------------------------------------------- 局域网访问码探测
def _mqtt_auth_ok(ip: str, code: str, serial: str | None = None,
                  port: int = 8883, timeout: float = 5.0) -> bool:
    """只测 bblp 登录是否被接受（不发任何指令，无副作用）。"""
    got = {"ok": False}

    def on_connect(cl, _u, _f, rc, _props=None):
        got["ok"] = getattr(rc, "value", rc) == 0
        try:
            cl.disconnect()
        except Exception:  # noqa: BLE001
            pass

    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                    client_id="acprobe" + uuid.uuid4().hex[:8],
                    protocol=mqtt.MQTTv311)
    c.username_pw_set("bblp", str(code))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    c.tls_set_context(ctx)
    c.tls_insecure_set(True)
    c.on_connect = on_connect
    try:
        c.connect(ip, port, keepalive=15)
    except Exception:  # noqa: BLE001
        return False
    c.loop_start()
    t0 = time.time()
    while time.time() - t0 < timeout and not got["ok"]:
        time.sleep(0.15)
    c.loop_stop()
    return bool(got["ok"])


def resolve_by_ip(ip: str, port: int = 8883, timeout: float = 4.0,
                  serial: str | None = None) -> dict | None:
    """只给 IP 时，用云端各机的访问码逐个试登录，认出这台是哪台。

    先试已知 serial（若给了），再按设备列表顺序试；命中即返回设备字典。
    """
    devs = device_list()
    if serial:
        devs = sorted(devs, key=lambda d: 0 if d.get("serial") == serial else 1)
    for d in devs:
        code = d.get("access_code")
        if not code:
            continue
        if _mqtt_auth_ok(ip, code, d.get("serial"), port=port, timeout=timeout):
            return d
    return None


def resolve(ip: str | None = None, serial: str | None = None,
            port: int = 8883, force: bool = False) -> dict | None:
    """统一入口：能给 serial 就给，给不出就用 ip 探测。

    返回 {serial,name,online,access_code,model,print_status} 或 None。
    """
    if serial:
        d = resolve_device(serial, force=force)
        if d:
            return d
    if ip:
        return resolve_by_ip(ip, port=port, serial=serial)
    return None



# ---------------------------------------------------------------- 云 MQTT 状态
def cloud_state(serial: str, seconds: int = 12) -> dict:
    """云 MQTT pushall 只读快照（失败返回 {}，不抛异常）。"""
    try:
        token = load_session()
        uid = resolve_uid(token)
        if not uid:
            return {}
        st: dict = {}

        def on_msg(_c, _u, m):
            try:
                j = json.loads(m.payload)
            except Exception:
                return
            p = j.get("print") or {}
            if isinstance(p, dict):
                st.update(p)

        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1,
                        client_id="bcd" + uuid.uuid4().hex[:8],
                        protocol=mqtt.MQTTv311)
        c.username_pw_set("u_" + uid, token)
        c.tls_set_context(ssl.create_default_context())
        c.on_connect = lambda cl, _u, _f, _rc: (
            cl.subscribe("device/%s/report" % serial, qos=0),
            cl.publish("device/%s/request" % serial,
                       json.dumps({"pushing": {"sequence_id": "99001",
                                               "command": "pushall"}}), qos=0))
        c.on_message = on_msg
        c.connect(MQTT_HOST, MQTT_PORT, 30)
        c.loop_start()
        time.sleep(seconds)
        c.loop_stop()
        c.disconnect()
        return st
    except Exception:
        return {}


# ---------------------------------------------------------------- 任务匹配
def latest_task(title_hint: str | None, serial: str | None = None,
                after_id: int | None = None, tries: int = 12,
                wait: float = 5.0) -> dict | None:
    """轮询任务列表，按标题匹配最新任务（列表按时间倒序，第一个匹配即最新）。

    after_id：只返回 id 大于它的任务，用于派单后只看「新」任务，避免重复打印
    同一文件时读到上一轮残留的旧任务。
    """
    token = load_session()
    base = os.path.splitext(os.path.basename(title_hint or ""))[0]
    for _ in range(tries):
        _, js = _http("GET", "/v1/user-service/my/tasks",
                      params={"limit": "10", "offset": "0"}, token=token)
        hits = (js.get("hits") if isinstance(js, dict) else None) or []
        for h in hits:
            if not isinstance(h, dict):
                continue
            hid = h.get("id")
            if after_id is not None and (hid or 0) <= after_id:
                continue
            t = str(h.get("title") or "")
            if not t:
                continue
            if title_hint and (t == title_hint or (base and t.startswith(base))):
                return {"id": hid, "status": h.get("status"),
                        "device": h.get("deviceId")}
        time.sleep(wait)
    return None


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="云端设备表 / 按 IP 认机 / 取当前访问码")
    ap.add_argument("--list", action="store_true", help="列出云端设备（访问码打码）")
    ap.add_argument("--serial", help="按序列号查")
    ap.add_argument("--ip", help="按局域网 IP 探测是哪台（用各机访问码试登录，无副作用）")
    a = ap.parse_args()

    def show(d: dict | None) -> None:
        if not d:
            print("未匹配到设备")
            return
        c = d.get("access_code") or ""
        print("serial=%s name=%r online=%s model=%s access_code=%s" % (
            d.get("serial"), d.get("name"), d.get("online"), d.get("model"),
            (c[:2] + "…（%d 位，未显示）" % len(c)) if c else None))

    if a.ip:
        print("按 IP 探测 %s ..." % a.ip)
        show(resolve(ip=a.ip, serial=a.serial))
    elif a.serial:
        show(resolve_device(a.serial))
    else:
        print("== devices ==")
        for d in device_list(force=True):
            show(d)

