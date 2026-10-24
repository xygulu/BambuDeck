import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/hub_ptz.dart';
import 'package:deck/data/hub_server.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/ptz_client.dart';
import 'package:deck/data/rtsp_quality.dart';
import 'package:flutter_test/flutter_test.dart';

/// Test double for [PtzClient]: records the pan/tilt the web pad asked for.
class _FakePtz implements PtzClient {
  final moves = <(double, double)>[];
  int stops = 0;
  bool reachable = true;

  @override
  bool get available => reachable;

  @override
  Future<bool> probe() async => reachable;

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    moves.add((pan, tilt));
  }

  @override
  Future<void> stop() async => stops++;

  @override
  void dispose() {}
}

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

    PrinterProfile printer({String id = 'p1', bool autoPlateSwap = false}) =>
        PrinterProfile(
          id: id,
          name: '车间 A1',
          mode: PrinterMode.lan,
          serial: 'S',
          ip: '1.2.3.4',
          autoPlateSwap: autoPlateSwap,
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

    // 带账号密码 + 主/子码流标记: 云台和码流切换都要求这一种地址。
    CameraProfile ptzCamera(
            {bool flipH = false,
            int rotationDeg = 0,
            String ptzCalibration = ''}) =>
        CameraProfile(
          id: 'c1',
          name: '工位相机',
          sourceType: CameraSourceType.rtsp,
          url: 'rtsp://admin:pass@10.0.0.5:554/h264/ch1/main/av_stream',
          printerIds: const ['p1'],
          flipH: flipH,
          rotationDeg: rotationDeg,
          ptzCalibration: ptzCalibration,
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

    Future<HttpClientResponse> post(String path, Map<String, dynamic> body,
        {String token = 'sekrit'}) async {
      final client = HttpClient();
      final req = await client.postUrl(Uri.parse(
          'http://127.0.0.1:${bound.port}$path?token=$token'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      addTearDown(client.close);
      return res;
    }

    test('POST /api/control runs the handler for the named printer', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      final calls = <String>[];
      hub.controlHandler = (profile, command) async {
        calls.add('${profile.id}:$command');
        return {'ok': true, 'printer': profile.name, 'command': command};
      };
      await hub.start();

      final res =
          await post('/api/control', {'printer': 'p1', 'command': 'pause'});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['ok'], isTrue);
      expect(body['printer'], '车间 A1');
      expect(calls, ['p1:pause']);
    });

    test('POST /api/control validates token, printer and command', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      hub.controlHandler = (_, __) async => {'ok': true};
      await hub.start();

      final badToken = await post('/api/control',
          {'printer': 'p1', 'command': 'pause'}, token: 'wrong');
      expect(badToken.statusCode, 401);

      final noPrinter =
          await post('/api/control', {'printer': 'nope', 'command': 'pause'});
      expect(noPrinter.statusCode, 404);

      final badCmd =
          await post('/api/control', {'printer': 'p1', 'command': 'launch'});
      expect(badCmd.statusCode, 400);
    });

    test('GET /api/control is rejected', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      hub.controlHandler = (_, __) async => {'ok': true};
      await hub.start();
      final res = await get('/api/control');
      expect(res.statusCode, 405);
    });

    test('a second control request while one runs gets 409', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      final gate = Completer<void>();
      hub.controlHandler = (_, __) async {
        await gate.future;
        return {'ok': true};
      };
      await hub.start();

      final first = post('/api/control', {'printer': 'p1', 'command': 'stop'});
      // Give the first request time to enter the handler and take the lock.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final second =
          await post('/api/control', {'printer': 'p1', 'command': 'pause'});
      expect(second.statusCode, 409);
      gate.complete();
      expect((await first).statusCode, 200);
    });

    test('POST /api/plate-swap runs the plate-swap handler', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      var calls = 0;
      hub.plateSwapHandler = (profile) async {
        calls++;
        return {'ok': true, 'printer': profile.name, 'task': 'T1'};
      };
      await hub.start();

      final res = await post('/api/plate-swap', {'printer': 'p1'});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['task'], 'T1');
      expect(calls, 1);
    });

    test('/api/state only flags plateSwap for printers set up for it',
        () async {
      hub.settings = hubSettings();
      hub.printers = [
        printer(),
        printer(id: 'p2', autoPlateSwap: true),
      ];
      await hub.start();

      final res = await get('/api/state');
      final body =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      final list = body['printers'] as List;
      expect(list[0]['plateSwap'], isFalse);
      expect(list[1]['plateSwap'], isTrue,
          reason: '网页的换盘按钮要和 App 一样看 autoPlateSwap');
    });

    test('POST /api/set forwards speed and light to the handler', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      int? gotSpeed;
      bool? gotLight;
      hub.setHandler = (profile, {speed, light}) async {
        gotSpeed = speed;
        gotLight = light;
        return {'ok': true, 'printer': profile.name, 'speed': speed,
            'light': light};
      };
      await hub.start();

      final res = await post('/api/set', {'printer': 'p1', 'speed': 3});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['ok'], isTrue);
      expect(body['speed'], 3);
      expect(gotSpeed, 3);
      expect(gotLight, isNull);

      // light accepts true/false as well as on/off.
      final res2 =
          await post('/api/set', {'printer': 'p1', 'light': 'off'});
      expect(res2.statusCode, 200);
      expect(gotLight, isFalse);
    });

    test('POST /api/set rejects a bad body, speed and unknown printer',
        () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      hub.setHandler = (_, {speed, light}) async => {'ok': true};
      await hub.start();

      expect((await post('/api/set', {'printer': 'p1'})).statusCode, 400);
      expect(
          (await post('/api/set', {'printer': 'p1', 'speed': 9})).statusCode,
          400);
      expect((await post('/api/set', {'printer': 'nope', 'speed': 2}))
          .statusCode, 404);
      expect((await get('/api/set')).statusCode, 405,
          reason: 'GET must not change settings');
    });

    test('POST /api/set answers 503 before the handler is wired', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      await hub.start();
      expect((await post('/api/set', {'printer': 'p1', 'speed': 2}))
          .statusCode, 503);
    });

    test('/api/state carries conn and the camera look controls', () async {
      hub.settings = hubSettings();
      hub.printers = [printer()];
      hub.cameras = [ptzCamera(flipH: true, rotationDeg: 90)];
      hub.connStatusOf = (_) => 'reconnecting';
      await hub.start();

      final res = await get('/api/state');
      final body =
          jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect((body['printers'] as List).single['conn'], 'reconnecting');
      final cam = (body['cameras'] as List).single as Map;
      expect(cam['flipH'], isTrue);
      expect(cam['rotation'], 90);
      expect(cam['rtsp'], isTrue);
      expect(cam['canQuality'], isTrue);
      expect(cam['quality'], 'main');
      expect(cam['ptz'], isTrue);
      expect(cam['audio'], isTrue);
    });

    test('POST /api/camera forwards orientation, quality and mute', () async {
      hub.settings = hubSettings();
      hub.cameras = [ptzCamera()];
      final calls = <String>[];
      hub.cameraHandler = (id,
          {bool? flipH, int? rotationDeg, RtspQuality? quality}) async {
        calls.add('$id flip=$flipH rot=$rotationDeg q=${quality?.name}');
        return {'ok': true, 'camera': id};
      };
      hub.muteHandler = (muted) async => calls.add('mute=$muted');
      await hub.start();

      final flip = await post('/api/camera', {'camera': 'c1', 'flipH': true});
      expect(flip.statusCode, 200);
      final rot =
          await post('/api/camera', {'camera': 'c1', 'rotation': 270});
      expect(rot.statusCode, 200);
      final q = await post('/api/camera', {'camera': 'c1', 'quality': 'sub'});
      expect(q.statusCode, 200);
      final mute =
          await post('/api/camera', {'camera': 'c1', 'muted': true});
      expect(mute.statusCode, 200);

      expect(calls, [
        'c1 flip=true rot=null q=null',
        'c1 flip=null rot=270 q=null',
        'c1 flip=null rot=null q=sub',
        'mute=true',
      ]);
    });

    test('POST /api/camera rejects bad input', () async {
      hub.settings = hubSettings();
      hub.cameras = [ptzCamera()];
      hub.cameraHandler = (_, {flipH, rotationDeg, quality}) async =>
          {'ok': true};
      hub.muteHandler = (_) async {};
      await hub.start();

      expect(
          (await post('/api/camera', {'camera': 'c1', 'rotation': 45}))
              .statusCode,
          400);
      expect((await post('/api/camera', {'camera': 'c1'})).statusCode, 400);
      expect(
          (await post('/api/camera', {'camera': 'nope', 'flipH': true}))
              .statusCode,
          404);
      expect((await get('/api/camera')).statusCode, 405);
    });

    test('POST /api/camera answers 503 before the handlers are wired',
        () async {
      hub.settings = hubSettings();
      hub.cameras = [ptzCamera()];
      await hub.start();
      expect(
          (await post('/api/camera', {'camera': 'c1', 'muted': true}))
              .statusCode,
          503);
      expect(
          (await post('/api/camera', {'camera': 'c1', 'flipH': true}))
              .statusCode,
          503);
    });

    test('POST /api/ptz refuses a camera without credentials', () async {
      hub.settings = hubSettings();
      hub.cameras = [camera()]; // rtsp:// but no user:pass
      await hub.start();
      final res = await post('/api/ptz', {'camera': 'c1', 'action': 'up'});
      expect(res.statusCode, 400);
    });

    test('POST /api/ptz maps a held key through the flip', () async {
      final fake = _FakePtz();
      hub.ptz = HubPtz(clientFactory: (_) => fake);
      hub.settings = hubSettings();
      // 画面翻转后, 屏幕上的「向右」要变成机身的「向左」。
      hub.cameras = [ptzCamera(flipH: true)];
      await hub.start();

      final res = await post('/api/ptz',
          {'camera': 'c1', 'action': 'right', 'speed': 0.5});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['ok'], isTrue);
      expect(fake.moves, hasLength(1));
      expect(fake.moves.single.$1, -0.5);
      expect(fake.moves.single.$2, 0);

      final stop = await post('/api/ptz', {'camera': 'c1', 'action': 'stop'});
      expect(stop.statusCode, 200);
      expect(fake.stops, 1);
    });

    test('POST /api/ptz honours a measured key map', () async {
      final fake = _FakePtz();
      hub.ptz = HubPtz(clientFactory: (_) => fake);
      hub.settings = hubSettings();
      // 实测: 这台的「上」键让画面往左走, 所以按「上」要发左(pure pan-left).
      hub.cameras = [ptzCamera(ptzCalibration: 'RLUD')];
      await hub.start();

      final res =
          await post('/api/ptz', {'camera': 'c1', 'action': 'up', 'speed': 0.5});
      expect(res.statusCode, 200);
      expect(fake.moves.single.$1, -0.5);
      expect(fake.moves.single.$2, 0);
    });

    test('POST /api/ptz reports an unreachable camera as unavailable', () async {
      final fake = _FakePtz()..reachable = false;
      hub.ptz = HubPtz(clientFactory: (_) => fake);
      hub.settings = hubSettings();
      hub.cameras = [ptzCamera()];
      await hub.start();

      final res = await post('/api/ptz', {'camera': 'c1', 'action': 'up'});
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
      expect(body['ok'], isFalse);
      expect(body['available'], isFalse);
      expect(fake.moves, isEmpty);
    });
  });
}
