import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/bambu_mjpeg.dart';
import '../data/camera_audio.dart';
import '../data/camera_profile.dart';
import '../data/hcnetsdk.dart';
import '../data/log_buffer.dart';
import '../data/onvif_ptz.dart';
import '../data/ptz_client.dart';
import '../data/rtsp_quality.dart';
import '../data/vision_guard.dart';
import 'mjpeg_tile.dart';
import 'ptz_pad.dart';

/// Callback factory for the tiles' main/sub quality chip: null when the
/// camera cannot swap streams (built-in, or a URL without a recognizable
/// stream marker), otherwise a closure that flips and persists [camera].
VoidCallback? qualityToggler(WidgetRef ref, CameraProfile camera) =>
    camera.sourceType != CameraSourceType.rtsp ||
            !rtspQualitySwappable(camera.url)
        ? null
        : () {
            ref.read(camerasProvider.notifier).replace(camera.copyWith(
                quality: camera.quality == RtspQuality.main
                    ? RtspQuality.sub
                    : RtspQuality.main));
          };

/// Toggles the owning camera's horizontal mirror (画面翻转 2026-10-20).
VoidCallback flipToggler(WidgetRef ref, CameraProfile camera) => () {
      ref
          .read(camerasProvider.notifier)
          .replace(camera.copyWith(flipH: !camera.flipH));
    };

/// Sets the owning camera's clockwise rotation (画面旋转 2026-10-20).
ValueChanged<int> rotationSetter(WidgetRef ref, CameraProfile camera) =>
    (deg) => ref
        .read(camerasProvider.notifier)
        .replace(camera.copyWith(rotationDeg: deg));

/// Live video tile for one stream URL (PRD FR-3). Wraps a media_kit
/// player with connect/error states and a manual retry; RTSP streams get
/// low-latency, TCP-forced transport settings. `bmjpeg://` URLs (the
/// A1/P1-family built-in camera) dispatch to [MjpegTile] instead - that
/// protocol is not something libmpv can demux.
///
/// RTSP tiles also carry camera controls: a main/sub quality chip (when
/// [onToggleQuality] is given and the URL encodes a swappable stream) and
/// an ONVIF PTZ pad built from the URL's own credentials.
class CameraTile extends ConsumerStatefulWidget {
  const CameraTile({
    super.key,
    required this.streamUrl,
    this.label = '',
    this.aspectRatio = 16 / 9,
    this.showLabel = true,
    this.onToggleQuality,
    this.expand = false,
    this.flipH = false,
    this.rotationDeg = 0,
    this.ptzInvertPan = false,
    this.ptzInvertTilt = false,
    this.onToggleFlip,
    this.onSetRotation,
    this.cameraId,
    this.frameSlot = 'main',
  });

  final String streamUrl;
  final String label;
  final double aspectRatio;
  final bool showLabel;

  /// Null hides the quality chip (built-in cameras, dashboard previews).
  final VoidCallback? onToggleQuality;

  /// Fill the parent box instead of locking to [aspectRatio]. The video
  /// itself stays undistorted (contain), so a wall cell of any shape
  /// just letterboxes (camera-wall zoom uses this).
  final bool expand;

  /// Horizontal mirror for the picture (画面翻转 2026-10-20).
  final bool flipH;

  /// Clockwise rotation in degrees (0/90/180/270) to right the mount
  /// (画面旋转 2026-10-20).
  final int rotationDeg;

  /// PTZ axis calibration passed through to [PtzPad] (云台方向校准).
  final bool ptzInvertPan;
  final bool ptzInvertTilt;

  /// Toggles [flipH] on the owning camera; null hides the orientation menu.
  final VoidCallback? onToggleFlip;

  /// Sets [rotationDeg] to a specific angle; null hides the orientation menu.
  final ValueChanged<int>? onSetRotation;

  /// Owning camera id: when set, the rendered picture is wrapped in a
  /// RepaintBoundary registered under (cameraId, frameSlot) so the vision
  /// guard can snapshot the frame without touching the decoder. Each live
  /// mount of the same camera must use a distinct [frameSlot] - a GlobalKey
  /// may sit in only one place (视觉抓帧 2026-10-20).
  final String? cameraId;

