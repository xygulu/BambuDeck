import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/gh_mirror.dart';
import '../core/version.dart';
import 'log_buffer.dart';

/// GitHub Releases 检查更新 / 自更新 (2026-10-29)。
///
/// 仓库公开, api.github.com 免认证 (必须带 User-Agent)。清单 = Release 里的
/// `version.json` (CI 发布时生成): version + 各资产 url/sha256。下载件 sha256
/// 对不上就删掉放弃 —— 更新链路 fail-closed。
///
/// Windows 自更新三段式:
///   1. `stage()` 下载 zip → 校验 → 解到 `update/pending/` → 返回;
///   2. 调用方 (hub_server) 先把 HTTP 响应发回去, 延迟几秒;
///   3. `exit(42)` → run-hub.cmd 守护循环看到 42 → apply-update.ps1 把
///      pending 覆盖包根 (config/logs/update 不动) → 循环重启 hub.exe。
/// macOS hub 由 launchd KeepAlive 拉起, 同样的 42 退出安全 (v1 mac 只检查,
/// apply 限 Windows 包布局)。
class HubUpdater {
  static const repo = 'xygulu/BambuDeck';
  static const _apiLatest =
      'https://api.github.com/repos/$repo/releases/latest';
  static const _ua = 'BambuDeck-hub';

  static final HttpClient _http = HttpClient()
    ..userAgent = _ua;

  /// 最近一次检查结果缓存 (重复点按钮不打爆 API; 匿名限额 60 次/小时/IP)。
  static Map<String, dynamic>? _last;
  static DateTime? _lastAt;

  static bool get isWindows => Platform.isWindows;

  /// 检查最新版。返回 {current, latest, notes, hasUpdate, checkedAt,
  /// apkUrl, releaseUrl}; 失败抛异常 (调用方展示)。
  /// [force] 跳过 5 分钟缓存。
  static Future<Map<String, dynamic>> check({bool force = false}) async {
    if (!force && _last != null && _lastAt != null &&
        DateTime.now().difference(_lastAt!) < const Duration(minutes: 5)) {
      return _last!;
    }
    final req = await _http.getUrl(Uri.parse(_apiLatest));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw 'GitHub API ${res.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}';
    }
    final rel = jsonDecode(body) as Map<String, dynamic>;
    final tag = (rel['tag_name'] as String?)?.trim() ?? '';
    final assets = (rel['assets'] as List? ?? const []).cast<Map>();
    String? manifestUrl(String name) {
      for (final a in assets) {
        if (a['name'] == name) return a['browser_download_url'] as String?;
      }
      return null;
    }

    // 清单优先 (有 sha256); 没有就直接用 tag 比较, 但 apply 必须有清单。
    Map<String, dynamic>? manifest;
    final mUrl = manifestUrl('version.json');
    if (mUrl != null) {
      try {
        final mreq = await _http.getUrl(Uri.parse(mUrl));
        final mres = await mreq.close().timeout(const Duration(seconds: 20));
        manifest =
            jsonDecode(await mres.transform(utf8.decoder).join())
                as Map<String, dynamic>;
      } catch (_) {
        manifest = null; // 清单拉不到: 检查降级, apply 拒绝
      }
    }
    final latest = (manifest?['version'] as String?) ??
        tag.replaceFirst(RegExp(r'^[vV]'), '');
    String? assetUrl(String key) {
      final a = manifest?['assets'] as Map?;
      return a?[key]?['url'] as String?;
    }

