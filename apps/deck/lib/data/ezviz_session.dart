import 'app_settings.dart';
import 'ezviz_cloud.dart';

/// One account-level EZVIZ session: exchanges the AppKey/AppSecret stored in
/// settings for an accessToken and caches it in memory (the token is valid
/// for ~7 days; it is never written to disk).
///
/// Every cloud feature goes through [run] so an expired token is refreshed
/// once and retried, and concurrent callers share one token request - the
/// PTZ pad would otherwise fetch a token twice a second.
class EzvizSession {
  EzvizSession({
    required AppSettings Function() settings,
    EzvizCloudClient? client,
    this.log,
  })  : _settings = settings,
        client = client ?? EzvizCloudClient();

  final AppSettings Function() _settings;
  final EzvizCloudClient client;
  final void Function(String line)? log;

  String? _token;
  Future<String>? _pending;

  String get appKey => _settings().ezvizAppKey.trim();
  String get appSecret => _settings().ezvizAppSecret.trim();

  /// True when both credentials are configured; the import sheet persists
  /// them the first time the user fetches the device list.
  bool get configured => appKey.isNotEmpty && appSecret.isNotEmpty;

  Future<String> token({bool force = false}) {
    if (!configured) {
      throw EzvizApiException(
          '配置缺失', '请先在「摄像头 → 从萤石账号导入」里填写 AppKey 和 AppSecret');
    }
    if (force) _token = null;
    final cached = _token;
    if (cached != null) return Future.value(cached);
    return _pending ??= _fetch().whenComplete(() => _pending = null);
  }

  Future<String> _fetch() async {
    final token = await client.fetchToken(appKey: appKey, appSecret: appSecret);
    _token = token;
    return token;
  }

  /// Runs [op] with the cached token, re-fetching once when the platform
  /// says the token is invalid/expired (10002, 10005).
  Future<T> run<T>(Future<T> Function(String token) op) async {
    try {
      return await op(await token());
    } on EzvizApiException catch (e) {
      if (e.code != '10002' && e.code != '10005') rethrow;
      log?.call('[ezviz] token 失效(${e.code}), 重新获取');
      return op(await token(force: true));
    }
  }
}
