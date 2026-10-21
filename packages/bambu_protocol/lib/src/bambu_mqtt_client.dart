/// MQTT client for Bambu printers - LAN direct and Bambu Cloud modes.
///
/// Ported from BambuHelper `src/bambu_mqtt.cpp` connection semantics:
/// TLS on 8883, LAN auth `bblp` + access code, cloud auth `u_{uid}` + token,
/// subscribe `device/{serial}/report`, request via `device/{serial}/request`,
/// pushall to force a full snapshot, exponential backoff reconnect.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show X509Certificate;
import 'dart:math';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:pointycastle/export.dart' show RSAPublicKey;
import 'package:typed_data/typed_data.dart';

import 'bambu_field_encryption.dart';
import 'bambu_signing.dart';
import 'models.dart';
import 'report_parser.dart';

enum BambuConnStatus { disconnected, connecting, connected, reconnecting, error }

class BambuMqttConfig {
  const BambuMqttConfig({
    required this.mode,
    required this.serial,
    required this.host,
    required this.username,
    required this.password,
    this.port = 8883,
  });

  factory BambuMqttConfig.lan({
    required String ip,
    required String serial,
    required String accessCode,
  }) =>
      BambuMqttConfig(
        mode: PrinterMode.lan,
        serial: serial,
        host: ip,
        username: 'bblp',
        password: accessCode,
      );

  factory BambuMqttConfig.cloud({
    required CloudRegion region,
    required String serial,
    required String userId, // "u_{uid}"
    required String token,
  }) =>
      BambuMqttConfig(
        mode: PrinterMode.cloud,
        serial: serial,
        host: region.mqttHost,
        username: userId,
        password: token,
      );

  final PrinterMode mode;
  final String serial;
  final String host;
  final int port;
  final String username;
  final String password;

  /// LAN printers serve self-signed certificates; cloud uses CA-signed ones.
  bool get acceptBadCertificates => mode == PrinterMode.lan;
}

/// 一条 `print` 命令的固件回执。
///
/// 成功: `{"print":{"sequence_id":"…","command":"pause","result":"success",
/// "reason":"success"}}`。
/// 被拒: 只有 `err_code`、**没有** `result` 字段 —— 这正是「按钮点了没反应」
/// 的根源(旧代码只在报文含 result/reason 时打日志，err_code 帧被整个吞掉)。
class BambuCommandAck {
  const BambuCommandAck({this.command, this.result, this.reason, this.errCode});

  final String? command;
  final String? result;
  final String? reason;
  final int? errCode;

  bool get success => result == 'success';

  /// 给人看的一句话，直接丢到 UI/日志里。
  String get describe {
    if (success) return '$command 成功';
    switch (errCode) {
      case 84033543:
        return '$command 被拒(84033543): 固件要求 print 帧带签名 —— '
            '需在该打印机上开启「开发者模式」(设置→网络→仅局域网模式→开发者模式→'
            '勾选确认→启用→重启)';
      case 84033544:
        return '$command 被拒(84033544): 文件校验失败或 sequence_id 复用';
      case 84033545:
        return '$command 被拒(84033545): 报文格式错误';
      case 84033546:
        return '$command 被拒(84033546): 签名无效(所用证书已被打印机吊销)';
      case 84033547:
      case 84033548:
        return '$command 被拒($errCode): 应用证书未安装';
      default:
        return '$command 被拒(err_code=${errCode ?? '?'}'
            '${reason == null ? '' : ' $reason'})';
    }
  }
}

class BambuMqttClient {
  BambuMqttClient({
    required this.config,
    this.log,
    String? clientId,
    String? signingKeyPem,
  })  : clientId = clientId ??
            'bambudeck_${DateTime.now().millisecondsSinceEpoch % 0xFFFFF}',
        _signer =
            signingKeyPem == null ? null : BambuCommandSigner.fromPem(signingKeyPem);

  final BambuMqttConfig config;
  final String clientId;

  /// Optional sink for diagnostics.
  final void Function(String line)? log;

