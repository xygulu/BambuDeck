import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/version.dart';

/// App 自更新检查 (2026-10-29)。
///
/// 查 GitHub Releases (仓库公开, api.github.com 免认证)。三个平台的处理:
///   Android  下载 APK → 交给系统安装器 (FileProvider + MethodChannel);
///   macOS   只能提示 + 给下载链接 (签名/替换 .app 不能自动做);
///   Windows/iOS  同样只提示 + 给链接。
///
/// 版本号来自 CI 注入的 `--dart-define=DECK_VERSION=X.Y.Z`; 本地构建是
/// 'dev', 永远认为正式版更新。
class AppUpdate {
  static const repo = 'xygulu/BambuDeck';
  static const _api = 'https://api.github.com/repos/$repo/releases/latest';
  static const _channel = MethodChannel('deck/update');

  static HttpClient? _http;

  static HttpClient get _client =>
      _http ??= (HttpClient()..userAgent = 'BambuDeck-app');

  /// 检查更新 -> {current, latest, hasUpdate, notes, apkUrl, releaseUrl}
  static Future<Map<String, dynamic>> check() async {
    final req = await _client.getUrl(Uri.parse(_api));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) {
      throw '仓库还没有发布过版本';
    }
    if (res.statusCode != 200) {
      throw '检查失败: HTTP ${res.statusCode}';
    }
    final rel = jsonDecode(body) as Map<String, dynamic>;
    final tag = (rel['tag_name'] as String?)?.trim() ?? '';
    final latest = tag.replaceFirst(RegExp(r'^[vV]'), '');

    String? apkUrl;
    var manifestVersion = '';
    for (final a in (rel['assets'] as List? ?? const []).cast<Map>()) {
      if (a['name'] == 'version.json') {
        try {
          final mreq = await _client.getUrl(
              Uri.parse(a['browser_download_url'] as String));
          final mres = await mreq.close().timeout(const Duration(seconds: 20));
          final m = jsonDecode(await mres.transform(utf8.decoder).join())
              as Map<String, dynamic>;
          manifestVersion = (m['version'] as String?) ?? '';
          final assets = m['assets'] as Map?;
          apkUrl = assets?['android_apk']?['url'] as String?;
        } catch (_) {
          apkUrl = null;
        }
      }
      if (a['name'] == 'deck-android.apk') {
        apkUrl ??= a['browser_download_url'] as String?;
      }
    }
    final ver = manifestVersion.isNotEmpty ? manifestVersion : latest;
    return <String, dynamic>{
      'current': deckVersion,
      'latest': ver,
      'hasUpdate': compareVersions(ver, deckVersion) > 0,
      'notes': (rel['body'] as String?) ?? '',
      'apkUrl': apkUrl,
      'releaseUrl': 'https://github.com/$repo/releases/latest',
    };
  }

  /// Android: 下载 APK 到缓存目录, 交给系统安装器。
  /// 非 Android 抛异常 (调用方改成给下载链接)。
  static Future<void> downloadAndInstall(String url) async {
    if (!Platform.isAndroid) {
      throw '当前平台不支持自动安装, 请手动下载';
    }
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(minutes: 10));
    if (res.statusCode != 200) throw '下载失败: HTTP ${res.statusCode}';
    // 不引 path_provider: dart:io 的 systemTemp 在 Android 上就是 app 的
    // 缓存目录 (/data/user/0/<包名>/cache), 安装器通过 FileProvider 能读。
    final dir = Directory.systemTemp;
    if (!await dir.exists()) await dir.create(recursive: true);
    final apk = File('${dir.path}/deck-update.apk');
    final sink = apk.openWrite();
    try {
      await res.pipe(sink);
      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close().catchError((_) {});
      rethrow;
    }
    await _channel.invokeMethod('installApk', apk.path);
  }

  /// 打开下载页 (macOS/Windows 用系统浏览器; 手机上给用户复制链接)。
  static Future<void> openRelease(String url) async {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else {
      await Clipboard.setData(ClipboardData(text: url));
    }
  }
}
