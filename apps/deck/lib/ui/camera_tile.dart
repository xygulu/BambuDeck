import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/theme.dart';
import '../data/app_settings.dart';
import '../data/bambu_mjpeg.dart';
import '../data/camera_profile.dart';
import '../data/log_buffer.dart';
import '../data/onvif_ptz.dart';
import '../data/rtsp_quality.dart';
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

  @override
  ConsumerState<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends ConsumerState<CameraTile> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  StreamSubscription<String>? _errSub;
  OnvifPtz? _ptz;

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
          child: _box(MjpegTile(
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            password: parsed.password,
            label: widget.showLabel ? widget.label : null,
          )),
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
              Video(
                  controller: controller,
                  fit: BoxFit.contain,
                  // No built-in overlay controls: monitoring tiles manage
                  // their own chips (quality/PTP/retry).
                  controls: NoVideoControls)
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

  /// ONVIF pad for third-party RTSP cameras. The client lives in this
  /// widget's state (created once per stream URL); the pad hides itself
  /// when the camera has no ONVIF service.
  Widget _ptzPadFor(String url) {
    final u = Uri.tryParse(url);
    if (u == null ||
        (u.scheme != 'rtsp' && u.scheme != 'rtsps') ||
        u.userInfo.isEmpty ||
        u.host.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_ptz == null) {
      final sep = u.userInfo.indexOf(':');
      final user = sep < 0 ? u.userInfo : u.userInfo.substring(0, sep);
      final pass =
          sep < 0 ? '' : Uri.decodeComponent(u.userInfo.substring(sep + 1));
      _ptz = OnvifPtz(host: u.host, port: 8899, username: user, password: pass);
    }
    return PtzPad(client: _ptz!);
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
