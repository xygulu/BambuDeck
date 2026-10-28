// LAN 发现探针: SSDP 组播 + 8883 扫网认证, 打印 serial→IP 配对结果。
// 用法: cd apps/deck && dart run tool/ssdp_probe.dart
// 凭据从 ~/.bambudeck/hub.json 读, 不打印访问码。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/lan_printer_probe.dart';

Future<void> main() async {
  final cfg = jsonDecode(
      File('${Platform.environment['HOME']}/.bambudeck/hub.json').readAsStringSync());

  print('== SSDP 组播 (最多 6 秒)…');
  final hits = await ssdpDiscoverPrinters(wait: const Duration(seconds: 6));
  for (final h in hits) {
    print('  ${h.serial}  ${h.ip}  ${h.name}');
  }
  print('  total: ${hits.length}');

  final missing = [
    for (final p in (cfg['printers'] as List))
      {
        'serial': (p['serial'] as String).trim(),
        'code': (p['accessCode'] as String?) ?? '',
        'name': p['name'],
        'ip': (p['ip'] as String?) ?? '',
      }
  ].where((p) => p['code']!.isNotEmpty).toList();
  if (missing.isEmpty) {
    print('== 8883 扫网: 没有带访问码的打印机, 跳过');
    return;
  }
  final prefixes = <String>{
    for (final p in missing)
      if ((p['ip'] as String).split('.').length == 4)
        (p['ip'] as String).split('.').sublist(0, 3).join('.'),
  }.toList();
  print('== 8883 扫网 $prefixes (每台打印机会真的连一次 MQTT 认证)…');
  final watch = Stopwatch()..start();
  final found = await locateLanPrinters(
    targets: [
      for (final p in missing)
        LanProbeTarget(serial: p['serial']!, accessCode: p['code']!),
    ],
    subnetPrefixes: prefixes,
  );
  watch.stop();
  for (final e in found.entries) {
    final name = missing.firstWhere((p) => p['serial'] == e.key)['name'];
    print('  ${e.key}  →  ${e.value}  ($name)');
  }
  print('  total: ${found.length}/${missing.length}  用时 ${watch.elapsed}');
}
