import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements CameraStore {
  _MemoryStore();
  List<CameraProfile>? _saved;

  @override
  Future<List<CameraProfile>> load() async => _saved ?? const [];

  @override
  Future<void> save(List<CameraProfile> cameras) async => _saved = cameras;
}

void main() {
  test('camera profile JSON roundtrip keeps type and links', () {
    final rtsp = CameraProfile(
      id: 'c1',
      name: '门口',
      sourceType: CameraSourceType.rtsp,
      url: 'rtsp://u:p@10.0.0.3:554/1',
      printerIds: const ['p1', 'p2'],
    );
    final back = CameraProfile.fromJson(
        jsonDecode(jsonEncode(rtsp.toJson())) as Map<String, dynamic>);
    expect(back.sourceType, CameraSourceType.rtsp);
    expect(back.url, rtsp.url);
    expect(back.printerIds, ['p1', 'p2']);
    expect(back.enabled, isTrue);
  });

  test('ezviz serial survives JSON and copyWith, old JSON defaults empty', () {
    final cam = CameraProfile(
      id: 'c1',
      name: '门口',
      sourceType: CameraSourceType.rtsp,
      url: 'rtsp://admin:code@10.0.0.3:554/x',
      ezvizSerial: 'C12345678',
      createdAt: 1700000000000,
    );
    final back = CameraProfile.fromJson(
        jsonDecode(jsonEncode(cam.toJson())) as Map<String, dynamic>);
    expect(back.ezvizSerial, 'C12345678');
    // copyWith fixes the earlier createdAt reset (list sort 2026-10-27).
    final renamed = back.copyWith(name: '新名字');
    expect(renamed.ezvizSerial, 'C12345678');
    expect(renamed.createdAt, 1700000000000);
    // A profile written before this field existed.
    final legacy = CameraProfile.fromJson({
      'id': 'c2',
      'name': 'old',
      'sourceType': 'rtsp',
      'url': 'rtsp://x',
    });
    expect(legacy.ezvizSerial, '');
  });

  test('legacy single printerId migrates into printerIds', () {
    final back = CameraProfile.fromJson({
      'id': 'c9',
      'name': '旧',
      'sourceType': 'rtsp',
      'url': 'rtsp://u:p@10.0.0.9:554/1',
      'printerId': 'p1',
    });
    expect(back.printerIds, ['p1']);
  });

  test('bambu camera resolves from the linked LAN printer model', () {
    final cam = CameraProfile(
        id: 'c2', name: '机内', sourceType: CameraSourceType.bambu);
    final linked = PrinterProfile(
      id: 'p1',
      name: 'A1',
      mode: PrinterMode.lan,
      serial: 'SN',
      ip: '192.168.100.110',
      accessCode: 'secret',
    );
    // Model unknown -> MJPEG family default.
    expect(cam.resolveUrl(linked), 'bmjpeg://bblp:secret@192.168.100.110');
    expect(
      cam.resolveUrl(linked.copyWith(model: 'X1C')),
      'rtsps://bblp:secret@192.168.100.110:322/streaming/live/1',
    );
  });

  test('bambu camera with no usable printer resolves null', () {
    final cam = CameraProfile(
        id: 'c3', name: '机内', sourceType: CameraSourceType.bambu);
    final cloud = PrinterProfile(
      id: 'p2',
      name: '云',
      mode: PrinterMode.cloud,
      serial: 'SN',
    );
    expect(cam.resolveUrl(null), isNull);
    expect(cam.resolveUrl(cloud), isNull); // cloud mode has no LAN rtsp
  });

  test('rtsp camera with empty url resolves null', () {
    final cam = CameraProfile(
        id: 'c4', name: 'x', sourceType: CameraSourceType.rtsp);
    expect(cam.resolveUrl(null), isNull);
  });

  test('ezviz cloud camera: resolveUrl stays null (address lives in the '
      'stream cache), type label and serial roundtrip', () {
    final cam = CameraProfile(
      id: 'c5',
      name: '地下室',
      sourceType: CameraSourceType.ezviz,
      ezvizSerial: 'BA6***17',
      createdAt: 42,
    );
    // The signed FLV/HLS address expires - it is never stored on the
    // profile, so resolveUrl must not pretend there is one.
    expect(cam.resolveUrl(null), isNull);
    expect(cam.sourceType.label, '萤石云端');
    final back = CameraProfile.fromJson(cam.toJson());
    expect(back.sourceType, CameraSourceType.ezviz);
    expect(back.ezvizSerial, 'BA6***17');
    expect(back.createdAt, 42);
    expect(back.copyWith(name: 'x2').ezvizSerial, 'BA6***17');
  });

  test('store roundtrip', () async {
    final store = _MemoryStore();
    expect(await store.load(), isEmpty);
    final cam = CameraProfile(
        id: 'c1', name: 'n', sourceType: CameraSourceType.bambu);
    await store.save([cam]);
    final back = await store.load();
    expect(back.single.sourceType, CameraSourceType.bambu);
  });
}
