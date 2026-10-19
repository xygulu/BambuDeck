import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/bambu_mjpeg.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
