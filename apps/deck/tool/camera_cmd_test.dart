// Throwaway diagnostics: send an ipcam MQTT command to a printer, watch
// the report's ipcam object and exit. Never prints the access code.
// Usage: dart run tool/ipcam_toggle.dart <serial> <ip> '{"mode_bits":2}'
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main(List<String> args) async {
  final serial = args[0];
  final ip = args[1];
  final cmd = jsonDecode(args[2]) as Map<String, dynamic>;

  final confPath =
      '${Platform.environment['HOME']}/Library/Application Support/'
      'BambuStudio/BambuStudio.conf';
  final conf =
      jsonDecode(File(confPath).readAsStringSync()) as Map<String, dynamic>;
  final code = (conf['access_code'] as Map<String, dynamic>)[serial] as String;

  final client = MqttServerClient.withPort(
      ip, 'bambudeck_ipcam_${DateTime.now().millisecondsSinceEpoch % 0xFFFF}',
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

  
  client.updates!.listen((messages) {
    for (final m in messages) {
      final pub = m.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
          pub.payload.message);
      final doc = jsonDecode(text) as Map<String, dynamic>;
      final print_ = doc['print'];
      if (print_ is! Map<String, dynamic>) continue;
      final ipcam = print_['ipcam'];
      final cmdAck = print_['command'];
      if (cmdAck != null || ipcam != null) {
        stdout.writeln(
            'frame: command=$cmdAck ipcam=${ipcam == null ? "-" : jsonEncode(ipcam)}');
      }
    }
  });

  client.subscribe('device/$serial/report', MqttQos.atLeastOnce);

  void publish(Map<String, dynamic> payload) {
    stdout.writeln('>> sending ${jsonEncode(payload)}');
    final info = MqttClientPayloadBuilder()
      ..addString(jsonEncode(payload));
    client.publishMessage(
        'device/$serial/request', MqttQos.atLeastOnce, info.payload!);
  }

  cmd['sequence_id'] = DateTime.now().millisecondsSinceEpoch % 100000;
  publish({'camera': cmd});

  await Future<void>.delayed(const Duration(seconds: 3));
  publish({
    'pushing': {'command': 'pushall'},
  });

  await Future<void>.delayed(const Duration(seconds: 9));
  stdout.writeln('done');
  client.disconnect();
}
