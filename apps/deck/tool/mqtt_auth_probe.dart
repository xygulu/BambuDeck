// 单次认证探针: 只对一台打印机的 IP 发一次 CONNECT, 排除连发错密码触发的
// 固件防爆破干扰。凭据从 ~/.bambudeck/hub.json 读, 不打印访问码。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:deck/data/lan_printer_probe.dart';

Future<void> main(List<String> args) async {
  final name = args.isNotEmpty ? args[0] : '宇树';
  final cfg = jsonDecode(
      File('${Platform.environment['HOME']}/.bambudeck/hub.json').readAsStringSync());
  final p = (cfg['printers'] as List)
      .firstWhere((e) => e['name'] == name, orElse: () => null);
  if (p == null) {
    print('no printer named $name');
    return;
  }
  print('${p['name']} serial=${p['serial']} ip=${p['ip']} codeLen=${(p['accessCode'] as String).length}');
  final watch = Stopwatch()..start();
  final ok = await _auth(p['ip'], p['accessCode']);
  print('auth ok=$ok  (${watch.elapsedMilliseconds}ms)');
}

Future<bool> _auth(String ip, String code) async {
  SecureSocket? sock;
  try {
    sock = await SecureSocket.connect(ip, 8883,
        onBadCertificate: (_) => true, timeout: const Duration(seconds: 3));
    sock.add(encodeMqttConnect(
        clientId: 'bmbdeck${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
        password: code));
    return await readMqttConnack(sock, const Duration(seconds: 3));
  } catch (e) {
    print('err: $e');
    return false;
  } finally {
    sock?.destroy();
  }
}
