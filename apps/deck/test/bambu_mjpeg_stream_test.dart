import 'dart:io';
import 'dart:typed_data';

import 'package:deck/data/bambu_mjpeg.dart';
import 'package:flutter_test/flutter_test.dart';

/// A1 机内摄像头: 半开的 TCP 连接不会报错, 只能靠空闲超时自己断开重连。
void main() {
  test('idle connection is dropped and reconnected', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    server.listen((s) {
      accepted.add(s);
      s.listen((_) {}, onError: (_) {});
      // 收下认证包, 但一帧画面都不发: 打印机半开 / 网络断了。
    });
    final errors = <String>[];
    final stream = BambuMjpegStream(
      host: '127.0.0.1',
      port: server.port,
      username: 'bblp',
      password: 'x',
      idleTimeout: const Duration(milliseconds: 120),
      connect: (h, p) => Socket.connect(h, p),
      onError: errors.add,
    );
    addTearDown(() async {
      stream.dispose();
      for (final s in accepted) {
        s.destroy();
      }
      await server.close();
    });
    stream.start();

    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (accepted.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(accepted.length, greaterThanOrEqualTo(2),
        reason: '半开连接不重连, 画面就会永久定格');
    expect(errors.any((e) => e.contains('没有收到画面数据')), isTrue,
        reason: '日志里要能看出是空闲超时导致的重连');
  });

  test('frames are split out of the wire format', () async {
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((s) {
      s.listen((_) {}, onError: (_) {});
      final head = ByteData(16)..setUint32(0, jpeg.length, Endian.little);
      // 头 + 帧分两次写, 覆盖跨 chunk 的情况。
      s.add(head.buffer.asUint8List());
      s.add(jpeg);
    });
    final frames = <Uint8List>[];
    final stream = BambuMjpegStream(
      host: '127.0.0.1',
      port: server.port,
      username: 'bblp',
      password: 'x',
      connect: (h, p) => Socket.connect(h, p),
      onFrame: frames.add,
    );
    addTearDown(stream.dispose);
    stream.start();

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (frames.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(frames.single, jpeg);
  });
}
