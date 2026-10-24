#!/usr/bin/env python3
"""bconnect_service.py —— BambuDeck 云打印/控制服务（Bambu Connect 自动化 + LAN 控制）。

取代 bconnect_helper.py 的通用命令服务。客户端只传「打印机唯一标识 + 命令 + 参数」，
服务端完成 Connect 自动化（打印）或 LAN MQTT 控制（暂停/继续/停止）。

接口:
  GET  /health     -> {ok, app_running, ax_ready, uid_resolved, busy}
  GET  /devices    -> 云端设备注册表（serial/name/online/model，access_code 掩码）
  POST /command    body {serial, command, params}
    command=print     params={file | file_b64+filename, filament?: [...],
                              stop_before_send?: bool}
                      file_b64 用于手机/其他设备：文件内容随请求上传，
                      服务端落到 ~/.bambudeck/uploads/ 再派单。
    command=pause      params={}    dev-ON 走 LAN MQTT；云模式回 84033543 明确报错
    command=resume     params={}
    command=stop       params={}
    command=status     params={}    云 MQTT 只读快照
  POST /print      （兼容旧接口，转发 command=print）
  POST /buttons    调试用

命令别名（中文同样可用）: print/打印, pause/暂停, resume/继续/恢复,
  stop/停止, status/状态。

控制路由:
  - 默认走 Bambu Connect 自动化（bconnect_drive.control，正则匹配打印机 + 短路 AX + 跳过锚，
    全链路 ~8s）——dev-OFF/云模式 LAN MQTT 会被固件 84033543 拦，Connect 有合法客户端身份。
  - Connect AX 失败时退回 LAN MQTT（dev-ON 且局域网可达时仍能直接控制）。
局域网 IP 映射从 ~/.bambudeck/printers.json 读；访问码从云端注册表动态取（会变，不写死）。

安全: 只监听 127.0.0.1，X-Deck-Token 校验；token 持久化在 ~/.bambudeck/helper.json，
     重启复用（不再每次换 token）。派单/控制串行执行（busy 时回 409）。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bconnect_cloud as cloud  # noqa: E402
import bconnect_drive as drive  # noqa: E402
import bconnect_print as bp     # noqa: E402

_INFO = os.path.expanduser("~/.bambudeck/helper.json")
_LAN_CONF = os.path.expanduser("~/.bambudeck/printers.json")

# 局域网自动发现：helper 每 5s 广播一条 UDP beacon 到 255.255.255.255:8798。
# 载荷 {type, uid, name, port, version}；客户端按数据报源 IP 拼回 HTTP 地址，
# 再调 /identity 校验 Bambu 账号是否一致（一致才允许调用）。
_BEACON_PORT = 8798
_BEACON_INTERVAL = 5.0

# 打印机列表定期拉取间隔：后台线程定期 GET /user/bind，列表有变化时立即
# 重建名称↔序列号映射（无变化不动）。30s 保证改名/增删「及时」跟上。
_MAPPING_REFRESH_INTERVAL = 30.0

TOKEN = secrets.token_urlsafe(16)

# 单飞锁：派单/控制必须串行（UI 自动化不能并发点两下）
_BUSY = threading.Lock()

# 命令别名
_COMMAND_ALIASES = {
    "print": "print", "打印": "print",
    "pause": "pause", "暂停": "pause",
    "resume": "resume", "继续": "resume", "恢复": "resume",
    "stop": "stop", "停止": "stop",
    "status": "status", "状态": "status",
}


# ---------------------------------------------------------------- 配置
def load_token() -> None:
    """优先复用已持久化的 token，重启不失效；否则新生成。"""
    global TOKEN
    try:
        with open(_INFO) as f:
            tok = json.load(f).get("token")
        if tok:
            TOKEN = tok
    except Exception:
        pass


def write_info(url: str) -> str:
    os.makedirs(os.path.dirname(_INFO), exist_ok=True)
    with open(_INFO, "w") as f:
        json.dump({"url": url, "token": TOKEN}, f)
    os.chmod(_INFO, 0o600)
    return _INFO


def load_lan_conf() -> dict:
    """serial -> {ip, name}。机器相关（换机器部署要改）。"""
    try:
        with open(_LAN_CONF) as f:
            return json.load(f)
    except Exception:
        return {}


def _frontmost_app() -> str | None:
    """当前最前 app 名字（Connect 自动化会把 Connect 置前，结束后还原焦点）。"""
    r = subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to get name of first process '
         'whose frontmost is true'],
        capture_output=True, text=True, timeout=30)
    return (r.stdout or "").strip() or None


def _restore_frontmost(prev: str | None) -> None:
    """把焦点还给操作前的 app（若它不是 Connect 且还活着）。绝不抛异常。"""
    if not prev or prev == "Bambu Connect":
        return
    try:
        subprocess.run(
            ["osascript", "-e", 'tell application "%s" to activate' % prev],
            capture_output=True, text=True, timeout=30)
    except Exception:  # noqa: BLE001
        pass


# ---------------------------------------------------------------- 控制
def lan_control(serial: str, command: str) -> dict:
    """dev-ON 打印机局域网控制（pause/resume/stop）。云模式回 84033543。

    容错关键：打印机局域网可能卡死（TCP ESTABLISHED 但 CONNACK 不来）。把 MQTT
    交互放进 daemon 线程 + join(15)，无论卡不卡，服务 15s 内必返回。结果先落
    box 再清理，避免 disconnect 拖慢时把成功结果也丢掉。
    """
    entry = load_lan_conf().get(serial) or {}
    ip = entry.get("ip")
    if not ip:
        return {"ok": False,
                "error": "局域网 IP 未配置（%s 缺 %s 的 ip）" % (_LAN_CONF, serial)}
    dev = cloud.resolve_device(serial)
    code = (dev or {}).get("access_code")
    if not code:
        return {"ok": False, "error": "取不到 %s 的访问码" % serial}

    box: dict = {}

    def worker():
        _lan_command(ip, code, serial, command, box)

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    t.join(15)
    if "result" in box:
        return box["result"]
    return {"ok": False,
            "error": "%s 超时（打印机局域网无响应，可能离线或 8883 卡死）" % command}


def _lan_command(ip: str, code: str, serial: str, command: str,
                 box: dict, conn_timeout: float = 6.0,
                 ack_timeout: float = 4.0) -> None:
    """单次 LAN MQTT 控制（daemon 线程内执行）。结果写进 box，不抛异常。"""
    import ssl as _ssl
    import time as _t
    import uuid as _uuid

    import paho.mqtt.client as _mqtt

    seq = str(20000 + int(_t.time()) % 5000)  # sequence_id 安全区（≤2147483647）
    ev_conn = threading.Event()
    ack: dict = {}

    ctx = _ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = _ssl.CERT_NONE

    c = _mqtt.Client(_mqtt.CallbackAPIVersion.VERSION1,
                     client_id="lan" + _uuid.uuid4().hex[:8],
                     protocol=_mqtt.MQTTv311)
    c.username_pw_set("bblp", code)
    c.tls_set_context(ctx)

    def on_connect(cl, _u, _f, _rc):
        cl.subscribe("device/%s/report" % serial, qos=0)
        ev_conn.set()

    def on_message(_cl, _u, m):
        try:
            j = json.loads(m.payload)
        except Exception:
            return
        p = j.get("print") or {}
        if isinstance(p, dict) and str(p.get("sequence_id")) == seq:
            ack.update(p)

    c.on_connect = on_connect
    c.on_message = on_message

    result: dict
    try:
        c.connect_async(ip, 8883, keepalive=30)
        c.loop_start()
        if not ev_conn.wait(conn_timeout):
            result = {"ok": False, "error": "局域网 MQTT 连接超时 %s" % ip}
        else:
            c.publish("device/%s/request" % serial,
                      json.dumps({"print": {"sequence_id": seq,
                                            "command": command, "param": ""}}),
                      qos=0)
            t0 = _t.time()
            while _t.time() - t0 < ack_timeout and not ack:
                _t.sleep(0.2)
            result = _ack_result(command, ack)
    except Exception as e:  # noqa: BLE001
        result = {"ok": False, "error": "局域网控制异常: %s" % e}

    box["result"] = result  # 先落结果，再清理
    # 只 disconnect()（会终止 daemon 网络线程），不 loop_stop()——它 join 网络
    # 线程，卡在 stalled CONNACK 上会把服务挂死（已踩过）。
    try:
        c.disconnect()
    except Exception:
        pass


def _ack_result(command: str, ack: dict) -> dict:
    if not ack:
        return {"ok": False, "error": "%s 无回执（打印机没响应）" % command}
    if ack.get("result") == "success":
        return {"ok": True, "detail": "已%s" % command, "ack": ack}
    err = ack.get("err_code")
    if err:
        return {"ok": False,
                "error": "%s 被拒 err_code=%s（云模式/dev-OFF，控制需开发者模式）"
                % (command, err), "ack": ack}
    return {"ok": False,
            "error": "%s 未确认: %s" % (command, ack.get("reason") or "?")}


# ---------------------------------------------------------------- 上传
def save_upload(params: dict) -> str:
    """把客户端 base64 上传的模型落到本机，返回绝对路径。

    手机/平板没有「Mac 上的文件路径」这回事，所以远程客户端把字节一起发过来；
    文件名只保留 basename 并清洗，避免路径穿越。
    """
    raw = str(params.get("file_b64") or "")
    if not raw:
        raise ValueError("file_b64 为空")
    if len(raw) > 96 * 1024 * 1024:  # ~72MB 原始数据
        raise ValueError("上传文件过大")
    name = re.sub(r"[^A-Za-z0-9._-]", "_",
                  os.path.basename(str(params.get("filename") or "upload.3mf")))
    if not name.lower().endswith((".3mf", ".gcode")):
        name += ".3mf"
    d = os.path.expanduser("~/.bambudeck/uploads")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(base64.b64decode(raw))
    os.replace(tmp, path)
    return path


# ---------------------------------------------------------------- 命令路由
def dispatch(serial: str, command: str, params: dict) -> dict:
    cmd = _COMMAND_ALIASES.get(command, command)
    if cmd == "print":
        file = params.get("file") or ""
        if not file and params.get("file_b64"):
            try:
                file = save_upload(params)
            except Exception as e:  # noqa: BLE001
                return {"ok": False, "error": "上传文件失败: %s" % e}
        if not file:
            return {"ok": False, "error": "print 缺参数 file"}
        res = bp.run(file,
                     stop_before_send=bool(params.get("stop_before_send")),
                     serial=serial, verbose=True,
                     filament=params.get("filament") or None)
        # 直接返回 run() 的扁平结果（ok/steps/task/printer/error/elapsed_total），
        # 不再包一层 {"result": ...} —— App 侧 CloudPrintResult.fromJson 读的是
        # 扁平键，包一层会让 task/steps/printer 永远为空（2026-10-22 修正）。
        return res
    if cmd in ("pause", "resume", "stop"):
        # 控制走 Bambu Connect 自动化（dev-OFF/云模式 LAN MQTT 被固件 84033543 拦；
        # Connect 持有合法客户端身份，实测全链路 ~8s）。serial 是「打印机唯一标识」
        # （名称或序列号均可，正则匹配）。
        res = drive.control(serial, cmd)
        if res.get("ok"):
            return res
        # Connect AX 失败时退回 LAN MQTT（dev-ON 且局域网可达时可能仍能直接控制）。
        lan = lan_control(serial, cmd)
        if lan.get("ok"):
            return lan
        return res
    if cmd == "status":
        st = cloud.cloud_state(serial, seconds=10)
        return {"ok": bool(st), "result": st}
    return {"ok": False, "error": "未知命令: %s" % command}


# ---------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "BambuDeckService/2.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[svc] " + (fmt % args) + "\n")

    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth_ok(self) -> bool:
        return self.headers.get("X-Deck-Token") == TOKEN

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {
                "ok": True, "busy": _BUSY.locked(),
                "app_running": bp.app_running(),
                "uid_resolved": bool(cloud.resolve_uid()),
            })
            return
        if self.path == "/identity":
            if not self._auth_ok():
                self._send(401, {"ok": False, "error": "bad or missing X-Deck-Token"})
                return
            self._send(200, {
                "ok": True,
                "uid": cloud.resolve_uid() or "",
                "name": socket.gethostname(),
                "version": 1,
            })
            return
        if self.path == "/devices":
            if not self._auth_ok():
                self._send(401, {"ok": False, "error": "bad or missing X-Deck-Token"})
                return
            devs = []
            for d in cloud.device_list():
                c = d.get("access_code") or ""
                devs.append({"serial": d["serial"], "name": d["name"],
                             "online": d["online"], "model": d["model"],
                             "access_code": (c[:2] + "…" if c else None)})
            self._send(200, {"ok": True, "devices": devs})
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if not self._auth_ok():
            self._send(401, {"ok": False, "error": "bad or missing X-Deck-Token"})
            return
        payload = self._body()

        if self.path == "/buttons":
            try:
                bp.ensure_app()
                bp.enable_ax()
                self._send(200, {"ok": True, "buttons": bp.list_buttons()})
            except Exception as e:  # noqa: BLE001
                self._send(500, {"ok": False, "error": str(e)})
            return

        # 兼容旧接口 POST /print {file, serial, stop_before_send}
        if self.path == "/print":
            payload = dict(payload)
            payload.setdefault("serial", payload.get("serial") or "")
            payload.setdefault("command", "print")
            payload.setdefault("params", {
                "file": payload.get("file"),
                "stop_before_send": payload.get("stop_before_send"),
                "filament": payload.get("filament"),
            })
            self.path = "/command"

        if self.path != "/command":
            self._send(404, {"ok": False, "error": "not found"})
            return

        serial = str(payload.get("serial") or "")
        command = str(payload.get("command") or "")
        params = payload.get("params") or {}
        if not serial:
            self._send(400, {"ok": False, "error": "缺字段 serial"})
            return
        if not command:
            self._send(400, {"ok": False, "error": "缺字段 command"})
            return

        cmd = _COMMAND_ALIASES.get(command, command)
        mutating = cmd in ("print", "pause", "resume", "stop")
        if mutating and not _BUSY.acquire(blocking=False):
            self._send(409, {"ok": False, "error": "已有命令在执行，请稍后重试"})
            return
        # 只有打印会抢焦点（CGEvent 点像素坐标必须 Connect 在最前）；控制走 AXPress，
        # 后台也能按，省掉两次 osascript 前台查询/还原（~0.3s）。
        prev = _frontmost_app() if cmd == "print" else None
        try:
            res = dispatch(serial, command, params)
        except Exception as e:  # noqa: BLE001
            res = {"ok": False, "error": str(e)}
        finally:
            if mutating:
                _BUSY.release()
            _restore_frontmost(prev)

        self._send(200 if res.get("ok") else 502, res)


def _beacon_loop(http_port: int) -> None:
    """广播本服务供局域网客户端自动发现。载荷含 uid(账号)与 hostname;
    客户端按数据报源 IP 拼回 http://<ip>:<port>,再调 /identity 校验账号。"""
    while True:
        try:
            msg = json.dumps({
                "type": "bambudeck-helper",
                "uid": cloud.resolve_uid() or "",
                "name": socket.gethostname(),
                "port": http_port,
                "version": 1,
            }, ensure_ascii=False).encode("utf-8")
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.sendto(msg, ("255.255.255.255", _BEACON_PORT))
            s.close()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(_BEACON_INTERVAL)


