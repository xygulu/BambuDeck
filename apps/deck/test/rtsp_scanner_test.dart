import 'dart:io';

import 'package:deck/data/rtsp_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Binds a fake RTSP server on 127.0.0.1 and answers every incoming
/// request with [response] (RTSP servers keep the connection open, so
/// does the fake).
Future<ServerSocket> _fakeRtsp(String response) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((sock) {
    sock.listen((_) => sock.write(response));
  });
  return server;
}

/// Scan the loopback /24 at the fake servers' port, with test-sized
/// timeouts.
Future<List<RtspHit>> _scan(
  int port,
  List<String> paths, {
  void Function(int done, int total)? onProgress,
}) {
  return scanRtspCameras(
    subnetPrefix: '127.0.0',
    ports: [port],
    paths: paths,
    onProgress: onProgress,
    concurrency: 32,
    connectTimeout: const Duration(milliseconds: 250),
    responseTimeout: const Duration(milliseconds: 400),
  );
}

void main() {
  test('phase-1 sweep + 200 DESCRIBE finds the endpoint and vendor',
      () async {
    final server = await _fakeRtsp(
      'RTSP/1.0 200 OK\r\n'
      'CSeq: 1\r\n'
      'Server: Hikvision-Webs/3.1.3\r\n'
      'Content-Type: application/sdp\r\n'
      'Content-Length: 0\r\n'
      '\r\n',
    );
    addTearDown(server.close);

    final progress = <int>[];
    final hits = await _scan(
      server.port,
      const ['/stream1'],
      onProgress: (d, t) => progress.add(d),
    );

    expect(hits, hasLength(1));
    expect(hits.first.url, 'rtsp://127.0.0.1:${server.port}/stream1');
    expect(hits.first.vendor, '海康威视');
    expect(hits.first.needsAuth, isFalse);
    expect(progress.last, 254); // 254 hosts x 1 port, all reported
  });

  test('401 counts as a hit flagged needsAuth', () async {
    final server = await _fakeRtsp(
      'RTSP/1.0 401 Unauthorized\r\n'
      'CSeq: 1\r\n'
      'Server: Dahua Http Service V1.0\r\n'
      '\r\n',
    );
    addTearDown(server.close);

    final hits = await _scan(server.port,
        const ['/cam/realmonitor?channel=1&subtype=0']);

    expect(hits, hasLength(1));
    expect(hits.first.needsAuth, isTrue);
    expect(hits.first.vendor, '大华');
  });

  test('open port that never answers RTSP yields no hit', () async {
    // Bare TCP server: accepts, stays mute -> probe times out.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((sock) {});
    addTearDown(server.close);

    final hits = await _scan(server.port, const ['/stream1']);

    expect(hits, isEmpty);
  });

  test('server header without a known vendor gives null vendor', () {
    const hit = RtspHit(
        ip: '10.0.0.9', port: 554, path: '/1', server: 'AppServer/1.0');
    expect(hit.vendor, isNull);
    expect(hit.url, 'rtsp://10.0.0.9:554/1');
  });
}
