import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/builtin_camera_options.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

PrinterProfile _printer({
  required String id,
  PrinterMode mode = PrinterMode.lan,
  String ip = '192.168.100.110',
  String code = '12345678',
}) =>
    PrinterProfile(
      id: id,
      name: '打印机 $id',
      mode: mode,
      serial: '03919D4A0803769',
      ip: ip,
      accessCode: code,
    );

CameraProfile _builtin(String printerId) => CameraProfile(
      id: 'bambu_x',
      name: '机内摄像头',
      sourceType: CameraSourceType.bambu,
      printerIds: [printerId],
    );

void main() {
  group('builtinCameraOptions', () {
    test('局域网 + IP + 访问码才算能取流', () {
      final options = builtinCameraOptions(
        [
          _printer(id: 'ok'),
          _printer(id: 'cloud', mode: PrinterMode.cloud),
          _printer(id: 'noip', ip: ''),
          _printer(id: 'nocode', code: ''),
        ],
        const [],
      );
      expect([for (final o in options) o.usable],
          [true, false, false, false]);
      expect(options[1].blockedReason, contains('云模式'));
      expect(options[2].blockedReason, contains('IP'));
      expect(options[3].blockedReason, contains('访问码'));
    });

    test('只有绑到这台打印机的机内摄像头才算「已经加过」', () {
      final options = builtinCameraOptions(
        [_printer(id: 'p1'), _printer(id: 'p2')],
        [_builtin('p1')],
      );
      expect(options[0].hasBuiltinCamera, isTrue);
      expect(options[1].hasBuiltinCamera, isFalse);
    });

    test('默认选中第一台能取流且还没加过的打印机', () {
      final options = builtinCameraOptions(
        [
          _printer(id: 'cloud', mode: PrinterMode.cloud),
          _printer(id: 'has'),
          _printer(id: 'free'),
        ],
        [_builtin('has')],
      );
      expect(defaultBuiltinCameraOption(options)?.printer.id, 'free');
    });

    test('全都加过了就返回 null(UI 显示「已加过」而不是空下拉)', () {
      final options = builtinCameraOptions(
        [_printer(id: 'p1')],
        [_builtin('p1')],
      );
      expect(defaultBuiltinCameraOption(options), isNull);
    });
  });
}
