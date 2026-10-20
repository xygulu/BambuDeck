import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/bambu_mjpeg.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _frame(int n, {bool jpeg = true}) {
  final b = BytesBuilder();
  final head = ByteData(16)
    ..setUint32(0, n, Endian.little)
    ..setUint32(4, 0, Endian.little)
    ..setUint32(8, 1, Endian.little)
    ..setUint32(12, 0, Endian.little);
  b.add(head.buffer.asUint8List());
  if (jpeg) {
    b.add([0xFF, 0xD8, ...List.filled(n - 4, 0x11), 0xFF, 0xD9]);
  } else {
    b.add(List.filled(n, 0x00));
  }
  return b.takeBytes();
}

void _expectFrame(Uint8List f, int size) {
  expect(f.length, size);
  expect(f[0], 0xFF);
  expect(f[1], 0xD8);
  expect(f[f.length - 2], 0xFF);
  expect(f[f.length - 1], 0xD9);
}

void main() {
  test('auth packet: 80 bytes, LE header, NUL-padded credentials', () {
    final p = buildMjpegAuthPacket('bblp', 'ABC12345');
    expect(p.length, 80);
    final bd = ByteData.sublistView(p);
    expect(bd.getUint32(0, Endian.little), 0x40);
    expect(bd.getUint32(4, Endian.little), 0x3000);
    expect(bd.getUint32(8, Endian.little), 0);
    expect(bd.getUint32(12, Endian.little), 0);
    expect(p.sublist(16, 20), 'bblp'.codeUnits);
    expect(p[24], 0); // username NUL padding
    expect(p.sublist(48, 56), 'ABC12345'.codeUnits);
    expect(p[79], 0); // password NUL padding
  });

  test('bmjpeg url parse keeps credentials and port', () {
    final a = parseBambuMjpegUrl('bmjpeg://bblp:secret@192.168.100.110');
    expect(a!.host, '192.168.100.110');
    expect(a.port, 6000);
    expect(a.username, 'bblp');
    expect(a.password, 'secret');
    final b = parseBambuMjpegUrl('bmjpeg://192.168.1.5:7100');
    expect(b!.host, '192.168.1.5');
    expect(b.port, 7100);
    expect(b.username, 'bblp');
    expect(b.password, '');
  });

  test('camera scheme by model: A1 family mjpeg, X1/P1S/H2 rtsps', () {
    expect(cameraSchemeForModel('A1'), BambuCameraScheme.mjpeg);
    expect(cameraSchemeForModel('A1 mini'), BambuCameraScheme.mjpeg);
    expect(cameraSchemeForModel('P1P'), BambuCameraScheme.mjpeg);
    expect(cameraSchemeForModel(''), BambuCameraScheme.mjpeg); // unknown
    expect(cameraSchemeForModel('P1S'), BambuCameraScheme.rtsps);
    expect(cameraSchemeForModel('X1C'), BambuCameraScheme.rtsps);
    expect(cameraSchemeForModel('P2S'), BambuCameraScheme.rtsps);
    expect(cameraSchemeForModel('H2D'), BambuCameraScheme.rtsps);
  });

  test('serial prefix guesses the model', () {
    expect(guessModelFromSerial('03919D4A0803769'), 'A1');
    expect(guessModelFromSerial('00M88A2C3D45678'), 'X1C');
    expect(guessModelFromSerial('009P12345678901'), 'P1S');
    expect(guessModelFromSerial('ZZZ'), isNull);
  });

  test('bambu camera resolves per linked printer model', () {
    PrinterProfile lan(String model) => PrinterProfile(
          id: 'p',
          name: 'A1',
          mode: PrinterMode.lan,
          serial: 'SN',
          ip: '192.168.100.110',
          accessCode: 'secret',
          model: model,
        );
    final cam = CameraProfile(
        id: 'c', name: '机内', sourceType: CameraSourceType.bambu);

    // A1 family: MJPEG over TLS :6000.
    expect(cam.resolveUrl(lan('A1')),
        'bmjpeg://bblp:secret@192.168.100.110');
    // Unknown model defaults to the MJPEG family.
    expect(cam.resolveUrl(lan('')), 'bmjpeg://bblp:secret@192.168.100.110');
    // P1S/X1 family: RTSPS on :322.
    expect(cam.resolveUrl(lan('P1S')),
        'rtsps://bblp:secret@192.168.100.110:322/streaming/live/1');
    // Cloud-linked or ip-less printers resolve null.
    expect(
        cam.resolveUrl(PrinterProfile(
          id: 'p2',
          name: '云',
          mode: PrinterMode.cloud,
          serial: 'SN',
        )),
        isNull);
  });

  test('legacy rtsp://bblp url pointing at the linked printer heals', () {
    final linked = PrinterProfile(
      id: 'p',
      name: 'A1',
      mode: PrinterMode.lan,
      serial: 'SN',
      ip: '192.168.100.110',
      accessCode: 'secret',
      model: 'A1',
    );
    // M2 stored built-in cameras with this exact shape.
    final legacy = CameraProfile(
      id: 'c',
      name: '机内',
      sourceType: CameraSourceType.rtsp,
      url: 'rtsp://bblp:stale@192.168.100.110/stream_live',
      printerId: 'p',
    );
    expect(legacy.resolveUrl(linked), 'bmjpeg://bblp:secret@192.168.100.110');
    // The same shape against a different host stays untouched.
    final other = CameraProfile(
      id: 'c2',
      name: '外部',
      sourceType: CameraSourceType.rtsp,
      url: 'rtsp://admin:x@192.168.100.102:554/h264/ch1/main/av_stream',
    );
    expect(other.resolveUrl(linked),
        'rtsp://admin:x@192.168.100.102:554/h264/ch1/main/av_stream');
  });

  test('framer: two frames in one chunk both parse (header reset bug)', () {
    final framer = MjpegFramer();
    final frames = framer.add([..._frame(100), ..._frame(120)]);
    expect(frames.length, 2);
    _expectFrame(frames[0], 100);
    _expectFrame(frames[1], 120);
  });

  test('framer: frames split at every byte boundary still parse', () {
    final wire = [..._frame(50), ..._frame(70), ..._frame(60)];
    for (var cut = 1; cut < wire.length - 1; cut += 7) {
      final framer = MjpegFramer();
      final frames = [
        ...framer.add(wire.sublist(0, cut)),
        ...framer.add(wire.sublist(cut)),
      ];
      expect(frames.length, 3, reason: 'cut at $cut');
      _expectFrame(frames[0], 50);
      _expectFrame(frames[1], 70);
      _expectFrame(frames[2], 60);
    }
  });

  test('framer: non-JPEG payloads are dropped, framing survives', () {
    final framer = MjpegFramer();
    final frames = framer.add([..._frame(40, jpeg: false), ..._frame(80)]);
    expect(frames.length, 1);
    _expectFrame(frames[0], 80);
  });

  test('framer: bogus size does not crash or emit', () {
    final framer = MjpegFramer();
    final bogus = Uint8List(16)
      ..buffer.asByteData().setUint32(0, 5 << 20, Endian.little);
    expect(framer.add(bogus), isEmpty);
    expect(framer.add([..._frame(30)]).length, 1);
  });
}
