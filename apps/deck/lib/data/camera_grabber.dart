import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'camera_profile.dart';
import 'hub_server.dart' show CameraRelay, discoverFfmpeg;
import 'log_buffer.dart';
import 'printer_profile.dart';

/// RepaintBoundary keys that let the vision guard snapshot a live camera
/// tile without touching its decoder (works for MJPEG and RTSP alike).
///
/// One camera can be mounted in several places at once (dashboard section,
/// monitor pane, camera wall - IndexedStack keeps them all alive), and a
/// GlobalKey may sit in only one place, so every mount site registers its
/// own [slot]; [grab] tries each and uses the first that is laid out and
/// visible (offstage pages have zero-size render objects).
class CameraFrameRegistry {
  final _keys = <String, GlobalKey>{};

  GlobalKey keyFor(String cameraId, String slot) =>
      _keys.putIfAbsent('$cameraId|$slot', () => GlobalKey());

  /// PNG bytes of the camera's current picture, or null when no mounted
  /// boundary could be rasterized (page hidden / camera off the screen).
  Future<Uint8List?> grab(String cameraId,
      {double pixelRatio = 0.75}) async {
    for (final entry in _keys.entries) {
      if (!entry.key.startsWith('$cameraId|')) continue;
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      // Not a widget-mount context - it lives for the render tree's life,
      // and the attached/size checks below guard every use.
      // ignore: use_build_context_synchronously
      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.attached) continue;
      if (ro.size.isEmpty || ro.debugNeedsLayout || ro.debugNeedsPaint) {
        continue;
      }
      try {
        final image = await ro.toImage(pixelRatio: pixelRatio);
        final data =
            await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data != null && data.lengthInBytes > 0) {
          return data.buffer.asUint8List();
        }
      } catch (_) {
        // frame gone mid-capture - try the next slot
      }
    }
    return null;
  }
}

final frameRegistry = CameraFrameRegistry();

/// 取一帧画面给视觉判读用。
///
/// 两条路：
///  1. **界面画面**：摄像头卡正挂着时直接截 RepaintBoundary，不额外占一条
///     视频流（Bambu 机内摄像头并发连接数有限，能省就省）。
///  2. **直连视频源**：界面上没有这个画面时（用户在设置页、切到了别的视角、
///     窄窗口里没进监控页），走和网页端同一套 [CameraRelay] 拉一帧 ——
///     bmjpeg 用 [BambuMjpegStream]，RTSP 用 ffmpeg。
///
/// 反馈 2026-10-24：「测试判读」在设置页点，界面画面全被遮住（路由不透明，
/// 下层没在绘制 → 截图为空），旧代码只走第 1 条路，于是永远回「没有可抓取
/// 的画面」。视觉守卫后台运行时其实是同一个坑：只有那台打印机的监控画面正
/// 好显示着才会判读。
class CameraGrabber {
  CameraGrabber({
    String? ffmpegPath,
    Duration? firstFrameTimeout,
    CameraRelay Function(
            CameraProfile camera, String? Function() resolveUrl)?
        relayFactory,
  })  : ffmpegPath = ffmpegPath ?? discoverFfmpeg(),
        firstFrameTimeout = firstFrameTimeout ?? const Duration(seconds: 15),
        _relayFactory = relayFactory;

  final String ffmpegPath;

  /// 直连源的第一帧等待上限：ffmpeg 连 RTSP 慢的时候要 3~8 秒。
  final Duration firstFrameTimeout;

  /// Test seam: builds the relay without opening a real stream.
  final CameraRelay Function(
      CameraProfile camera, String? Function() resolveUrl)? _relayFactory;

  final _relays = <String, CameraRelay>{};

  /// The printer each Bambu camera currently resolves against. Kept here
  /// (not captured in the relay's closure) so a grab that ran before the
  /// printer list loaded does not leave a relay stuck on a null printer.
  final _linkedPrinters = <String, PrinterProfile?>{};

  Future<Uint8List?> grab(
    CameraProfile camera, {
    List<PrinterProfile> printers = const [],
    bool preferMounted = true,
    Duration? timeout,
  }) async {
    if (!camera.enabled) return null;
    if (preferMounted) {
      final shot = await frameRegistry.grab(camera.id);
      if (shot != null) return shot;
    }
    return _fromSource(
        camera, _linked(camera, printers), timeout ?? firstFrameTimeout);
  }

  /// Bambu 机内摄像头要从绑定的打印机拿 IP/访问码。
  PrinterProfile? _linked(CameraProfile c, List<PrinterProfile> printers) {
    if (c.sourceType != CameraSourceType.bambu) return null;
    for (final p in printers) {
      if (c.printerIds.contains(p.id)) return p;
    }
    return null;
  }

  Future<Uint8List?> _fromSource(
      CameraProfile c, PrinterProfile? linked, Duration timeout) async {
    _linkedPrinters[c.id] = linked;
    String? resolve() {
      final url = c.enabled ? c.resolveUrl(_linkedPrinters[c.id]) : null;
      return (url != null && url.isNotEmpty) ? url : null;
    }

    // No URL means nothing to connect to - answer at once instead of
    // sitting out the whole first-frame timeout.
    if (resolve() == null) {
      LogBuffer.instance.add('[视觉] ${c.name}: 未配置可用的视频源');
      return null;
    }

    final relay = _relays.putIfAbsent(c.id, () {
      final make = _relayFactory;
      if (make != null) return make(c, resolve);
      return CameraRelay(
        camera: c,
        resolveUrl: resolve,
        ffmpegPath: ffmpegPath,
        log: LogBuffer.instance.add,
      );
    });

    // attach() 会按需启动源；relay 自己带 10 秒宽限，连续判读不会反复重连。
    final frames = relay.attach();
    final completer = Completer<Uint8List?>();
    final sub = frames.listen(
      (frame) {
        if (!completer.isCompleted) completer.complete(frame);
      },
      onError: (_) {},
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
      relay.detach();
    }
  }

  void dispose() {
    for (final r in _relays.values) {
      r.dispose();
    }
    _relays.clear();
  }
}

final cameraGrabber = CameraGrabber();
