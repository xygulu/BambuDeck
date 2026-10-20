import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/hub_server.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JpegSplitter', () {
    Uint8List jpeg(int seed) => Uint8List.fromList(
        [0xFF, 0xD8, seed, 0x11, 0x22, 0x33, 0xFF, 0xD9]);

    test('splits concatenated frames', () {
      final s = JpegSplitter();
      final frames = s.add([...jpeg(1), ...jpeg(2), ...jpeg(3)]);
      expect(frames.length, 3);
      expect(frames[0][2], 1);
      expect(frames[2][2], 3);
    });

    test('reassembles frames across chunk boundaries', () {
      final s = JpegSplitter();
      final whole = [...jpeg(7), ...jpeg(9)];
      final out = <Uint8List>[];
      // Feed one byte at a time - worst-case fragmentation.
      for (final b in whole) {
        out.addAll(s.add([b]));
      }
      expect(out.length, 2);
      expect(out[1][2], 9);
    });

    test('drops garbage before SOI and oversize runaway', () {
      final s = JpegSplitter();
      expect(s.add([1, 2, 3, ...jpeg(4)]).length, 1);
      // A chunk with no markers at all is discarded, not buffered forever.
      expect(s.add([9, 9, 9, 9]), isEmpty);
      expect(s.add(jpeg(5)).length, 1);
    });
  });

  group('HubServer', () {
    late HubServer hub;
    late HttpServer bound;

    setUp(() async {
      hub = HubServer(
        pageHtml: '<html>deck-hub-page</html>',
        bind: (_, __) async {
          final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          bound = srv;
          return srv;
        },
        log: (_) {},
      );
    });

    tearDown(() => hub.stop());

    AppSettings hubSettings() =>
        const AppSettings(hubPort: 0, hubToken: 'sekrit');

    PrinterProfile printer() => PrinterProfile(
          id: 'p1',
          name: '车间 A1',
          mode: PrinterMode.lan,
          serial: 'S',
          ip: '1.2.3.4',
        );

    BambuState state() => BambuState(
          updatedAt: DateTime.now(),
          gcodeState: GcodeState.running,
          progress: 42,
          remainingMinutes: 75,
          layerNum: 12,
          totalLayers: 300,
          nozzleTemp: 220,
          nozzleTarget: 220,
          bedTemp: 55,
          bedTarget: 55,
          subtaskName: '支架.gcode.3mf',
        );

    CameraProfile camera({bool enabled = true}) => CameraProfile(
          id: 'c1',
          name: '工位相机',
          sourceType: CameraSourceType.rtsp,
          url: 'rtsp://10.0.0.5:554/stream',
          printerIds: const ['p1'],
          enabled: enabled,
        );

    Future<HttpClientResponse> get(String path,
        {bool auth = true}) async {
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${bound.port}$path'
              '${auth ? '?token=sekrit' : '?token=wrong'}'));
      final res = await req.close();
      addTearDown(client.close);
      return res;
    }

    test('page is served without a token, api rejects a wrong one',
        () async {
      hub.settings = hubSettings();
      await hub.start();
      final page = await get('/');
      expect(page.statusCode, 200);
      expect(await page.transform(utf8.decoder).join(),
          contains('deck-hub-page'));

      final bad = await get('/api/state', auth: false);
      expect(bad.statusCode, 401);
    });

    test('/api/state carries printers, live state and camera streams',
        () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      hub.cameras = [camera()];
      hub.observeState(printer(), state());
      await hub.start();

      final res = await get('/api/state');
      expect(res.statusCode, 200);
      final body =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      final printers = (body['printers'] as List).asMap();
      expect(printers[0]['name'], '车间 A1');
      final st = printers[0]['state'] as Map;
      expect(st['gcode'], 'RUNNING');
      expect(st['progress'], 42);
      expect(st['remainingMinutes'], 75);
      expect(st['layerNum'], 12);
      expect(st['subtaskName'], '支架.gcode.3mf');
      final cams = (body['cameras'] as List).asMap();
      expect(cams[0]['stream'], '/stream/c1?token=sekrit');
    });

    test('disabled cameras expose no stream url', () async {
      hub.settings = hubSettings();
      hub.cameras = [camera(enabled: false)];
      await hub.start();
      final res = await get('/api/state');
      final body =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect((body['cameras'] as List).single.containsKey('stream'), isFalse);
    });

    test('websocket pushes snapshots on state events', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      await hub.start();

      final ws = await WebSocket.connect(
          'ws://127.0.0.1:${bound.port}/ws?token=sekrit');
      addTearDown(ws.close);
      // One listen for the whole socket - dart:io websockets are not
      // re-listenable.
      final messages = <Map<String, dynamic>>[];
      final hello = Completer<void>();
      ws.listen((data) {
        messages.add(jsonDecode(data as String) as Map<String, dynamic>);
        if (!hello.isCompleted) hello.complete();
      });
      await hello.future;
      expect((messages.first['printers'] as List).single
          .containsKey('state'), isFalse);

      hub.observeState(printer(), state());
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (messages.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(messages.length, greaterThanOrEqualTo(2),
          reason: 'state event must be pushed over ws');
      final st = (messages[1]['printers'] as List).first['state'] as Map;
      expect(st['progress'], 42);
    });

    test('stream endpoint relays mjpeg frames from the source', () async {
      hub.settings = hubSettings();
      hub.cameras = [camera()];
      final frames = StreamController<Uint8List>.broadcast();
      hub.relayOverride = (_) => frames.stream;
      await hub.start();

      // Own the client so we can force-close the socket - the server side
      // of a streaming response only notices a gone viewer at the socket.
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(
          'http://127.0.0.1:${bound.port}/stream/c1?token=sekrit'));
      final res = await req.close();
      expect(res.headers.contentType?.mimeType,
          'multipart/x-mixed-replace');

      final frame = Uint8List.fromList([0xFF, 0xD8, 0xAA, 0xFF, 0xD9]);
      final collected = <int>[];
      final sub = res.listen(collected.addAll);
      frames.add(frame);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      client.close(force: true); // void - tears the socket down now
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel().timeout(const Duration(seconds: 5));
      final text = latin1.decode(collected);
      expect(text, contains('--bambudeck'));
      expect(text, contains('Content-Length: ${frame.length}'));
      expect(text, contains(latin1.decode(frame)));
    });

    test('stream for an unknown camera is 404', () async {
      hub.settings = hubSettings();
      await hub.start();
      final res = await get('/stream/nope');
      expect(res.statusCode, 404);
    });
  });
}
