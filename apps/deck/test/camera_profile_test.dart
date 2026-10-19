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
      printerId: 'p1',
    );
    final back = CameraProfile.fromJson(
        jsonDecode(jsonEncode(rtsp.toJson())) as Map<String, dynamic>);
    expect(back.sourceType, CameraSourceType.rtsp);
    expect(back.url, rtsp.url);
    expect(back.printerId, 'p1');
    expect(back.enabled, isTrue);
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
