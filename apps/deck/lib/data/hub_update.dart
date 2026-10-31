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
/// macOS 同样 42 退出安全: launchd KeepAlive=true 无条件拉起。差别在换装
/// 时机 —— macOS 允许 rename 正在运行的可执行文件, 所以 `stage()` 里就
/// **原地换好** bin/hub (旧进程继续用旧 inode, 服务不中断), 之后 42 退出
/// 让 launchd 直接跑新文件; 42 之前进程被杀也一样, 磁盘上已经是新版。
class HubUpdater {
  static const repo = 'xygulu/BambuDeck';
  static const _apiLatest =
      'https://api.github.com/repos/$repo/releases/latest';
  static const _ua = 'BambuDeck-hub';

  /// 网页端「下载安装包」清单 (2026-10-31): 文件名 -> (展示名, MIME)。
  /// `/dl/<file>` 代下路由与页面下载区共用这张表。
  static const packages = <String, (String, String)>{
    'deck-android.apk': ('Android 客户端 APK',
        'application/vnd.android.package-archive'),
    'deck-macos.zip': ('macOS 客户端', 'application/zip'),
    'deck-windows.zip': ('Windows 客户端', 'application/zip'),
    'deck-hub-windows.zip': ('Windows Hub 部署包', 'application/zip'),
    'deck-hub-macos.zip': ('macOS Hub 服务包', 'application/zip'),
  };

  /// 路由层代下 Release 资产用 (镜像候选由 GhMirror 出, 这里只管客户端)。
  static HttpClient get httpClient => _http;

  /// 2026-10-29 盒子+Mac 实测: GitHub 被断时 TLS 握手挂 5-20s+, 20s 超时
  /// 叠加清单二次拉取能把一个「检查更新」拖到 40s+, 隧道侧直接 524。
  /// 8s 快速失败 + 重定向兜底。
  static const _timeout = Duration(seconds: 8);

  static final HttpClient _http = HttpClient()
    ..userAgent = _ua;