  /// Signs `print` commands (bambu_signing.dart). Null = unsigned frames,
  /// which post-2025-01 firmware rejects with 84033543.
  final BambuCommandSigner? _signer;

  /// Printer device-cert public key (CN=<serial>), captured from the LAN TLS
  /// handshake on :8883 — the key firmware decrypts `url_enc`/`param_enc`
  /// against. Null until the first (re)connect or for cloud transports.
  RSAPublicKey? _devicePublicKey;

  /// Developer-mode-off (secured) override. Null = auto-detect from
  /// `print.fun` bit 29 in the report stream (unreported on A1 01.07.02.00,
  /// so a caller that already knows the toggle state can pin it here).
  bool? _securedOverride;

  BambuFieldEncryptor? get _fieldEncryptor {
    final key = _devicePublicKey;
    return key == null ? null : BambuFieldEncryptor(key);
  }

  /// Whether the next `print` command should be field-encrypted (`*_enc`).
  /// Resolves override → report bit 29 → false (assume developer mode on).
  bool get _secured => _securedOverride ?? _lastState?.developerModeOff ?? false;

  /// The captured device cert public key, for tests/tools that build `*_enc`
  /// fields themselves. Null until the TLS handshake has completed.
  RSAPublicKey? get devicePublicKey => _devicePublicKey;

  MqttServerClient? _client;
  Timer? _staleTimer;
  Timer? _reconnectTimer;
  int _backoffMs = 2000;
  bool _disposed = false;
  DateTime _lastMessageAt = DateTime.now();
  // Last parsed state, fed back as `previous` so partial frames (only a few
  // fields) never blank out job identity on the dashboard.
  BambuState? _lastState;

  /// Signed frames are rejected below sequence_id 2000 (84033545); Studio
  /// lives in 20000-29999. Start at a random point above the floor and count
  /// monotonically - reusing ids across app restarts has also been rejected.
  int _sequence = 20000 + Random().nextInt(1 << 24);

  static const _stalePushallAfter = Duration(seconds: 30);
  static const _staleReconnectAfter = Duration(seconds: 90);
  static const _maxBackoffMs = 60000;

  final _states = StreamController<BambuState>.broadcast();
  final _status = StreamController<BambuConnStatus>.broadcast();

  /// sequence_id → 正在等回执的 completer。固件把回执塞回 report 流里，
  /// 不按 seq 关联的话，成功和失败都只能靠猜。
  final Map<String, Completer<BambuCommandAck>> _pendingAcks = {};

  Stream<BambuState> get states => _states.stream;
  Stream<BambuConnStatus> get status => _status.stream;
  BambuConnStatus get currentStatus => _statusValue;
  BambuConnStatus _statusValue = BambuConnStatus.disconnected;

  String get _reportTopic => 'device/${config.serial}/report';
  String get _requestTopic => 'device/${config.serial}/request';

  // -- lifecycle ------------------------------------------------------------

  Future<void> connect() async {
    if (_disposed) return;
    _setStatus(BambuConnStatus.connecting);
    try {
      await _connectOnce();
      _setStatus(BambuConnStatus.connected);
      _backoffMs = 2000;
      _lastMessageAt = DateTime.now();
      await requestPushall(reason: 'connect');
      _startStaleWatch();
    } catch (e) {
      // Plain catch (not `on Exception`): mqtt_client can surface TypeError
      // (an Error) from its internals, and any failure must degrade to the
      // reconnect path rather than escape to the caller.
      _logLine('connect failed: $e');
      _setStatus(BambuConnStatus.reconnecting);
      _scheduleReconnect();
    }
  }

  void dispose() {
    _disposed = true;
    _staleTimer?.cancel();
    _reconnectTimer?.cancel();
    try {
      _client?.autoReconnect = false;
      _client?.disconnect();
    } on Exception {
      // ignore - socket may already be gone
    }
    _client = null;
    _states.close();
    _status.close();
  }

