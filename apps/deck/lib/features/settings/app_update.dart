import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../core/gh_mirror.dart';
import '../../core/version.dart';

/// App 自更新检查 (2026-10-29; 2026-10-31 桌面端自动换装)。
///
/// 查 GitHub Releases (仓库公开, api.github.com 免认证)。三个平台的处理:
///   Android  下载 APK → 交给系统安装器 (FileProvider + MethodChannel);
///   macOS    下载 deck-macos.zip → sha256 校验 → 退出换包 → 自动重启;
///   Windows  下载 deck-windows.zip → 同上 (bat 换包);
///   iOS      只提示 + 给链接。
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

  /// 检查更新 -> {current, latest, hasUpdate, notes, apkUrl, macUrl, winUrl,
  /// macSha, winSha, releaseUrl}
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

    String? apkUrl, macUrl, winUrl, macSha, winSha;
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
          macUrl = assets?['macos']?['url'] as String?;
          macSha = assets?['macos']?['sha256'] as String?;
          winUrl = assets?['windows_app']?['url'] as String?;
          winSha = assets?['windows_app']?['sha256'] as String?;
        } catch (_) {
          apkUrl = null;
        }
      }
      // 清单拉不到时退化到资产名直查 (没有 sha256, 下载后只做大小检查)。
      if (a['name'] == 'deck-android.apk') {
        apkUrl ??= a['browser_download_url'] as String?;
      }
      if (a['name'] == 'deck-macos.zip') {
        macUrl ??= a['browser_download_url'] as String?;
      }
      if (a['name'] == 'deck-windows.zip') {
        winUrl ??= a['browser_download_url'] as String?;
      }
    }
    final ver = manifestVersion.isNotEmpty ? manifestVersion : latest;
    return <String, dynamic>{
      'current': deckVersion,
      'latest': ver,
      'hasUpdate': compareVersions(ver, deckVersion) > 0,
      'notes': (rel['body'] as String?) ?? '',
      'apkUrl': apkUrl,
      'macUrl': macUrl,
      'macSha': macSha,
      'winUrl': winUrl,
      'winSha': winSha,
      'releaseUrl': 'https://github.com/$repo/releases/latest',
    };
  }

  /// Android: 下载 APK 到缓存目录, 交给系统安装器。
  /// 非 Android 抛异常 (调用方改成给下载链接)。
  static Future<void> downloadAndInstall(String url) async {
    if (!Platform.isAndroid) {
      throw '当前平台不支持自动安装, 请手动下载';
    }
    // 不引 path_provider: dart:io 的 systemTemp 在 Android 上就是 app 的
    // 缓存目录 (/data/user/0/<包名>/cache), 安装器通过 FileProvider 能读。
    final dir = Directory.systemTemp;
    if (!await dir.exists()) await dir.create(recursive: true);
    final apk = File('${dir.path}/deck-update.apk');
    // 直连不通自动换镜像 (国内 Release 资产站会被拦, 见 gh_mirror.dart)。
    await GhMirror.fetch(_client, url, apk);
    await _channel.invokeMethod('installApk', apk.path);
  }

  /// 桌面端: 下载新版包到 `~/.bambudeck/update/` 并按清单 sha256 校验。
  /// 成功返回暂存包, 之后 [applyDesktopStaged] 换包重启。
  static Future<File> downloadDesktopPackage(
    String url,
    String? wantSha, {
    void Function(String msg)? onLog,
  }) async {
    final stage = await _stageDir();
    final out = File(
        '${stage.path}/${Platform.isMacOS ? 'deck-macos.zip' : 'deck-windows.zip'}');
    await GhMirror.fetch(_client, url, out, onLog: onLog);
    if (wantSha != null && wantSha.isNotEmpty) {
      final got = sha256.convert(await out.readAsBytes()).toString();
      if (got != wantSha.toLowerCase()) {
        try {
          await out.delete();
        } catch (_) {}
        throw '新版本包校验不对 (sha256), 已放弃更新';
      }
    }
    return out;
  }

  /// 桌面端: 起一个 detached 换包脚本 → 本进程退出 → 脚本等它死透后
  /// 解压覆盖安装位置并重新拉起。换包过程写 `update.log` 进暂存目录。
  static Future<void> applyDesktopStaged(File zip) async {
    final stage = zip.parent;
    if (Platform.isMacOS) {
      final script =
          await _writeScript(stage, 'apply-update.sh', _macScript, '\n');
      await Process.start('bash', [
        script.path,
        zip.path,
        _macAppBundle(),
        '${stage.path}/update.log',
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isWindows) {
      final script = await _writeScript(
          stage, 'apply-update.cmd', _winScript, '\r\n');
      await Process.start('cmd', ['/c', script.path, zip.path,
        File(Platform.resolvedExecutable).parent.path,
        '${stage.path}/update.log',
      ], mode: ProcessStartMode.detached);
    } else {
      throw '当前平台不支持自动更新';
    }
    // 给脚本落地时间再退, 别让父进程的退出连坐子进程。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
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

  // ---- 内部 ------------------------------------------------------------

  static Future<Directory> _stageDir() async {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    final d = Directory('$home/.bambudeck/update');
    await d.create(recursive: true);
    return d;
  }

  /// resolvedExecutable 往上找到 `.app` 目录 (找不到就说明结构变了, 拒绝换包)。
  static String _macAppBundle() {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 6; i++) {
      if (dir.path.endsWith('.app')) return dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    throw '找不到 .app 安装位置 (${Platform.resolvedExecutable})';
  }

  static Future<File> _writeScript(
      Directory dir, String name, String content, String eol) async {
    final f = File('${dir.path}/$name');
    await f.writeAsString(
        content.replaceAll('\n', eol), encoding: utf8, flush: true);
    return f;
  }

  /// macOS 换包脚本: 旧 .app 先挪到 .bak, 拷入新的成功才删 .bak;
  /// 失败把旧的挪回来, 永远不出现「删了新的又没装上」。
  static const _macScript = '''
#!/bin/bash
ZIP="\$1"
BUNDLE="\$2"
LOG="\$3"
{
  echo "\$(date '+%F %T') apply-update start"
  TMP="\${ZIP%.zip}.unzipped"
  rm -rf "\$TMP"
  mkdir -p "\$TMP"
  if ! unzip -oq "\$ZIP" -d "\$TMP"; then echo "unzip failed"; exit 3; fi
  APP="\$(find "\$TMP" -maxdepth 2 -name '*.app' -print | head -1)"
  if [ -z "\$APP" ]; then echo "no .app in zip"; exit 4; fi
  xattr -dr com.apple.quarantine "\$APP" 2>/dev/null || true
  mv "\$BUNDLE" "\$BUNDLE.bak" 2>/dev/null || true
  if cp -R "\$APP" "\$BUNDLE"; then
    rm -rf "\$BUNDLE.bak"
    rm -rf "\$TMP" "\$ZIP"
    echo "\$(date '+%F %T') relaunch"
    open "\$BUNDLE"
  else
    echo "copy failed, restoring old bundle"
    mv "\$BUNDLE.bak" "\$BUNDLE" 2>/dev/null || true
    exit 5
  fi
} >> "\$LOG" 2>&1
''';

  /// Windows 换包脚本: 等 exe 退出 → Expand-Archive → robocopy 覆盖
  /// (失败重试 5 次, exe 文件锁释放有延迟) → 重新启动。bat 必须 CRLF。
  static const _winScript = '''
@echo off
setlocal enabledelayedexpansion
set "ZIP=%~1"
set "INSTALL=%~2"
set "LOG=%~3"
echo %date% %time% apply-update start >> "%LOG%"
ping -n 3 127.0.0.1 >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Force -LiteralPath '%ZIP%' -DestinationPath '%ZIP%.unzipped'" >> "%LOG%" 2>&1
if errorlevel 1 (
  echo expand failed >> "%LOG%"
  exit /b 3
)
set "SRC=%ZIP%.unzipped"
if not exist "%SRC%\\deck.exe" (
  for /d %%D in ("%SRC%\\*") do if exist "%%D\\deck.exe" set "SRC=%%D"
)
set /a tries=0
:copyloop
robocopy "%SRC%" "%INSTALL%" /E /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1
if errorlevel 8 (
  set /a tries+=1
  if !tries! GEQ 5 (
    echo copy failed >> "%LOG%"
    exit /b 4
  )
  ping -n 3 127.0.0.1 >nul
  goto copyloop
)
rmdir /s /q "%SRC%" >> "%LOG%" 2>&1
del /q "%ZIP%" >> "%LOG%" 2>&1
echo %date% %time% relaunch >> "%LOG%"
start "" "%INSTALL%\\deck.exe"
exit /b 0
''';
}
