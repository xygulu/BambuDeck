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
  final _lastEncryptOff = <String, DateTime>{};
  final _flvFailures = <String, int>{};

  /// How soon after a failure another forced refetch may run - mpv fires
  /// several error events for one dead stream, and a device that is
  /// offline would otherwise be polled once per error.
  static const _forceMinInterval = Duration(seconds: 15);

  /// 同一个序列号两次自动关闭视频加密的最小间隔 - 平台侧真关掉之前不反复
  /// 打这个写接口; 萤石App 若过几天又打开开关, 超过这个间隔就会自愈。
  static const _encryptOffMinInterval = Duration(minutes: 10);

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
      _noteDead(serial);
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
  void invalidate(String serial) {
    serial = serial.trim();
    _entries.remove(serial);
    _noteDead(serial);
  }

  /// 记一条断流。连续断两次就认定 FLV 网关在这条网络线路上不稳 (实测
  /// 地下室的 FLV 频繁 TLS 超时而 HLS 干净), 下次解析改优先 HLS; FLV
  /// 真正拉通后计数清零、回到优先 FLV。
  void _noteDead(String serial) {
    _flvFailures[serial] = (_flvFailures[serial] ?? 0) + 1;
  }

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
    final preferHls = (_flvFailures[serial] ?? 0) >= 2;
    final first = preferHls ? 2 : 4;
    final second = preferHls ? 4 : 2;
    final url = await session.run<String>((token) async {
      try {
        final url = await _live(token, serial, protocol: first);
        if (first == 4) _flvFailures.remove(serial);
        return url;
      } on EzvizApiException catch (e) {
        // 加密类错误换协议也一样, 直接把那条更可行动的抛出去。
        if (e.code == '60019') rethrow;
        // FLV is H.264-only and some gateways only serve HLS - retry once.
        final url = await _live(token, serial, protocol: second);
        if (second == 4) _flvFailures.remove(serial);
        return url;
      }
    });
    _entries[serial] = _Entry(url: url, fetchedAt: _now());
    log?.call('[ezviz] $serial 取流地址已刷新 '
        '(${Uri.parse(url).scheme}, ${Uri.parse(url).host})');
    return url;
  }

  /// One live-address call, healing 60019 加密已开启: a device with 视频加密
  /// switched on refuses *every* cloud stream, so the fix is the platform's
  /// encrypt/off followed by one retry (用户 2026-11-03 同意自动关闭).
  /// 萤石App 过几天可能又把开关打开, 所以按 [_encryptOffMinInterval] 节流
  /// 重试, 而不是只做一次。
  Future<String> _live(String token, String serial,
      {required int protocol}) async {
    Future<String> call() => session.client.liveAddress(token, serial,
        protocol: protocol, quality: 1, expireSeconds: expireSeconds);
    try {
      return await call();
    } on EzvizApiException catch (e) {
      if (e.code != '60019') rethrow;
      final last = _lastEncryptOff[serial];
      if (last != null && _now().difference(last) < _encryptOffMinInterval) {
        rethrow;
      }
      _lastEncryptOff[serial] = _now();
      log?.call('[ezviz] $serial 视频加密已开启, 尝试自动关闭');
      try {
        await session.client.encryptOff(token, serial);
      } on EzvizApiException catch (off) {
        // 平台可能要设备验证码才让关 (20010) - 这时只能引导用户去App里关。
        throw EzvizApiException(
            '60019',
            '视频加密已开启, 自动关闭失败(${off.message})'
                '——请在萤石App该摄像头设置里关闭视频加密');
      }
      return call();
    }
  }
}

class _Entry {
  const _Entry({required this.url, required this.fetchedAt});

  final String url;
  final DateTime fetchedAt;
}
