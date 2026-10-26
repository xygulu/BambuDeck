import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/list_sort.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

PrinterProfile _p(String id, String name, PrinterMode mode,
        {int createdAt = 0}) =>
    PrinterProfile(id: id, name: name, mode: mode, serial: id, createdAt: createdAt);

CameraProfile _c(String id, String name, CameraSourceType type,
        {int createdAt = 0}) =>
    CameraProfile(id: id, name: name, sourceType: type, createdAt: createdAt);

void main() {
  group('sortPrinters', () {
    final stored = [
      _p('a', '字树', PrinterMode.lan, createdAt: 30),
      _p('b', '嘉兴', PrinterMode.cloud, createdAt: 10),
      _p('c', '123', PrinterMode.lan, createdAt: 20),
    ];

    test('manual keeps the stored order', () {
      expect(sortPrinters(stored, ListSortMode.manual).map((p) => p.id),
          ['a', 'b', 'c']);
    });

    test('name sorts by name', () {
      expect(sortPrinters(stored, ListSortMode.name).map((p) => p.id),
          ['c', 'b', 'a']); // 123 < 嘉兴 < 字树 (码点序)
    });

    test('type puts LAN first, then by name; addedTime ascending', () {
      expect(sortPrinters(stored, ListSortMode.type).map((p) => p.id),
          ['c', 'a', 'b']);
      expect(sortPrinters(stored, ListSortMode.addedTime).map((p) => p.id),
          ['b', 'c', 'a']);
    });

    test('legacy entries (createdAt 0) come first and keep stored order', () {
      final legacy = [
        _p('x', '乙', PrinterMode.lan),
        _p('y', '甲', PrinterMode.lan),
        _p('z', '丙', PrinterMode.lan, createdAt: 5),
      ];
      expect(sortPrinters(legacy, ListSortMode.addedTime).map((p) => p.id),
          ['x', 'y', 'z']);
    });
  });

  group('sortCameras', () {
    final stored = [
      _c('a', '字树机内', CameraSourceType.bambu, createdAt: 30),
      _c('b', '萤石', CameraSourceType.rtsp, createdAt: 10),
      _c('c', '123机内', CameraSourceType.bambu, createdAt: 20),
    ];

    test('manual keeps stored order; name sorts; type puts built-in first',
        () {
      expect(sortCameras(stored, ListSortMode.manual).map((c) => c.id),
          ['a', 'b', 'c']);
      expect(sortCameras(stored, ListSortMode.name).map((c) => c.id),
          ['c', 'a', 'b']); // 123机内 < 字树机内 < 萤石 (码点序)
      expect(sortCameras(stored, ListSortMode.type).map((c) => c.id),
          ['c', 'a', 'b']);
      expect(sortCameras(stored, ListSortMode.addedTime).map((c) => c.id),
          ['b', 'c', 'a']);
    });
  });
}
