import 'camera_profile.dart';
import 'ezviz_cloud.dart';
import 'ezviz_session.dart';

/// 萤石云端取流 (直接读云端 2026-11-03).
///
/// A cloud camera ([CameraSourceType.ezviz]) is identified by its serial
/// alone; its playback address is a signed FLV/HLS live address from the
/// EZVIZ open platform that **expires** (we request 5 minutes of
/// validity). This cache resolves one per serial on demand, hands out
/// only unexpired entries via [cached], and refetches when a consumer
/// reports the stream dead ([markFailed]) - the App 画面块 and the hub
/// web relay both heal through it without persisting anything to disk.
class EzvizStreamCache {
  EzvizStreamCache({
    required this.session,
    this.ttl = const Duration(minutes: 4),
    this.expireSeconds = 300,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final EzvizSession session;
  final Duration ttl;
  final int expireSeconds;
  final void Function(String line)? log;
  final DateTime Function() _now;

  final _entries = <String, _Entry>{};
  final _pending = <String, Future<String?>>{};
  final _lastForceFetch = <String, DateTime>{};

  /// How soon after a failure another forced refetch may run - mpv fires
  /// several error events for one dead stream, and a device that is
  /// offline would otherwise be polled once per error.
  static const _forceMinInterval = Duration(seconds: 15);

  /// The current address for [serial], or null when there is none or it
  /// has aged past [ttl] (the platform expires it shortly after; handing
  /// out a dead address just burns the consumer's retry budget).
  String? cached(String serial) {
    final e = _entries[serial];
    if (e == null) return null;
    if (_now().difference(e.fetchedAt) >= ttl) return null;
    return e.url;
  }

  /// Resolves (or reuses) the live address for [serial]. Concurrent calls
  /// share one request; [force] bypasses the TTL - used on mount and on
  /// stream failure, still rate-limited by [_forceMinInterval].
  Future<String?> fetch(String serial, {bool force = false}) {
    serial = serial.trim();
    if (serial.isEmpty) return Future.value(null);
    final e = _entries[serial];
    if (!force && e != null && _now().difference(e.fetchedAt) < ttl) {
      return Future.value(e.url);
    }
    if (force) {
      final last = _lastForceFetch[serial];
      if (last != null && _now().difference(last) < _forceMinInterval) {
        // Inside the throttle window: an expired address is worthless, so
        // report none - the consumer retries and the next window fetches.
        return Future.value(cached(serial));
      }
      _lastForceFetch[serial] = _now();
    }
    return _flight(serial).catchError((Object err) {
      log?.call('[ezviz] $serial 取流地址失败: $err');
      return null;
    });
  }

  /// Single-flight resolution shared by [fetch] and [fetchOrThrow].
  /// 注意这里不能用 `_pending[serial] ??= ...whenComplete(() => _pending.remove(...))`:
  /// map 的值就是 Future 本身, 箭头闭包会把 remove 返回的**那条 Future**交给
  /// whenComplete, 而 whenComplete 会 await 回调返回的 Future —— 等于 future
  /// 等它自己的完成, 永久挂死 (dart run/flutter test 双双实测)。块体返回 void
  /// 才安全; 单飞也改成显式判重, 不用 ??=。这条 future 会把解析错误抛给调用方,
  /// [fetch] 在外面接住转 null, [fetchOrThrow] 原样放行。
  Future<String?> _flight(String serial) {
    final existing = _pending[serial];
    if (existing != null) return existing;
    final Future<String?> f = _resolve(serial).whenComplete(() {
      _pending.remove(serial);
    });
    _pending[serial] = f;
    return f;
  }

  /// Stream died - drop the cached address and pull a fresh one so the
  /// next [fetch] (or relay retry) reconnects with a valid signature.
  void invalidate(String serial) => _entries.remove(serial.trim());

  /// Like [fetch] but rethrows the resolution error - 导入界面要把「加密已开启」
  /// 这类平台原因直接摆给用户 (泛泛的「取流失败」没法行动)。
  Future<String?> fetchOrThrow(String serial) {
    serial = serial.trim();
    if (serial.isEmpty) return Future.value(null);
    final e = _entries[serial];
    if (e != null && _now().difference(e.fetchedAt) < ttl) {
      return Future.value(e.url);
    }
    return _flight(serial);
  }

  Future<String?> _resolve(String serial) async {
    final url = await session.run<String>((token) async {
      try {
        return await session.client.liveAddress(token, serial,
            protocol: 4, quality: 1, expireSeconds: expireSeconds);
      } on EzvizApiException {
        // FLV is H.264-only and some gateways only serve HLS - retry once.
        return await session.client.liveAddress(token, serial,
            protocol: 2, quality: 1, expireSeconds: expireSeconds);
      }
    });
    _entries[serial] = _Entry(url: url, fetchedAt: _now());
    log?.call('[ezviz] $serial 取流地址已刷新 '
        '(${Uri.parse(url).scheme}, ${Uri.parse(url).host})');
    return url;
  }
}

class _Entry {
  const _Entry({required this.url, required this.fetchedAt});

  final String url;
  final DateTime fetchedAt;
}