  /// Mount-site discriminator for the frame boundary registry.
  final String frameSlot;

  /// Whether the orientation menu is shown (any of its actions present).
  bool get _showOrientation => onToggleFlip != null || onSetRotation != null;

  @override
  ConsumerState<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends ConsumerState<CameraTile> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  StreamSubscription<String>? _errSub;
  PtzClient? _ptz;

  /// The web console's mute toggle flips the same global setting; the bus
  /// lets it reach this already-open player.
  late final void Function(bool muted) _muteSink = _applyMuted;

  void _applyMuted(bool muted) => _player?.setVolume(muted ? 0 : 100);

  @override
  void initState() {
    super.initState();
    _open(widget.streamUrl);
  }

  @override
  void didUpdateWidget(CameraTile old) {
    super.didUpdateWidget(old);
    if (old.streamUrl != widget.streamUrl) {
      _open(widget.streamUrl);
    }
  }

  Future<void> _open(String url) async {
    // Log the (credential-masked) source so stream failures in the log
    // name the exact URL that failed.
    LogBuffer.instance.add('[${widget.label}] 打开视频源: '
        '${_maskCredentials(url)}');
    // bmjpeg:// is served by MjpegTile in build() - no mpv player here.
    // Handing the scheme to media_kit would just spew playlist errors.
    if (url.startsWith('bmjpeg://')) {
      await _teardown();
      if (mounted) setState(() => _error = null);
      return;
    }
    setState(() => _error = null);
    await _teardown();

    final player = Player(
        configuration: const PlayerConfiguration(
      // Live view: keep the buffer small so the picture stays close to now.
      bufferSize: 4 * 1024 * 1024,
    ));
    // media_kit 1.2.6 has no setMuted - muting is volume 0. Start with the
    // persisted choice so a fresh stream never blares before the toggle is
    // touched.
    if (ref.read(appSettingsProvider).valueOrNull?.cameraMuted ?? false) {
      await player.setVolume(0);
    }
    cameraAudioBus.attach(_muteSink);
    final controller = VideoController(player);
    try {
      // RTSP over TCP avoids UDP artifact storms on lossy Wi-Fi; low-latency
      // profile trades robustness for freshness, which is what monitoring
      // wants. Properties are best-effort across libmpv builds.
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
        await platform.setProperty('profile', 'low-latency');
        await platform.setProperty('network-timeout', '5');
        // Software-decode RTSP video: media_kit_video 0.0.4 cannot take
        // VideoToolbox hardware frames on macOS - the stream plays (audio
        // is audible) but the picture stays black (萤石 HEVC 实测 2026-10-20).
        // Sw decode of 1440p HEVC is trivial for Apple Silicon.
        await platform.setProperty('hwdec', 'no');
      }
    } catch (_) {
      // Non-fatal: defaults still play.
    }
    _errSub = player.stream.error.listen((e) {
      LogBuffer.instance.add('[${widget.label}] 视频流错误: $e');
      if (mounted) setState(() => _error = '视频流错误: $e');
    });

