import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/theme.dart';
import '../data/bambu_mjpeg.dart';
import 'mjpeg_tile.dart';

/// Live video tile for one stream URL (PRD FR-3). Wraps a media_kit
/// player with connect/error states and a manual retry; RTSP streams get
/// low-latency, TCP-forced transport settings. `bmjpeg://` URLs (the
/// A1/P1-family built-in camera) dispatch to [MjpegTile] instead - that
/// protocol is not something libmpv can demux.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.streamUrl,
    this.label = '',
    this.aspectRatio = 16 / 9,
    this.showLabel = true,
  });

  final String streamUrl;
  final String label;
  final double aspectRatio;
  final bool showLabel;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  StreamSubscription<String>? _errSub;

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
    setState(() => _error = null);
    await _teardown();

    final player = Player(
        configuration: const PlayerConfiguration(
      // Live view: keep the buffer small so the picture stays close to now.
      bufferSize: 4 * 1024 * 1024,
    ));
    final controller = await VideoController.create(player.handle);
    try {
      // RTSP over TCP avoids UDP artifact storms on lossy Wi-Fi; low-latency
      // profile trades robustness for freshness, which is what monitoring
      // wants. Properties are best-effort across libmpv builds.
      final platform = player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
        await platform.setProperty('profile', 'low-latency');
        await platform.setProperty('network-timeout', '5');
      }
    } catch (_) {
      // Non-fatal: defaults still play.
    }
    _errSub = player.stream.error.listen((e) {
      if (mounted) setState(() => _error = '视频流错误: $e');
    });

    setState(() {
      _player = player;
      _controller = controller;
    });
    try {
      await player.open(Media(url));
    } catch (e) {
      if (mounted) setState(() => _error = '无法连接视频源: $e');
    }
  }

  Future<void> _teardown() async {
    _errSub?.cancel();
    _errSub = null;
    final p = _player;
    _player = null;
    _controller = null;
    await p?.dispose();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.streamUrl.startsWith('bmjpeg://')) {
      final parsed = parseBambuMjpegUrl(widget.streamUrl);
      if (parsed != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: widget.aspectRatio,
            child: MjpegTile(
              host: parsed.host,
              port: parsed.port,
              username: parsed.username,
              password: parsed.password,
              label: widget.showLabel ? widget.label : null,
            ),
          ),
        );
      }
    }
    final controller = _controller;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: widget.aspectRatio,
          child: Stack(fit: StackFit.expand, children: [
            if (controller != null && _error == null)
              Video(controller: controller, fit: BoxFit.contain)
            else if (_error != null)
              _overlay(const Icon(Icons.videocam_off_outlined,
                  size: 34, color: DeckColors.error), _error!)
            else
              _overlay(const CircularProgressIndicator(strokeWidth: 2),
                  '连接视频源…'),
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
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                ),
              ),
            if (_error != null)
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
}
