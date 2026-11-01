import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/lan_printer_probe.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PrinterProfile cloud(String id, {String serial = '', String code = ''}) =>
      PrinterProfile(
        id: id,
        name: id,
        mode: PrinterMode.cloud,
        serial: serial,
        accessCode: code,
      );

  group('needsLanIp', () {
    test('serial+code and no ip qualifies (cloud or lan alike)', () {
      expect(needsLanIp(cloud('a', serial: 'SN', code: 'code')), isTrue);
      expect(
          needsLanIp(cloud('b', serial: 'SN', code: 'code')
              .copyWith(mode: PrinterMode.lan)),
          isTrue);
    });

    test('missing code / serial or having ip does not', () {
      expect(needsLanIp(cloud('a', serial: 'SN')), isFalse); // 无访问码
      expect(needsLanIp(cloud('b', code: 'code')), isFalse); // 无序列号
      expect(
          needsLanIp(
              cloud('c', serial: 'SN', code: 'code').copyWith(ip: '1.2.3.4')),
          isFalse); // 已有 IP
    });
  });

  group('applyLanIps', () {
    test('fills ip and upgrades cloud mode to lan', () {
      final a = cloud('a', serial: 'SN-A', code: 'c1');
      final b = cloud('b', serial: 'SN-B', code: 'c2');
      final next = applyLanIps([a, b], {'SN-A': '192.168.100.110'})!;
      expect(next, hasLength(2));
      expect(next[0].ip, '192.168.100.110');
      expect(next[0].mode, PrinterMode.lan);
      // 未命中的保持原样
      expect(next[1].ip, '');
      expect(next[1].mode, PrinterMode.cloud);
    });

    test('untouched list returns null (caller skips persisting)', () {
      final a = cloud('a', serial: 'SN-A', code: 'c1');
      expect(applyLanIps([a], {}), isNull); // 空 hit
      expect(
          applyLanIps(
              [a.copyWith(ip: '1.2.3.4')], {'SN-A': '1.2.3.4'}), // ip 已同
          isNull);
    });

    test('does not mutate entries that were not hit', () {
      final a = cloud('a', serial: 'SN-A', code: 'c1');
      final b = cloud('b', serial: 'SN-B', code: 'c2');
      final next = applyLanIps([a, b], {'SN-B': '2.2.2.2'})!;
      expect(a.ip, ''); // 原 profile 不被改
      expect(next[0], same(a));
    });
  });
}