    final releaseUrl =
        'https://github.com/$repo/releases/latest';
    final out = <String, dynamic>{
      'current': deckVersion,
      'latest': latest,
      'notes': (rel['body'] as String?) ?? '',
      'hasUpdate': compareVersions(latest, deckVersion) > 0,
      'checkedAt': DateTime.now().toIso8601String(),
      'apkUrl': assetUrl('android_apk'),
      'releaseUrl': releaseUrl,
      'manifestOk': manifest != null,
    };
    _last = out;
    _lastAt = DateTime.now();
    return out;
  }

  /// Windows: 下载 hub_windows 包 → sha256 校验 → 解到 `update/pending/`。
  /// 成功返回后由调用方延迟 exit(42) 换装。
  /// 其它平台 / 清单缺失 / 校验失败 → 抛异常, 什么都不动 (fail-closed)。
  static Future<void> stage() async {
    if (!isWindows) throw '自更新目前只支持 Windows 部署包 (macOS 请手动替换)';
    final m = await _manifest();
    if (m == null) throw 'Release 缺 version.json 清单, 拒绝更新';
    final latest = (m['version'] as String?)?.trim() ?? '';
    if (latest.isEmpty) throw '清单缺 version 字段';
    if (compareVersions(latest, deckVersion) <= 0) {
      throw '已是最新版 $deckVersion';
    }
    final a = m['assets'] as Map?;
    final hubAsset = a?['hub_windows'] as Map?;
    if (hubAsset == null) throw '清单里没有 hub_windows 资产';
    final url = hubAsset['url'] as String;
    final wantSha = (hubAsset['sha256'] as String).toLowerCase();

    final root = _packageRoot();
    final upd = Directory('$root/update');
    await upd.create(recursive: true);
    final pendingDir = Directory('${upd.path}/pending');
    final zipPath = '${upd.path}/pending.zip';
    if (await pendingDir.exists()) {
      await pendingDir.delete(recursive: true);
    }
    LogBuffer.instance.add('[更新] 下载 v$latest: $url');
    await _download(url, zipPath);

    final got = sha256.convert(await File(zipPath).readAsBytes()).toString();
    if (got != wantSha) {
      await File(zipPath).delete().catchError((_) => File(zipPath));
      throw 'sha256 不符 (期望 $wantSha, 实得 $got), 已删除';
    }
    LogBuffer.instance.add('[更新] sha256 校验通过, 解压暂存');
    // -Command 后面整串当一个脚本执行, 参数不会再被单独引用 —— 路径带空格
    // (C:\Program Files\...) 时必须自己加引号, 所以拼成一条命令再传。
    String q(String s) => "'${s.replaceAll("'", "''")}'";
    final p = await Process.run('powershell', [
      '-NoProfile', '-NonInteractive', '-Command',
      'Expand-Archive -LiteralPath ${q(zipPath)} '
          '-DestinationPath ${q(pendingDir.path)} -Force',
    ]);
    if (p.exitCode != 0) {
      throw '解压失败: ${p.stderr}';
    }
    if (!await File('${pendingDir.path}/hub.exe').exists()) {
      throw '包里没有 hub.exe, 拒绝换装';
    }
    await File('${upd.path}/stage.json').writeAsString(jsonEncode({
      'version': latest,
      'stagedAt': DateTime.now().toIso8601String(),
    }));
    LogBuffer.instance.add('[更新] 已暂存 v$latest, 即将退出换装');
  }

  /// stage() 之后调用: 给 HTTP 响应留几秒, 然后 42 退出交给守护循环。
  static void exitForSwap() {
    Timer(const Duration(seconds: 3), () => exit(42));
  }

  /// 启动时发现上次有暂存没换完 (42 退出但守护脚本没执行成功) → 提示。
  static Future<String?> pendingVersion() async {
    if (!isWindows) return null;
    final f = File('${_packageRoot()}/update/stage.json');
    if (!await f.exists()) return null;
    try {
      return (jsonDecode(await f.readAsString())
          as Map<String, dynamic>)['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  // -- helpers -----------------------------------------------------------

  /// 部署包根 = hub.exe 所在目录 (Windows 包布局: 所有东西都在这下面)。
  static String _packageRoot() =>
      File(Platform.resolvedExecutable).parent.path;

  static Future<Map<String, dynamic>?> _manifest() async {
    // check() 不回传 manifest 全文, 这里直接从 Release 资产再取一次
    // (清单很小; 5 分钟的检查缓存不影响这条路径)。
    final req = await _http.getUrl(Uri.parse(_apiLatest));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    final rel = jsonDecode(await res.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    for (final a in (rel['assets'] as List? ?? const []).cast<Map>()) {
      if (a['name'] == 'version.json') {
        final mreq = await _http.getUrl(
            Uri.parse(a['browser_download_url'] as String));
        final mres = await mreq.close().timeout(const Duration(seconds: 20));
        return jsonDecode(await mres.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      }
    }
    return null;
  }

  static Future<void> _download(String url, String to) async {
    var lastMb = 0;
    const reportEvery = 4 << 20;
    // 直连不通自动换镜像 (国内 Release 资产站会被拦, 见 gh_mirror.dart);
    // 内容真伪仍由清单里的 sha256 判定, 镜像不参与信任。
    await GhMirror.fetch(
      _http,
      url,
      File(to),
      onLog: (m) => LogBuffer.instance.add(m),
      onProgress: (got) {
        final mb = got >> 20;
        if (got % reportEvery < 65536 && mb != lastMb) {
          lastMb = mb;
          LogBuffer.instance.add('[更新] 已下载 $mb MB');
        }
      },
    );
  }
}