def _mapping_refresh_loop() -> None:
    """定期拉取云端打印机列表；列表一变就重建名称↔序列号映射（没变不动）。

    作用：调用传入序列号时（换盘/打印目标机核对）能立刻拿到「正确名称」，
    而不是依赖调用那一刻才刷新的懒缓存（反馈 2026-10-23）。
    """
    while True:
        try:
            cloud.ensure_mapping(force=True)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(_MAPPING_REFRESH_INTERVAL)


def lan_ip() -> str | None:
    """本机在局域网里的地址（不真的发包，只是让内核选出口网卡）。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:  # noqa: BLE001
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=None,
                    help="监听地址（默认 127.0.0.1，--lan 时 0.0.0.0）")
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--lan", action="store_true",
                    help="监听 0.0.0.0，让手机/平板/其他电脑调用本服务")
    args = ap.parse_args()

    host = args.host or ("0.0.0.0" if args.lan else "127.0.0.1")
    loopback = host in ("127.0.0.1", "localhost", "::1")

    load_token()
    if not loopback:
        # 只有真的对外监听时广播才有意义；仅本机时广播只会误导局域网客户端。
        threading.Thread(target=_beacon_loop, args=(args.port,), daemon=True).start()
    threading.Thread(target=_mapping_refresh_loop, daemon=True).start()
    srv = ThreadingHTTPServer((host, args.port), Handler)
    # helper.json 里写「客户端该连的地址」：对外监听时写局域网 IP，
    # 这样手机端「读本机 helper」拿到的就是能用的地址。
    dial = "127.0.0.1" if loopback else (lan_ip() or host)
    url = "http://%s:%d" % (dial, args.port)
    info_path = write_info(url)
    out = {"ok": True, "listening": url, "host": host, "info_file": info_path}
    if loopback:
        out["hint"] = "只监听本机；手机/平板访问请加 --lan 重新启动"
    print(json.dumps(out, ensure_ascii=False), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
