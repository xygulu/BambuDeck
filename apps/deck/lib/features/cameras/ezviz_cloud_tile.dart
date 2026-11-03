import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/camera_providers.dart';
import '../../data/ezviz_cloud.dart';
import '../../data/ezviz_ptz.dart';
import '../../data/ptz_client.dart';

/// 萤石云端画面挂载点 (直接读云端 2026-11-03).
///
/// Cloud cameras carry no stored URL - their signed FLV/HLS address
/// expires, so [EzvizStreamCache] resolves one per mount and refreshes it
/// when the player reports the stream dead ([CameraTile.onStreamFailed]).
/// [builder] receives the resolved address, a refetch callback and the
/// cloud PTZ client (平台云台走画面上的方向键, 同 LAN 体验 2026-11-03);
/// while resolving (or when the cloud says no) a placeholder explains
/// the wait.
class EzvizCloudFeed extends ConsumerStatefulWidget {
  const EzvizCloudFeed({
    super.key,
    required this.camera,
    required this.builder,
  });

  final CameraProfile camera;

  /// (context, resolvedUrl, refetch, ptzClient) - refetch is throttled
  /// upstream; ptzClient is null for cameras without platform PTZ.
  final Widget Function(BuildContext, String, VoidCallback, PtzClient?)
      builder;

  @override
  ConsumerState<EzvizCloudFeed> createState() => _EzvizCloudFeedState();
}

class _EzvizCloudFeedState extends ConsumerState<EzvizCloudFeed> {
  String? _url;
  String? _error;
  PtzClient? _ptz;

  @override
  void initState() {
    super.initState();
    _ptz = EzvizCloudPtz(
      session: ref.read(ezvizSessionProvider),
      serial: widget.camera.ezvizSerial,
      log: null,
    );
    _load();
  }

  @override
  void didUpdateWidget(EzvizCloudFeed old) {
    super.didUpdateWidget(old);
    if (old.camera.ezvizSerial != widget.camera.ezvizSerial) {
      _url = null;
      _error = null;
      _ptz?.dispose();
      _ptz = EzvizCloudPtz(
        session: ref.read(ezvizSessionProvider),
        serial: widget.camera.ezvizSerial,
        log: null,
      );
      _load();
    }
  }

  @override
  void dispose() {
    _ptz?.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final cache = ref.read(ezvizStreamsProvider);
    try {
      // 初次挂载用会抛错的变体, 把「加密已开启」这类平台原因直接摆上占位图;
      // 断流重取仍走 fetch(force) —— 那条路有 15 秒节流, mpv 对一条死流会
      // 连发好几个错误事件, 不能每次都真打到平台 API。
      final url = force
          ? await cache.fetch(widget.camera.ezvizSerial, force: true)
          : await cache.fetchOrThrow(widget.camera.ezvizSerial);
      if (!mounted) return;
      setState(() {
        if (url != null) _error = null;
        _url = url;
        if (url == null && _error == null) {
          _error = '云端取流失败, 稍后自动重试';
        }
      });
    } on EzvizApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = '萤石云端: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '云端取流失败: $e');
    }
  }

  /// Stream died: pull a fresh address; the new url re-opens the tile via
  /// didUpdateWidget (the cache rate-limits forced refetches itself).
  void _refetch() => _load(force: true);

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url != null) {
      return widget.builder(context, url, _refetch, _ptz);
    }
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(height: 10),
        Text(
          _error ?? '正在从萤石云端取流…',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12,
              color:
                  _error == null ? DeckColors.textSecondary : Colors.white70),
        ),
      ]),
    );
  }
}
