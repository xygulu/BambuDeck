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
    "speed": "speed", "速度": "speed",
    "status": "status", "状态": "status",
}


# ---------------------------------------------------------------- 配置
def load_token() -> None:
    """优先复用已持久化的 token，重启不失效；否则新生成。"""
    global TOKEN
    try:
        # utf-8-sig：PowerShell 导出的配置常带 BOM，直接 json.load 会炸
        # （2026-10-28 Windows 机实测：BOM 让 load_token 失败 → 服务重新
        # 生成 token → 和 hub.json 里的对不上，控制全 401）。
        with open(_INFO, encoding="utf-8-sig") as f:
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


def _activate_connect() -> bool:
    """把 Connect 置前。CGEvent 点像素坐标点的是最顶层窗口，它不在前就点空。"""
    try:
        r = subprocess.run(
            ["osascript", "-e", 'tell application "%s" to activate' % bp.APP],
            capture_output=True, text=True, timeout=30)
        return r.returncode == 0
    except Exception:  # noqa: BLE001
        return False


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


def current_speed_level(serial: str, wait: float = 5.0) -> int | None:
    """云 pushall 读 spd_lvl —— 权威当前档位（帧到早退，实测 ~2s）。

    Connect 界面的百分比要 10~20s 才刷新，拿它判「已经是这一档」会用旧值
    误判（2026-10-27 实测：运动→标准 被滞后的 100% 骗成 already）。
    局域网 report 只有稀疏心跳帧（温度/wifi，没 spd_lvl），完整帧走云端。
    None = 读不到（离线/超时），调用方自行退化。
    """
    box: dict = {}
    ev = threading.Event()

    def worker() -> None:
        import ssl as _ssl
        import uuid as _uuid

        import paho.mqtt.client as _mqtt

        c = None
        try:
            token = cloud.load_session()
            uid = cloud.resolve_uid(token)
            if not uid:
                return
            c = _mqtt.Client(_mqtt.CallbackAPIVersion.VERSION1,
                             client_id="spd" + _uuid.uuid4().hex[:8],
                             protocol=_mqtt.MQTTv311)
            c.username_pw_set("u_" + uid, token)
            c.tls_set_context(_ssl.create_default_context())

            def on_connect(cl, _u, _f, _rc):
                cl.subscribe("device/%s/report" % serial, qos=0)
                cl.publish("device/%s/request" % serial,
                           json.dumps({"pushing": {"sequence_id": "99002",
                                                   "command": "pushall"}}), qos=0)

            def on_message(_cl, _u, m):
                if ev.is_set():
                    return
                try:
                    p = (json.loads(m.payload) or {}).get("print") or {}
                except Exception:  # noqa: BLE001
                    return
                lvl = p.get("spd_lvl")
                if lvl is not None:
                    try:
                        box["lvl"] = int(lvl)
                    except (TypeError, ValueError):
                        pass
                    ev.set()

            c.on_connect = on_connect
            c.on_message = on_message
            c.connect(cloud.MQTT_HOST, cloud.MQTT_PORT, 30)
            c.loop_start()
            ev.wait(wait)
        except Exception:  # noqa: BLE001
            pass
        finally:
            # 只 disconnect()：loop_stop 会 join 网络线程，卡在 stalled
            # CONNACK 上会把服务挂死（LAN MQTT 踩过的坑，云上同防）。
            try:
                if c is not None:
                    c.disconnect()
            except Exception:  # noqa: BLE001
                pass

    t = threading.Thread(target=worker, daemon=True)
    t.start()
    t.join(wait + 3)
    return box.get("lvl")


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
    if cmd == "speed":
        # 调速必须让 **Connect** 发 print_speed: App 自己经 LAN/云 MQTT 发的
        # 会被固件拦 (84033543) 或收下不改档 —— 这是签名问题的老账。
        # Connect 设备页的档位按钮就是同一条命令, 点它等于用官方身份发。
        try:
            level = int(params.get("level") or 0)
        except (TypeError, ValueError):
            level = 0
        return drive.set_speed(serial, level)
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
            # Windows 移植 (2026-10-28): 子系统缺失时降级为 False, 健康检查不能崩
            # (app_running 无进程探测 / resolve_uid 无云会话文件都会抛异常)。
            def _safe(fn) -> bool:
                try:
                    return bool(fn())
                except Exception:  # noqa: BLE001
                    return False
            self._send(200, {
                "ok": True, "busy": _BUSY.locked(),
                "app_running": _safe(bp.app_running),
                "uid_resolved": _safe(cloud.resolve_uid),
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
            # 401 前先把 body 读干净：不读完就 close，TCP 会发 RST 而不是 FIN，
            # RST 会把刚写出的错误响应从客户端接收缓冲里冲掉 —— Dart 端看到的
            # 是「Connection closed while receiving data」而不是 401 原文
            # （2026-10-28 Windows hub 调 helper 实测）。只在不通过时排空，
            # 正常路径的 body 仍交给 _body() 读。
            try:
                n = int(self.headers.get("Content-Length") or 0)
                if 0 < n <= 256 * 1024 * 1024:
                    self.rfile.read(n)
            except Exception:  # noqa: BLE001
                pass
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

        # 兼容旧接口 POST /print {file | file_b64+filename, serial,
        # stop_before_send}。file_b64/filename 必须跟着进 params —— 远程客户端
        # （Windows/手机）没有「Mac 本机路径」可发，只发字节流；漏拷的话
        # dispatch 里看不到 file_b64，报「print 缺参数 file」（2026-10-26 实测，
        # Windows 一键换盘 502 的根因）。
        if self.path == "/print":
            payload = dict(payload)
            payload.setdefault("serial", payload.get("serial") or "")
            payload.setdefault("command", "print")
            payload.setdefault("params", {
                "file": payload.get("file"),
                "file_b64": payload.get("file_b64"),
                "filename": payload.get("filename"),
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
        global _BUSY
        mutating = cmd in ("print", "pause", "resume", "stop", "speed")
        if mutating:
            # print 抢锁失败就别排了（后面 check 阶段也会因冲突失败）；
            # 控制/调速撞上换盘（~7-15s）时等一把再上，比直接 409 可用性好。
            if not _BUSY.acquire(timeout=0 if cmd == "print" else 20):
                self._send(409, {"ok": False, "error": "已有命令在执行，请稍后重试"})
                return
        if cmd == "speed":
            # 权威预检：云 pushall 的 spd_lvl 就是当前档位（~2s）。已在这档
            # 直接返回，连 Connect 窗口都不弹；界面百分比滞后 10-20s，不可信。
            try:
                want = int(params.get("level"))
            except (TypeError, ValueError):
                want = 0
            cur = current_speed_level(serial) if want in (1, 2, 3, 4) else None
            if cur is not None and cur == want:
                dev = cloud.resolve_device(serial) or {}
                self._send(200, {
                    "ok": True, "command": "speed", "level": want,
                    "printer": dev.get("name") or serial, "serial": serial,
                    "method": "already", "from": "%d档" % cur,
                    "to": "%d档" % cur, "confirmed": True,
                    "elapsed": 0.0, "steps": {"cloud_precheck": True},
                })
                return
        # 打印和调速都要真实鼠标点击（Connect 是 Electron，档位下拉/百分比不是
        # AXButton，AXPress 点不动），点像素坐标必须 Connect 在最前；控制按钮走
        # AXPress，后台也能按，省掉两次 osascript 前台查询/还原（~0.3s）。
        need_click = cmd in ("print", "speed")
        prev = _frontmost_app() if need_click else None
        if need_click:
            _activate_connect()
        # 看门狗：dispatch 全链路都有界，但真机见过命令卡 10+ 分钟把锁占死、
        # 之后所有命令全 409（2026-10-27）。daemon 线程跑 dispatch，超时就
        # 弃线程、换新锁，服务绝不陪葬。print 整流程最慢（导入等待+任务落库）
        # 给 300s，其余 120s。
        budget = 300.0 if cmd == "print" else 120.0
        box: dict = {}
        held = _BUSY if mutating else None

        def _run() -> None:
            try:
                box["res"] = dispatch(serial, command, params)
            except Exception as e:  # noqa: BLE001
                box["res"] = {"ok": False, "error": str(e)}

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        t.join(budget)
        if t.is_alive():
            _BUSY = threading.Lock()  # 僵尸线程抱着旧锁，服务换新锁继续
            res = {"ok": False,
                   "error": "命令 %s 执行超过 %ds 没有返回，已放弃（服务已解锁）"
                            % (command, int(budget))}
            print("[watchdog] %s %s 超时被弃" % (serial, command), flush=True)
        else:
            res = box.get("res") or {"ok": False, "error": "命令无返回结果"}
        try:
            if held is not None and held is _BUSY:
                held.release()
        except Exception:  # noqa: BLE001
            pass
        _restore_frontmost(prev)

        if cmd == "speed":
            if res.get("ok"):
                # 权威确认：spd_lvl 变了才算数；没变则保留「未确认」提示
                # （界面/机器回传都有滞后，交给调用方的 awaitSpeedLevel 兜底）。
                after = current_speed_level(serial, wait=4)
                if after is not None:
                    res["confirmed"] = (after == res.get("level"))
                    if res["confirmed"]:
                        res.pop("note", None)
                    else:
                        res["spd_lvl_now"] = after
            # 调速步骤只活在返回 JSON 里，之前日志里啥都不留，出问题没法查。
            print("[speed] %s L%s ok=%s method=%s confirmed=%s elapsed=%s err=%s"
                  % (serial, params.get("level"), res.get("ok"),
                     res.get("method"), res.get("confirmed"),
                     res.get("elapsed"), res.get("error") or "-"),
                  flush=True)
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