  Future<void> _connectOnce() async {
    final client = MqttServerClient.withPort(
        config.host, clientId, config.port);
    client.secure = true;
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.connectTimeoutPeriod = 5000;
    client.autoReconnect = false; // we drive reconnection ourselves
    if (config.acceptBadCertificates) {
      // mqtt_client casts this to bool Function(Object) internally
      // (mqtt_server_client.dart:165), so the parameter must be typed Object -
      // a (X509Certificate) signature fails that runtime cast.
      client.onBadCertificate = (Object cert) {
        // The LAN self-signed leaf IS the printer device cert (CN=<serial>);
        // its public key is what firmware decrypts url_enc/param_enc against
        // (§10.2). Capture it so secured project_file can field-encrypt.
        if (cert is X509Certificate) {
          try {
            _devicePublicKey = rsaPublicKeyFromCertPem(cert.pem);
            _logLine('已捕获设备证书公钥(字段加密)');
          } catch (e) {
            _logLine('设备证书公钥解析失败: $e');
          }
        }
        return true;
      };
    }

    _logLine('connecting ${config.host}:${config.port} as ${config.username}');
    await client.connect(config.username, config.password);

    final state = client.connectionStatus?.state;
    if (state != MqttConnectionState.connected) {
      throw Exception('MQTT connect ended in $state');
    }

    client.onDisconnected = () {
      if (_disposed) return;
      _logLine('connection lost');
      _setStatus(BambuConnStatus.reconnecting);
      _staleTimer?.cancel();
      _scheduleReconnect();
    };

    client.subscribe(_reportTopic, MqttQos.atLeastOnce);
    // NOTE: do NOT also subscribe to the request topic. The printer's broker
    // enforces per-topic ACLs and drops the CONNECTION on an unauthorized
    // subscribe - every printer went into a connect/kill/reconnect loop and
    // none came online (全部打印机连不上 2026-10-21). Command delivery is
    // QoS 1 (PUBACK), so there is no need to echo-read the inbox anyway.

    client.updates!.listen((messages) {
      for (final rec in messages) {
        if (rec.topic != _reportTopic) continue;
        // updates yields MqttReceivedMessage<MqttMessage?>: the payload's
        // runtime type is MqttPublishMessage (declared as the MqttMessage
        // base type), and the raw bytes sit one hop deeper in .payload.message.
        final recMess = rec.payload as MqttPublishMessage;
        final text =
            MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        _lastMessageAt = DateTime.now();
        // 命令回执: 固件在 report 流里按 sequence_id 回执。被拒帧只有
        // err_code、没有 result —— 必须在这里抓，否则「按钮点了没反应」
        // 永远查不到原因(换盘诊断 2026-10-21)。
        _captureAck(text);
        final state = parseReport(text, previous: _lastState);
        if (state != null) {
          _lastState = state;
          _states.add(state);
        }
      }
    });

    _client = client;
  }

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) return;
    final delay = _backoffMs;
    _backoffMs = (_backoffMs * 2).clamp(2000, _maxBackoffMs);
    _logLine('reconnect in ${delay}ms');
    _reconnectTimer = Timer(Duration(milliseconds: delay), () async {
      _reconnectTimer = null;
      _teardownClient();
      if (_disposed) return;
      await connect();
    });
  }

  void _teardownClient() {
    _staleTimer?.cancel();
    _staleTimer = null;
    final old = _client;
    _client = null;
    if (old != null) {
      old.autoReconnect = false;
      try {
        old.disconnect();
      } on Exception {
        // ignore
      }
    }
  }

  /// While connected, watch for silence: nudge with a pushall after 30s,
  /// force a reconnect after 90s. Ported from the ESP32 stale-pushall logic.
  void _startStaleWatch() {
    _staleTimer?.cancel();
    _staleTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
      if (_disposed || _client == null) {
        t.cancel();
        return;
      }
      final idle = DateTime.now().difference(_lastMessageAt);
      if (idle > _staleReconnectAfter) {
        _logLine('stale for ${idle.inSeconds}s, forcing reconnect');
        t.cancel();
        _setStatus(BambuConnStatus.reconnecting);
        _teardownClient();
        _scheduleReconnect();
      } else if (idle > _stalePushallAfter) {
        await requestPushall(reason: 'stale');
      }
    });
  }

  void _setStatus(BambuConnStatus s) {
    _statusValue = s;
    if (!_status.isClosed) _status.add(s);
  }

  void _logLine(String line) => log?.call('[${config.serial}] $line');

  /// 从 report 流里抓命令回执：`result` 或 `err_code` 任一出现即为回执帧，
  /// 按 `sequence_id` 兑现等待中的 completer。
  ///
  /// 注意被拒帧的形状是 `{"print":{…,"err_code":84033543}}` —— 没有
  /// `result`、没有 `reason`，只认 result 的写法会把它当普通状态帧丢掉。
  void _captureAck(String text) {
    if (!text.contains('err_code') && !text.contains('"result"')) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    for (final ns in const ['print', 'info', 'system', 'security']) {
      final node = decoded[ns];
      if (node is! Map) continue;
      if (!node.containsKey('result') && !node.containsKey('err_code')) {
        continue;
      }
      final ack = BambuCommandAck(
        command: node['command']?.toString(),
        result: node['result']?.toString(),
        reason: node['reason']?.toString(),
        errCode: node['err_code'] is int
            ? node['err_code'] as int
            : int.tryParse('${node['err_code']}'),
      );
      _logLine('回执 ${ack.describe}');
      final seq = node['sequence_id']?.toString();
      if (seq == null) continue;
      final pending = _pendingAcks.remove(seq);
      if (pending != null && !pending.isCompleted) pending.complete(ack);
    }
  }

  // -- publishing -----------------------------------------------------------

  Future<bool> _publish(String json) async {
    final client = _client;
    final state = client?.connectionStatus?.state;
    _logLine('publish state=$state $json');
    if (client == null || state != MqttConnectionState.connected) {
      _logLine('publish ABORTED (not connected)');
      return false;
    }
    try {
      // QoS 1: the reference clients publish commands at QoS 1 (OpenBambuAPI
      // sends print.stop at QoS 1; bambu-mqtt-comms send_and_wait defaults to
      // qos=1). Publishing at QoS 0 stopped the chamber-light command reaching
      // the printer (灯光开关失效 2026-10-20) - the earlier "QoS 1 dropped"
      // read was the wrong-command-name / signing rejection, not QoS.
      client.publishMessage(
          _requestTopic, MqttQos.atLeastOnce, _payloadBytes(json));
      _logLine('publish OK');
      return true;
    } on Exception catch (e) {
      _logLine('publish failed: $e');
      return false;
    }
  }

  Uint8Buffer _payloadBytes(String json) {
    final buf = Uint8Buffer();
    buf.addAll(utf8.encode(json));
    return buf;
  }

  /// Inner `print` command node; wrap with [_publishSigned]. Unsigned print
  /// frames are silently dropped by post-2025-01 firmware (84033543) - the
  /// 暂停/停止/换盘 dead-air symptom (2026-10-21).
  Map<String, dynamic> _printNode(String command, Map<String, dynamic> extra) =>
      {'sequence_id': _nextSequence(), 'command': command, ...extra};

  String _nextSequence() => (_sequence++).toString();

  Future<bool> _publishSigned(Map<String, dynamic> printNode) {
    final signer = _signer;
    return _publish(signer == null
        ? jsonEncode({'print': printNode})
        : signer.wrapSigned(printNode));
  }

  /// System-envelope command. ledctrl rides `system`, not `print`, and the
  /// A1/P1 silently DROP it unless the timing fields are present - payload
  /// mirrors BambuHelper sendLightCtrlNode (field-proven on LAN + cloud).
  /// `system` frames are never signed.
  Map<String, dynamic> _systemNode(String command, Map<String, dynamic> extra) =>
      {
        'system': {
          'sequence_id': _nextSequence(),
          'command': command,
          ...extra,
        }
      };

  /// Force a full state snapshot. Reasons mirror BambuHelper PushallReason.
  /// `pushing` frames are never signed.
  Future<bool> requestPushall({String reason = 'manual'}) {
    _logLine('pushall ($reason)');
    return _publish(jsonEncode({
      'pushing': {
        'sequence_id': _nextSequence(),
        'command': 'pushall',
        'push_target': 1,
      }
    }));
  }

  // Bambu's control commands are `pause`/`resume`/`stop` (no `_print`
  // suffix — that suffix only appears in `print_speed`). Sending `stop_print`
  // is silently ignored by the printer (停止按钮不起作用 2026-10-20).
  // 2025+ 固件要求 print 帧显式带 `param`(哪怕是空串),缺了整帧被静默丢弃
  // 连错误都不回(doctor.py L1 探针实测 2026-10-21)。
  Future<bool> pausePrint() => _controlCommand('pause');
  Future<bool> resumePrint() => _controlCommand('resume');
  Future<bool> stopPrint() => _controlCommand('stop');

  /// 发一条控制命令并等固件回执。返回值语义是「**打印机接受了没有**」，
  /// 不是「MQTT publish 成功没有」—— 这两件事差别很大：publish 成功而
  /// 打印机拒收(如云模式 84033543)时，旧写法照样返回 true，UI 就表现成
  /// 无响应。
  ///
  /// 命令不需要回执时(超时)沿用 publish 结果，避免误报失败。
  Future<bool> _controlCommand(String command) async {
    final node = _printNode(command, {'param': ''});
    final seq = node['sequence_id']?.toString();
    final completer = Completer<BambuCommandAck>();
    if (seq != null) _pendingAcks[seq] = completer;

    final published = await _publishSigned(node);
    if (!published) {
      if (seq != null) _pendingAcks.remove(seq);
      _logLine('$command: publish 失败(MQTT 未连接)');
      return false;
    }
    if (seq == null) return true;

    try {
      final ack = await completer.future.timeout(const Duration(seconds: 6));
      return ack.success;
    } on TimeoutException {
      _pendingAcks.remove(seq);
      _logLine('$command: 6s 内无回执(固件不 ack 该命令)，按 publish 成功处理');
      return true;
    }
  }

  /// Prints a 3mf already on the printer's local storage (uploaded over FTPS
  /// first — see BambuDeck's FtpsClient). [url] is the printer-local path in
  /// the documented `ftp:///cache/<file>` spelling; [param] points at the
  /// plate gcode inside the 3mf. [amsSlot] routes the print through the
  /// printer's AMS (A1 + AMS lite: a single unit, [amsId] defaults 0).
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
    int? amsSlot,
    int amsId = 0,
  }) {
    // buildProjectFilePayload returns the full {'print': ...} envelope for
    // testability; the signer wants the inner node so it wraps exactly one
    // print key. Double-wrapping shipped once and the firmware silently
    // dropped the whole frame (print.print.command - 换盘 无响应 2026-10-21).
    //
    // Secured (developer-mode-off) firmware requires `url` → `url_enc`
    // (RSA under the device cert), cleartext `url` alone is rejected 84033544
    // (§10.3). Field-encrypt BEFORE signing so the signature covers `url_enc`.
    String? urlEnc;
    if (_secured) {
      final enc = _fieldEncryptor;
      if (enc == null) {
        _logLine('secured 但尚未拿到设备证书,url 保持明文(将 84033544)');
      } else {
        urlEnc = enc.encryptField(url);
      }
    }
    final envelope = buildProjectFilePayload(
      sequenceId: _nextSequence(),
      url: url,
      urlEnc: urlEnc,
      param: param,
      md5: md5,
      name: name,
      amsSlot: amsSlot,
      amsId: amsId,
    );
    return _publishSigned(envelope['print'] as Map<String, dynamic>);
  }

  /// 1 silent, 2 standard, 3 sport, 4 ludicrous.
  Future<bool> setSpeedLevel(int level) =>
      _publishSigned(_printNode('print_speed', {'param': level.toString()}));

  Future<bool> setChamberLight(bool on) {
    _logLine('ledctrl ${on ? 'on' : 'off'}');
    return _publish(jsonEncode(_systemNode('ledctrl', {
      'led_node': 'chamber_light',
      'led_mode': on ? 'on' : 'off',
      'led_on_time': 500,
      'led_off_time': 500,
      'loop_times': 0,
      'interval_time': 0,
    })));
  }

  /// Pins the secured (developer-mode-off) policy for field encryption. Null
  /// restores auto-detection from `print.fun` bit 29. Needed on firmware that
  /// doesn't report `fun` (A1 01.07.02.00) where the caller already knows the
  /// printer's toggle state.
  void setSecured(bool? secured) => _securedOverride = secured;

  /// Installs the shared app cert chain + CRL into the printer's volatile
  /// trust store (`security.app_cert_install`). RAM-only — re-run after every
  /// printer reboot. Unsigned (it IS the bootstrap that makes later signed
  /// `print` frames verify). The report-stream reply carries `printer_cert`
  /// (the authoritative device cert) + `result`.
  Future<bool> installAppCert({
    required List<String> appCertPems,
    required List<String> crlPems,
  }) {
    _logLine(
        'app_cert_install (${appCertPems.length} certs, ${crlPems.length} crls)');
    return _publish(jsonEncode({
      'security': {
        'sequence_id': _nextSequence(),
        'command': 'app_cert_install',
        'app_cert': appCertPems,
        'crl': crlPems,
      }
    }));
  }

  /// Lists the app cert_ids the printer currently trusts (observability; the
  /// `type` field is mandatory, `sequence_id` must stay a string).
  Future<bool> appCertList() {
    _logLine('app_cert_list');
    return _publish(jsonEncode({
      'security': {
        'sequence_id': '1',
        'command': 'app_cert_list',
        'type': 'app',
      }
    }));
  }
}

