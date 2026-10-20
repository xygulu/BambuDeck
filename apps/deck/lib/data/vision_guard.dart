import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'app_settings.dart';
import 'camera_profile.dart';
import 'log_buffer.dart';
import 'print_events.dart' show deckNotifier;
import 'printer_profile.dart';
import 'vision_llm.dart';

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
      final ro = ctx.findRenderObject();
      if (ro is! RenderRepaintBoundary || !ro.attached) continue;
      if (ro.size.isEmpty || ro.debugNeedsLayout) continue;
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

/// One completed analysis per printer, kept for the UI/log surface.
class VisionReport {
  const VisionReport({
    required this.at,
    this.verdict,
    this.inconclusive = false,
  });

  final DateTime at;
  final VisionVerdict? verdict;

  /// True when the frame could not be captured or the model reply did not
  /// parse - never grounds an automatic action.
  final bool inconclusive;
}

/// Watches every printer's state (fed from the connection listeners, same
/// pattern as [PrintEventWatcher]) and, while a printer is actively
/// printing and vision monitoring is on, periodically snapshots its bound
/// camera and asks the configured vision LLM whether the print looks
/// healthy. On spaghetti / empty-print findings it raises a desktop
/// notification (once per anomaly episode) and can auto-pause the task.
class VisionGuard {
  VisionGuard({
    Future<Uint8List?> Function(String cameraId)? grab,
    Future<bool> Function(String printerId)? pauseCommand,
    Future<VisionVerdict?> Function(Uint8List frame, AppSettings s)? analyze,
  })  : _grab = grab ?? frameRegistry.grab,
        pauseCommand = pauseCommand ?? ((String _) async => false),
        _analyzeOverride = analyze;

  final Future<Uint8List?> Function(String cameraId) _grab;

  /// Test/local-model seam: when set, replaces the HTTP vision client.
  final Future<VisionVerdict?> Function(Uint8List frame, AppSettings s)?
      _analyzeOverride;

  /// Sends a pause to a live printer (wired by the app shell to the
  /// connection provider); the default is a no-op (tests / disabled).
  Future<bool> Function(String printerId) pauseCommand;

  /// Synced from appSettingsProvider by the app shell.
  AppSettings settings = const AppSettings();

  /// Synced from camerasProvider by the app shell.
  List<CameraProfile> cameras = const [];

  /// Latest verdict per printer id (null verdict = inconclusive run).
  final reports = <String, VisionReport>{};

  final _states = <String, (PrinterProfile, BambuState)>{};
  Timer? _timer;
  bool _disposed = false;
  final _lastRunAt = <String, DateTime>{};

  /// Remembered per printer so an anomaly notifies once per episode, not
  /// every interval; cleared when the frame returns to normal.
  final _activeAnomaly = <String, String>{};

  /// Absolute cap so a wedged HTTP call can never stack ticks.
  final _runs = <String, Future<void>>{};

  static const _tickEvery = Duration(seconds: 5);

