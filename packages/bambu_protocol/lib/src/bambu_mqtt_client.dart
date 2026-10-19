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
    if (client == null ||
        client.connectionStatus?.state != MqttConnectionState.connected) {
      return false;
    }
    try {
      client.publishMessage(
          _requestTopic, MqttQos.atLeastOnce, _payloadBytes(json));
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

  Future<bool> pausePrint() => _publish(jsonEncode(_node('pause_print', {})));
  Future<bool> resumePrint() => _publish(jsonEncode(_node('resume_print', {})));
  Future<bool> stopPrint() => _publish(jsonEncode(_node('stop_print', {})));

  /// 1 silent, 2 standard, 3 sport, 4 ludicrous.
  Future<bool> setSpeedLevel(int level) =>
      _publish(jsonEncode(_node('print_speed', {'param': level.toString()})));

  Future<bool> setChamberLight(bool on) => _publish(jsonEncode(_node('ledctrl', {
        'led_node': 'chamber_light',
        'led_mode': on ? 'on' : 'off',
      })));
}