    setState(() {
      _player = player;
      _controller = controller;
    });
    try {
      await player.open(Media(url));
    } catch (e) {
      LogBuffer.instance.add('[${widget.label}] 无法连接视频源: $e');
      if (mounted) setState(() => _error = '无法连接视频源: $e');
    }
  }

  /// Flip the global camera mute (persisted) and apply it to the live
  /// player immediately.
  void _toggleMute() {
    final settings =
        ref.read(appSettingsProvider).valueOrNull ?? const AppSettings();
    final want = !settings.cameraMuted;
    ref
        .read(appSettingsProvider.notifier)
        .set(settings.copyWith(cameraMuted: want));
    _player?.setVolume(want ? 0 : 100);
  }

  Future<void> _teardown() async {
    cameraAudioBus.detach(_muteSink);
    _errSub?.cancel();
    _errSub = null;
    final p = _player;
    _player = null;
    _controller = null;
    _ptz?.dispose();
    _ptz = null;
    if (p != null) {
      // Halt playback before terminate: destroying a player whose RTSP
      // demuxer is still live aborts inside mpv (mp_clients_destroy,
      // crash 2026-10-20 主/子码流切换).
      try {
        await p.stop();
      } catch (_) {}
      await p.dispose();
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  /// AspectRatio lock unless [CameraTile.expand] - the video itself is
  /// contain-fit either way.
  Widget _box(Widget child) => widget.expand
      ? SizedBox.expand(child: child)
      : AspectRatio(aspectRatio: widget.aspectRatio, child: child);

  @override
  Widget build(BuildContext context) {
    if (widget.streamUrl.startsWith('bmjpeg://')) {
      final parsed = parseBambuMjpegUrl(widget.streamUrl);
      if (parsed != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: _box(_orient(_frameBoundary(MjpegTile(
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            password: parsed.password,
            label: widget.showLabel ? widget.label : null,
          )))),
        );
      }
      // Malformed built-in URL: never let it fall through to mpv (it would
      // come back as a baffling playlist error).
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          color: Colors.black,
          child: _box(_overlay(
              const Icon(Icons.videocam_off_outlined,
                  size: 34, color: DeckColors.error),
              '打印机摄像头地址无效')),
        ),
      );
    }
    final controller = _controller;
    final url = widget.streamUrl;
    final showQuality = widget.onToggleQuality != null &&
        rtspQualitySwappable(url) &&
        _error == null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: Colors.black,
        child: _box(
          Stack(fit: StackFit.expand, children: [
            if (controller != null && _error == null)
              _orient(_frameBoundary(Video(
                  controller: controller,
                  fit: BoxFit.contain,
                  // No built-in overlay controls: monitoring tiles manage
                  // their own chips (quality/PTP/retry).
                  controls: NoVideoControls)))
            else if (_error != null)
              _overlay(
                  const Icon(Icons.videocam_off_outlined,
                      size: 34, color: DeckColors.error),
                  _error!)
            else
              _overlay(
                  const CircularProgressIndicator(strokeWidth: 2), '连接视频源…'),
            if (widget.showLabel && widget.label.isNotEmpty)
              Positioned(
                left: 10,
                top: 10,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(widget.label,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            if (_error == null)
              Positioned(
                right: 10,
                top: 10,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (showQuality) ...[
                    QualityToggle(
                      isSub: rtspQualityOfUrl(url) == RtspQuality.sub,
                      onToggle: widget.onToggleQuality!,
                    ),
                    const SizedBox(width: 6),
                  ],
                  // RTSP streams may carry audio; built-in MJPEG has none.
                  MuteToggle(
                    muted: ref
                            .watch(appSettingsProvider)
                            .valueOrNull
                            ?.cameraMuted ??
                        false,
                    onToggle: _toggleMute,
                  ),
                  if (widget._showOrientation) ...[
                    const SizedBox(width: 6),
                    _orientationMenu(),
                  ],
                ]),
              ),
            if (_error == null)
              Positioned(
                right: 10,
                bottom: 10,
                child: _ptzPadFor(url),
              )
            else
              Positioned(
                right: 10,
                bottom: 10,
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '重连',
                  onPressed: () => _open(widget.streamUrl),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// PTZ pad for third-party RTSP cameras. The client lives in this widget's
  /// state (created once per stream URL); it probes ONVIF first and falls back
  /// to the EZVIZ/Hikvision command port, so a camera works whether or not
  /// ONVIF is enabled in its own app. The pad stays visible (dimmed) when no
  /// transport is reachable.
  ///
  /// The pad is drawn through the very same flip/rotation as the picture, so
  /// its keys travel with the image: an arrow always points the way the
  /// picture will move (用户口径 2026-10-24). Commands therefore stay exactly
  /// as the initial view defines them - no per-angle remapping, nothing to get
  /// wrong.
  Widget _ptzPadFor(String url) {
    final client = _ptzClient();
    if (client == null) return const SizedBox.shrink();
    return _transform(PtzPad(
      client: client,
      invertPan: widget.ptzInvertPan,
      invertTilt: widget.ptzInvertTilt,
    ));
  }

  /// Parsed stream URL when it can carry PTZ credentials, else null.
  Uri? _ptzUri() {
    final u = Uri.tryParse(widget.streamUrl);
    if (u == null ||
        (u.scheme != 'rtsp' && u.scheme != 'rtsps') ||
        u.userInfo.isEmpty ||
        u.host.isEmpty) {
      return null;
    }
    return u;
  }

  /// Lazy PTZ client for this tile (probe-once, shared by the pad and the
  /// calibration dialog); null for URLs that cannot carry credentials.
  PtzClient? _ptzClient() {
    final u = _ptzUri();
    if (u == null) return null;
    return _ptz ??= () {
      final sep = u.userInfo.indexOf(':');
      final user = sep < 0 ? u.userInfo : u.userInfo.substring(0, sep);
      final pass =
          sep < 0 ? '' : Uri.decodeComponent(u.userInfo.substring(sep + 1));
      return FallbackPtz([
        OnvifPtz(host: u.host, port: 8899, username: user, password: pass),
        HcNetSdkPtz(host: u.host, username: user, password: pass),
      ]);
    }();
  }

  /// Registers the video picture for the vision guard's snapshots when a
  /// [CameraTile.cameraId] was supplied; a plain passthrough otherwise.
  Widget _frameBoundary(Widget child) {
    final id = widget.cameraId;
    if (id == null) return child;
    return RepaintBoundary(
        key: frameRegistry.keyFor(id, widget.frameSlot), child: child);
  }

  /// Applies the persisted flip/rotation to the video frame and to the PTZ
  /// pad, so the pad's keys stay aligned with the picture. Other overlay
  /// chips (quality/mute/menu) stay upright.
  /// 90/270° letterbox inside a 16:9 tile; the common flip/180° cases fill it
  /// exactly.
  Widget _orient(Widget child) => _transform(child);

  /// `T = FlipX(flipH) · RotZ(rotationDeg)`, or the child untouched when both
  /// are neutral. The single place the picture transform is defined - the
  /// video and the PTZ pad must always receive the identical matrix.
  Widget _transform(Widget child) {
    if (!widget.flipH && widget.rotationDeg == 0) return child;
    final m = Matrix4.identity();
    if (widget.flipH) m.scale(-1.0, 1.0, 1.0);
    if (widget.rotationDeg != 0) {
      m.rotateZ(widget.rotationDeg * math.pi / 180.0);
    }
    return Transform(alignment: Alignment.center, transform: m, child: child);
  }

  /// Compact popup for 画面翻转/旋转: a horizontal-mirror toggle plus the
  /// four rotation angles (增加视频画面翻转和旋转功能 2026-10-20).
  Widget _orientationMenu() {
    final active = widget.flipH || widget.rotationDeg != 0;
    return PopupMenuButton<String>(
      tooltip: '画面翻转 / 旋转',
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.screen_rotation_alt,
        size: 16,
        color: active ? Colors.amber : Colors.white,
      ),
      onSelected: (v) {
        if (v == 'flip') {
          widget.onToggleFlip?.call();
        } else {
          widget.onSetRotation?.call(int.parse(v));
        }
      },
      itemBuilder: (_) => [
        if (widget.onToggleFlip != null)
          PopupMenuItem(
            value: 'flip',
            child: Row(children: [
              Icon(
                  widget.flipH
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 16),
              const SizedBox(width: 8),
              const Text('水平翻转', style: TextStyle(fontSize: 13)),
            ]),
          ),
        if (widget.onSetRotation != null)
          for (final deg in const [0, 90, 180, 270])
            PopupMenuItem(
              value: '$deg',
              child: Row(children: [
                Icon(
                    widget.rotationDeg == deg
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16),
                const SizedBox(width: 8),
                Text('旋转 ${deg == 0 ? '0°(正常)' : '$deg°'}',
                    style: const TextStyle(fontSize: 13)),
              ]),
            ),
      ],
    );
  }

  Widget _overlay(Widget indicator, String text) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          indicator,
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(text,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, color: DeckColors.textSecondary)),
          ),
        ]),
      );

  /// `rtsp://user:secret@host` → `rtsp://user:***@host`.
  static String _maskCredentials(String url) => url.replaceAllMapped(
      RegExp(r'(://[^:@/]+:)[^@/]+(@)'),
      (m) => '${m.group(1)}***${m.group(2)}');
}