  /// GET 一个 URL, 非 200 抛错; [noRedirect] 时 30x 也原样返回。
  static Future<(int, String, String)> _get(String url,
      {bool noRedirect = false}) async {
    final req = await _http.openUrl('GET', Uri.parse(url));
    if (noRedirect) req.followRedirects = false;
    final res = await req.close().timeout(_timeout);
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body, res.headers.value('location') ?? '');
  }

  /// api.github.com 不可达时的兜底: `github.com/<repo>/releases/latest`
  /// 会 302 到 `/releases/tag/<tag>`, Location 末段就是最新 tag —— 不用
  /// JSON, 且 github.com 与 api.github.com 被断的时段经常错开。失败返回 ''。
  static Future<String> _latestTagViaRedirect() async {
    try {
      final (code, _, loc) = await _get(
          'https://github.com/$repo/releases/latest',
          noRedirect: true);
      if (code >= 300 && code < 400) {
        final m = RegExp(r'/releases/tag/([^/?#]+)$').firstMatch(loc);
        return m?[1] ?? '';
      }
    } catch (_) {}
    return '';
  }

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
    String body;
    String tag;
    try {
      final res = await req.close().timeout(_timeout);
      body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw 'GitHub API ${res.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}';
      }
      final rel = jsonDecode(body) as Map<String, dynamic>;
      tag = (rel['tag_name'] as String?)?.trim() ?? '';
    } catch (e) {
      // api 不通 -> 302 兜底 (只拿得到 tag, notes/资产清单降级为空)
      tag = await _latestTagViaRedirect();
      if (tag.isEmpty) {
        throw 'GitHub API 不可达: $e';
      }
      body = '';
    }
    final rel = body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    final assets = (rel['assets'] as List? ?? const []).cast<Map>();
    String? manifestUrl(String name) {
      for (final a in assets) {
        if (a['name'] == name) return a['browser_download_url'] as String?;
      }
      return null;
    }

    // 清单优先 (有 sha256); 没有就直接用 tag 比较, 但 apply 必须有清单。
    // 清单是 github.com 的 release 资产 (被墙重灾区), 直连失败按
    // GhMirror 的镜像顺序重试 (内容真伪由 sha256 把关, 镜像不参与信任)。
    Future<Map<String, dynamic>?> fetchManifest(String url) async {
      for (final u in GhMirror.candidates(url)) {
        try {
          final (code, body, _) = await _get(u);
          if (code == 200) {
            return jsonDecode(body) as Map<String, dynamic>;
          }
        } catch (_) {}
      }
      return null;
    }

    Map<String, dynamic>? manifest;
    final mUrl = manifestUrl('version.json');
    if (mUrl != null) {
      // 清单拉不到: 检查降级, apply 拒绝 (fail-closed)
      manifest = await fetchManifest(mUrl);
    }
    final latest = (manifest?['version'] as String?) ??
        tag.replaceFirst(RegExp(r'^[vV]'), '');
    String? assetUrl(String key) {
      final a = manifest?['assets'] as Map?;
      return a?[key]?['url'] as String?;
    }

    // 网页端「下载安装包」(2026-10-31): 清单带 url+size 就用清单, 没有清单
    // 退化到 Release 资产名直查 (没有 size)。键是文件名, /dl/<file> 直接用。
    final dlUrl = <String, String>{};
    final dlSize = <String, int>{};
    (manifest?['assets'] as Map?)?.forEach((k, v) {
      if (v is! Map) return;
      final f = (v['file'] as String?) ?? '';
      final u = (v['url'] as String?) ?? '';
      if (packages.containsKey(f) && u.isNotEmpty) {
        dlUrl[f] = u;
        if (v['size'] is int) dlSize[f] = v['size'] as int;
      }
    });
    for (final a in assets) {
      final n = a['name'] as String?;
      if (n != null && packages.containsKey(n) && !dlUrl.containsKey(n)) {
        final u = a['browser_download_url'] as String?;
        if (u != null) dlUrl[n] = u;
      }
    }
    final downloads = <Map<String, dynamic>>[
      for (final e in packages.entries)
        if (dlUrl.containsKey(e.key))
          {
            'file': e.key,
            'label': e.value.$1,
            if (dlSize.containsKey(e.key)) 'size': dlSize[e.key],
          },
    ];

    final releaseUrl =
        'https://github.com/$repo/releases/latest';
    final out = <String, dynamic>{
      'current': deckVersionRuntime,
      'latest': latest,
      'notes': (rel['body'] as String?) ?? '',
      'hasUpdate': compareVersions(latest, deckVersionRuntime) > 0,
      'checkedAt': DateTime.now().toIso8601String(),
      'apkUrl': assetUrl('android_apk'),
      'releaseUrl': releaseUrl,
      'assets': dlUrl,
      'downloads': downloads,
      'manifestOk': manifest != null,
    };
    _last = out;
    _lastAt = DateTime.now();
    return out;
  }

  /// 下载当前平台的 hub 包 → sha256 校验 → Windows 解到 `update/pending/`
  /// / macOS 原地换好 bin/hub。成功返回后由调用方延迟 exit(42), 由各自的
  /// 守护者 (run-hub.cmd / launchd KeepAlive) 拉起新版。
  /// 清单缺失 / 校验失败 → 抛异常, 什么都不动 (fail-closed)。
  static Future<void> stage() async {
    final m = await _manifest();
    if (m == null) throw 'Release 缺 version.json 清单, 拒绝更新';
    final latest = (m['version'] as String?)?.trim() ?? '';
    if (latest.isEmpty) throw '清单缺 version 字段';
    if (compareVersions(latest, deckVersionRuntime) <= 0) {
      throw '已是最新版 $deckVersionRuntime';
    }
    final a = m['assets'] as Map?;
    final assetKey = isWindows ? 'hub_windows' : 'hub_macos';
    final hubAsset = a?[assetKey] as Map?;
    if (hubAsset == null) throw '清单里没有 $assetKey 资产';
    final url = hubAsset['url'] as String;
    final wantSha = (hubAsset['sha256'] as String).toLowerCase();

    final root = isWindows ? _packageRoot() : _bundleRoot();
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
    LogBuffer.instance.add('[更新] sha256 校验通过');

    if (isWindows) {
      LogBuffer.instance.add('[更新] 解压暂存');
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
    } else {
      await _applyMacos(zipPath, latest);
    }
  }

  /// macOS 换装: 解包后**先原地换好 bin/hub**再返回。macOS 允许 rename
  /// 正在运行的可执行文件 —— 旧进程继续用旧 inode 服务不受影响; 随后调用
  /// 方 exit(42), launchd KeepAlive 直接拉起新文件。就算 42 之前进程被杀,
  /// 磁盘上也已经是新版, 不会「换装失败服务起不来」。换失败会把旧的挪回。
  static Future<void> _applyMacos(String zipPath, String latest) async {
    final bundle = _bundleRoot();
    final upd = '$bundle/update';
    // 解包到 update/pending (zip 根目录是 deck-hub-macos/)
    final uz = await Process.run(
        '/usr/bin/unzip', ['-oq', zipPath, '-d', '$upd/pending']);
    if (uz.exitCode != 0) {
      throw '解压失败: ${uz.stderr}';
    }
    String q(String s) => "'${s.replaceAll("'", "'\\''")}'";
    final script = '''
set -e
cd ${q(bundle)}
[ -d update/pending ] || exit 9
[ -f update/pending/deck-hub-macos/bin/hub ] || exit 10
mv bin/hub update/hub.old
if ! mv update/pending/deck-hub-macos/bin/hub bin/hub; then
  mv update/hub.old bin/hub
  exit 11
fi
chmod 755 bin/hub
if [ -d update/pending/deck-hub-macos/lib ]; then
  rm -rf update/lib.old
  if [ -d lib ]; then mv lib update/lib.old; fi
  mv update/pending/deck-hub-macos/lib lib
fi
printf '%s' '$latest' > bin/version.txt
rm -rf update/pending
''';
    final p = await Process.run('/bin/bash', ['-c', script]);
    if (p.exitCode != 0) {
      throw '换装失败 (${p.exitCode}): ${p.stderr}';
    }
    await File('$upd/stage.json').writeAsString(jsonEncode({
      'version': latest,
      'stagedAt': DateTime.now().toIso8601String(),
    }));
    LogBuffer.instance.add('[更新] 已换装 v$latest, 即将重启生效');
  }

  /// macOS 部署根 = bin/hub 的上一级 (~/.bambudeck/bin/deck_hub_bundle)。
  static String _bundleRoot() =>
      File(Platform.resolvedExecutable).parent.parent.path;

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
    // (清单很小; 5 分钟的检查缓存不影响这条路径)。api 不通时用 302
    // 兜底拿 tag 再走镜像试清单 —— apply 本来就要求清单, 拿不到就拒绝。
    Map<String, dynamic>? rel;
    try {
      final (code, body, _) = await _get(_apiLatest);
      if (code == 200) {
        rel = jsonDecode(body) as Map<String, dynamic>;
      }
    } catch (_) {}
    if (rel == null) return null;
    for (final a in (rel['assets'] as List? ?? const []).cast<Map>()) {
      if (a['name'] == 'version.json') {
        final url = a['browser_download_url'] as String;
        for (final u in GhMirror.candidates(url)) {
          try {
            final (code, body, _) = await _get(u);
            if (code == 200) {
              return jsonDecode(body) as Map<String, dynamic>;
            }
          } catch (_) {}
        }
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