  void observeState(PrinterProfile profile, BambuState s) {
    _states[profile.id] = (profile, s);
    if (_disposed) return;
    // Arm the ticker only when the feature is on - widget tests (default
    // settings) must never leave a pending timer behind, and in the app the
    // next state frame (arrives ~1/s) arms it right after the user flips
    // the switch.
    if (_timer == null && settings.visionEnabled) {
      _timer = Timer.periodic(_tickEvery, (_) => _tick());
      // React to the first state promptly instead of idling until the
      // first periodic tick (interval gate still applies inside _tick).
      unawaited(_tick());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  bool _printing(BambuState s) => s.gcodeState == GcodeState.running;

  Future<void> _tick() async {
    final enabled = settings.visionEnabled && settings.visionApiKey.isNotEmpty;
    if (!enabled) return;
    final interval = Duration(seconds: settings.visionIntervalSec);
    for (final entry in _states.entries) {
      final (profile, s) = entry.value;
      if (!_printing(s)) {
        _activeAnomaly.remove(entry.key);
        continue;
      }
      final last = _lastRunAt[entry.key];
      if (last != null && DateTime.now().difference(last) < interval) {
        continue;
      }
      // One run per printer at a time.
      if (_runs[entry.key] != null) continue;
      _lastRunAt[entry.key] = DateTime.now();
      final run = _analyze(profile);
      _runs[entry.key] = run;
      await run.whenComplete(() => _runs.remove(entry.key));
    }
  }

  String? _cameraIdFor(String printerId) {
    for (final c in cameras) {
      if (c.sourceType == CameraSourceType.rtsp &&
          c.enabled &&
          c.printerIds.contains(printerId)) {
        return c.id;
      }
    }
    for (final c in cameras) {
      if (c.sourceType == CameraSourceType.bambu &&
          c.enabled &&
          c.printerIds.contains(printerId)) {
        return c.id;
      }
    }
    return null;
  }

  Future<void> _analyze(PrinterProfile profile) async {
    // A guard run must never crash the ticker: every failure lands in the
    // log as an inconclusive report instead.
    try {
      await _analyzeInner(profile);
    } catch (e) {
      LogBuffer.instance.add('[视觉] ${profile.name}: 分析异常 $e');
      reports[profile.id] =
          VisionReport(at: DateTime.now(), inconclusive: true);
    }
  }

  Future<void> _analyzeInner(PrinterProfile profile) async {
    final log = LogBuffer.instance.add;
    final cameraId = _cameraIdFor(profile.id);
    if (cameraId == null) return;
    final png = await _grab(cameraId);
    if (png == null) {
      log('[视觉] ${profile.name}: 画面不可抓取(对应摄像头未显示?)');
      _reports(profile.id,
          VisionReport(at: DateTime.now(), inconclusive: true));
      return;
    }
    final s = settings;
    final override = _analyzeOverride;
    VisionVerdict? verdict;
    String? reply;
    if (override != null) {
      verdict = await override(png, s);
    } else {
      final client = VisionLlmClient(
        baseUrl: s.visionBaseUrl,
        apiKey: s.visionApiKey,
        model: s.visionModel,
        log: log,
      );
      reply = await client.analyzeFrame(png);
      verdict = reply == null ? null : parseVisionVerdict(reply);
    }
    if (verdict == null) {
      log('[视觉] ${profile.name}: 判读失败'
          '${reply == null ? '(请求失败)' : '(无法解析: ${_clip(reply)})'}');
      _reports(profile.id,
          VisionReport(at: DateTime.now(), inconclusive: true));
      return;
    }
    log('[视觉] ${profile.name}: ${verdict.abnormal} · '
        '平台物体=${verdict.platformHasObject} · '
        '打印中=${verdict.printRunning} · ${_clip(verdict.notes)}');
    _reports(profile.id, VisionReport(at: DateTime.now(), verdict: verdict));

    if (!verdict.isAbnormal) {
      _activeAnomaly.remove(profile.id);
      return;
    }
    if (_activeAnomaly[profile.id] == verdict.abnormal) {
      return; // same episode - already notified
    }
    _activeAnomaly[profile.id] = verdict.abnormal;

    var paused = false;
    if (s.visionAutoPause) {
      paused = await pauseCommand(profile.id);
    }
    await deckNotifier.show(
      title: '⚠ ${profile.name} 疑似打印异常: ${_abnormalLabel(verdict.abnormal)}',
      body: '${verdict.notes.isEmpty ? _abnormalLabel(verdict.abnormal) : verdict.notes}'
          '${paused ? "\n已自动暂停打印" : ""}',
    );
  }

  void _reports(String printerId, VisionReport r) => reports[printerId] = r;

  static String _abnormalLabel(String abnormal) => switch (abnormal) {
        'spaghetti' => '炒面(乱丝)',
        'empty' => '空打',
        'other' => '画面异常',
        _ => abnormal,
      };

  static String _clip(String text) => text.length > 80
      ? '${text.substring(0, 80)}…'
      : text;
}

/// App-wide guard, fed from the connection listeners.
final visionGuard = VisionGuard();