/// Payload for the `print.project_file` command (local print). Extracted as
/// a pure function so tests can pin the wire shape the A1 accepts.
Map<String, dynamic> buildProjectFilePayload({
  required String sequenceId,
  required String url,
  String? urlEnc,
  String param = 'Metadata/plate_1.gcode',
  String md5 = '',
  String name = 'BambuDeck',
  int? amsSlot,
  int amsId = 0,
}) =>
    {
      'print': {
        'sequence_id': sequenceId,
        'command': 'project_file',
        'param': param,
        if (md5.isNotEmpty) 'md5': md5,
        'project_id': '0',
        'profile_id': '0',
        'task_id': '0',
        'subtask_id': '0',
        'subtask_name': name,
        // Secured firmware reads url_enc (not url); developer mode needs the
        // cleartext url (§10.3).
        if (urlEnc != null) 'url_enc': urlEnc else 'url': url,
        // A1 + AMS lite: the swap model is sliced for a single PLA filament,
        // so the caller picks a live AMS slot of matching type on every
        // start (颜色不限 - 用户 2026-10-21). ams_id 0 = the A1's single AMS
        // lite unit; both mapping shapes go out (firmware that knows
        // ams_mapping2 prefers it, legacy firmware reads ams_mapping).
        if (amsSlot != null) ...{
          'use_ams': true,
          // A1 的 ams_mapping 是固定 5 元素、从右往左对应槽位、空位填 -1
          // (Doridian/OpenBambuAPI mqtt.md; 调研复核 2026-10-21)。早期的
          // [slot] 是 X1 时代的遗留形态。
          'ams_mapping': [-1, -1, -1, -1, amsSlot],
          'ams_mapping2': [
            {'ams_id': amsId, 'slot_id': amsSlot}
          ],
        } else
          // No AMS match: print from the external spool instead.
          'use_ams': false,
        'bed_leveling': true,
        'flow_cali': false,
        'vibration_cali': false,
        'layer_inspect': false,
        'timelapse': false,
      }
    };
