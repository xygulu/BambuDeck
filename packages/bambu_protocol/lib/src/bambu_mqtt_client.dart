/// MQTT client for Bambu printers - LAN direct and Bambu Cloud modes.
///
/// Ported from BambuHelper `src/bambu_mqtt.cpp` connection semantics:
/// TLS on 8883, LAN auth `bblp` + access code, cloud auth `u_{uid}` + token,
/// subscribe `device/{serial}/report`, request via `device/{serial}/request`,
/// pushall to force a full snapshot, exponential backoff reconnect.
library;

import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:typed_data/typed_data.dart';

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

class BambuMqttClient {
  BambuMqttClient({
    required this.config,
    this.log,
    String? clientId,
  }) : clientId = clientId ??
            'bambudeck_${DateTime.now().millisecondsSinceEpoch % 0xFFFFF}';

  final BambuMqttConfig config;
  final String clientId;

  /// Optional sink for diagnostics.
  final void Function(String line)? log;

  MqttServerClient? _client;
  Timer? _staleTimer;
  Timer? _reconnectTimer;
  int _backoffMs = 2000;
  bool _disposed = false;
  DateTime _lastMessageAt = DateTime.now();
  // Last parsed state, fed back as `previous` so partial frames (only a few
  // fields) never blank out job identity on the dashboard.
  BambuState? _lastState;
  int _pushallSeq = 1;

  static const _stalePushallAfter = Duration(seconds: 30);
  static const _staleReconnectAfter = Duration(seconds: 90);
  static const _maxBackoffMs = 60000;

  final _states = StreamController<BambuState>.broadcast();
  final _status = StreamController<BambuConnStatus>.broadcast();

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
      client.onBadCertificate = (Object cert) => true;
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

  Map<String, dynamic> _node(String command, Map<String, dynamic> extra) => {
        'print': {
          'sequence_id': (_pushallSeq++).toString(),
          'command': command,
          ...extra,
        }
      };

  /// System-envelope command. ledctrl rides `system`, not `print`, and the
  /// A1/P1 silently DROP it unless the timing fields are present - payload
  /// mirrors BambuHelper sendLightCtrlNode (field-proven on LAN + cloud).
  Map<String, dynamic> _systemNode(String command, Map<String, dynamic> extra) =>
      {
        'system': {
          'sequence_id': (_pushallSeq++).toString(),
          'command': command,
          ...extra,
        }
      };

  /// Force a full state snapshot. Reasons mirror BambuHelper PushallReason.
  Future<bool> requestPushall({String reason = 'manual'}) {
    _logLine('pushall ($reason)');
    return _publish(jsonEncode({
      'pushing': {
        'sequence_id': (_pushallSeq++).toString(),
        'command': 'pushall',
        'push_target': 1,
      }
    }));
  }

  // Bambu's control commands are `pause`/`resume`/`stop` (no `_print`
  // suffix — that suffix only appears in `print_speed`). Sending `stop_print`
  // is silently ignored by the printer (停止按钮不起作用 2026-10-20).
  Future<bool> pausePrint() => _publish(jsonEncode(_node('pause', {})));
  Future<bool> resumePrint() => _publish(jsonEncode(_node('resume', {})));
  Future<bool> stopPrint() => _publish(jsonEncode(_node('stop', {})));

  /// Prints a 3mf already on the printer's local storage (uploaded over FTPS
  /// first — see BambuDeck's FtpsClient). [url] is the printer-local path in
  /// the documented `ftp:///cache/<file>` spelling; [param] points at the
  /// plate gcode inside the 3mf. Newer firmware may reject unsigned
  /// project_file with print_error 84033543 — that surfaces in the report
  /// stream and the log for diagnosis.
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
  }) =>
      _publish(jsonEncode(buildProjectFilePayload(
        sequenceId: (_pushallSeq++).toString(),
        url: url,
        param: param,
        md5: md5,
        name: name,
      )));

  /// 1 silent, 2 standard, 3 sport, 4 ludicrous.
  Future<bool> setSpeedLevel(int level) =>
      _publish(jsonEncode(_node('print_speed', {'param': level.toString()})));

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
}

/// Payload for the `print.project_file` command (local print). Extracted as
/// a pure function so tests can pin the wire shape the A1 accepts.
Map<String, dynamic> buildProjectFilePayload({
  required String sequenceId,
  required String url,
  String param = 'Metadata/plate_1.gcode',
  String md5 = '',
  String name = 'BambuDeck',
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
        'url': url,
        // A1 has no AMS: a local file must never try the AMS path. Bed
        // leveling on (A1 levels before every print); the cali flags match
        // what Bambu Studio sends for a plain local print.
        'use_ams': false,
        'bed_leveling': true,
        'flow_cali': false,
        'vibration_cali': false,
        'layer_inspect': false,
        'timelapse': false,
      }
    };
