import 'dart:async';
import 'dart:typed_data';

import 'package:deck/data/camera_grabber.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/hub_server.dart' show CameraRelay;
import 'package:flutter_test/flutter_test.dart';

/// Stands in for [CameraRelay] so the grab path can be driven without
/// opening a real RTSP / bmjpeg connection.
class _FakeRelay extends CameraRelay {
  _FakeRelay(CameraProfile camera, String? Function() resolveUrl)
      : super(camera: camera, resolveUrl: resolveUrl, ffmpegPath: 'ffmpeg');

  final ctl = StreamController<Uint8List>.broadcast();
  int attaches = 0;
  int detaches = 0;

  @override
  Stream<Uint8List> attach() {
    attaches++;
    return ctl.stream;
  }

  @override
  void detach() => detaches++;

  @override
  void dispose() {
    ctl.close();
    super.dispose();
  }
}

void main() {
  late _FakeRelay relay;
  var built = 0;

  CameraGrabber grabber({Duration? timeout}) => CameraGrabber(
        firstFrameTimeout: timeout ?? const Duration(seconds: 2),
        relayFactory: (c, resolve) {
          built++;
          return relay = _FakeRelay(c, resolve);
        },
      );

  CameraProfile cam({
    bool enabled = true,
    CameraSourceType type = CameraSourceType.rtsp,
    List<String> printerIds = const [],
  }) =>
      CameraProfile(
        id: 'c1',
        name: '车间摄像头',
        sourceType: type,
        url: 'rtsp://admin:pw@10.0.0.9:554/Streaming/Channels/101',
        enabled: enabled,
        printerIds: printerIds,
      );

  final frame = Uint8List.fromList([0xFF, 0xD8, 7, 0xFF, 0xD9]);

  setUp(() => built = 0);

  test('界面上没有画面时直连视频源取第一帧', () async {
    final g = grabber();
    addTearDown(g.dispose);

    final pending = g.grab(cam(), preferMounted: false);
    await pumpEventQueue();
    relay.ctl.add(frame);

    expect(await pending, frame);
    expect(relay.attaches, 1);
    expect(relay.detaches, 1, reason: '取完帧必须摘掉，否则 relay 一直占着连接');
  });

  test('源一直不出帧时按超时返回 null，并摘掉客户端', () async {
    final g = grabber(timeout: const Duration(milliseconds: 50));
    addTearDown(g.dispose);

    expect(await g.grab(cam(), preferMounted: false), isNull);
    expect(relay.detaches, 1);
  });

  test('停用的摄像头直接返回 null，不建立连接', () async {
    final g = grabber();
    addTearDown(g.dispose);

    expect(await g.grab(cam(enabled: false), preferMounted: false), isNull);
    expect(built, 0);
  });

  test('机内摄像头没绑定打印机时立即返回 null，不等超时', () async {
    final g = grabber(timeout: const Duration(seconds: 30));
    addTearDown(g.dispose);

    final sw = Stopwatch()..start();
    expect(
      await g.grab(
        cam(type: CameraSourceType.bambu, printerIds: const ['p-missing']),
        preferMounted: false,
      ),
      isNull,
    );
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(built, 0);
  });

  test('重复抓帧复用同一个 relay', () async {
    final g = grabber();
    addTearDown(g.dispose);

    for (var i = 0; i < 2; i++) {
      final pending = g.grab(cam(), preferMounted: false);
      await pumpEventQueue();
      relay.ctl.add(frame);
      expect(await pending, frame);
    }
    expect(built, 1);
    expect(relay.attaches, 2);
  });
}
