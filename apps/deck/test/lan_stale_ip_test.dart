import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/lan_printer_probe.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// DHCP 换 IP 自愈 (2026-11-19): 有 IP 但访问码认证不过的, 视为 IP 过期。
void main() {
  PrinterProfile p(String id,
          {PrinterMode mode = PrinterMode.lan,
          String ip = '',
          String serial = 'SN',
          String code = 'code1234'}) =>
      PrinterProfile(
          id: id, name: id, mode: mode, serial: serial, ip: ip, accessCode: code);

  test('unreachable IP 判为过期', () async {
    // 127.0.0.1 肯定没有 8883: 连接立即被拒, 不能当成"配对成功"。
    final stale = await staleLanIpSerials([p('a', ip: '127.0.0.1')]);
    expect(stale, {'SN'});
  });

  test('缺 IP / 云模式 / 无访问码 都不参与探测', () async {
    final stale = await staleLanIpSerials([
      p('noip'),
      p('cloud', mode: PrinterMode.cloud, ip: '127.0.0.1'),
      p('nocode', ip: '127.0.0.1', code: ''),
    ]);
    expect(stale, isEmpty);
  });
}
