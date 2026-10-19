// Throwaway diagnostics: connect LAN MQTT to a printer, request pushall,
// print the report's key structure. Never prints the access code.
// Usage: dart run tool/dump_pushall_keys.dart <serial> <ip>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main(List<String> args) async {
  final serial = args[0];
  final ip = args[1];

  final confPath =
      '${Platform.environment['HOME']}/Library/Application Support/'
      'BambuStudio/BambuStudio.conf';
  final conf =
      jsonDecode(File(confPath).readAsStringSync()) as Map<String, dynamic>;
  final code = (conf['access_code'] as Map<String, dynamic>)[serial] as String;

  final client = MqttServerClient.withPort(
      ip, 'bambudeck_dump_${DateTime.now().millisecondsSinceEpoch % 0xFFFF}',
      8883)
    ..secure = true
    ..logging(on: false)
    ..keepAlivePeriod = 10
    ..connectTimeoutPeriod = 5000
    ..autoReconnect = false;
  client.onBadCertificate = (Object cert) => true;

  await client.connect('bblp', code);
  if (client.connectionStatus?.state != MqttConnectionState.connected) {
    stderr.writeln('connect failed');
    exit(2);
  }

  final done = Completer<void>();
  client.updates!.listen((messages) {
    for (final m in messages) {
      final pub = m.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
          pub.payload.message);
      final doc = jsonDecode(text) as Map<String, dynamic>;
      final print_ = doc['print'];
      if (print_ is! Map<String, dynamic>) continue;
      stdout.writeln('--- frame (top-level keys) ---');
      for (final k in print_.keys.toList()..sort()) {
        final v = print_[k];
        if (v is Map<String, dynamic>) {
          stdout.writeln('$k: {${(v.keys.toList()..sort()).join(', ')}}');
        } else if (v is List) {
          stdout.writeln('$k: [${v.length}]');
        } else {
          stdout.writeln('$k: $v');
        }
      }
      for (final key in ['ipcam', 'camera', 'cam', 'liveview', 'video']) {
        if (print_[key] != null) {
          stdout.writeln('>> $key FULL: ${jsonEncode(print_[key])}');
        }
      }
      if (!done.isCompleted) done.complete();
    }
  });

  client.subscribe('device/$serial/report', MqttQos.atLeastOnce);
  final info = MqttClientPayloadBuilder()
    ..addString(jsonEncode({
      'pushing': {'command': 'pushall'},
    }));
  client.publishMessage('device/$serial/request',
      MqttQos.atLeastOnce, info.payload!);

  await done.future.timeout(const Duration(seconds: 10), onTimeout: () {
    stdout.writeln('no pushall within 10s');
  });
  client.disconnect();
}
