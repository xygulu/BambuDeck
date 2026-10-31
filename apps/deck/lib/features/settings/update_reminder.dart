import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';

/// 全局 navigatorKey: 更新提醒弹窗不依赖任何页面上下文, MaterialApp 挂上
/// 即可随时弹。
final deckNavKey = GlobalKey<NavigatorState>();

/// 版本更新提醒 (2026-10-30): 检查全自动 —— 启动后 8s 静默查一次, 之后每
/// 12h; GitHub 被断是常态, 失败不出声。装不装由人决定: 有新版弹一次
/// 「发现新版本」对话框, Android 直接装 APK, 桌面端下载后重启换包。
class UpdateReminder {
  static Timer? _retry;
  static bool _checking = false;
  static String? _reminded;

  static void start() {
    Timer(const Duration(seconds: 8), _check);
    Timer.periodic(const Duration(hours: 12), (_) => _check());
  }

  static Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      final info = await AppUpdate.check();
      if (info['hasUpdate'] != true) return;
      final latest = '${info['latest'] ?? ''}';
      if (latest.isEmpty || latest == _reminded) return;
      final ctx = deckNavKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        // 首帧还没起来 (冷启动慢): 稍后重试, 别把这一版漏掉
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 30), _check);
        return;
      }
      _reminded = latest;
      await showUpdateDialog(ctx, info);
    } catch (_) {
      // 检查失败静默; 设置页的「检查更新」会把错误说给人听
    } finally {
      _checking = false;
    }
  }
}

/// 「发现新版本」对话框: 设置页「检查更新」与全局提醒共用。
/// Android 下载 APK 交给系统安装器; 桌面端 (macOS/Windows) 下载整包后
/// 重启换包; iOS 或拿不到包地址时给下载页链接。
Future<void> showUpdateDialog(
    BuildContext context, Map<String, dynamic> info) async {
  final notes = (info['notes'] ?? '').toString().trim();
  final desktopUrl = Platform.isMacOS
      ? (info['macUrl'] ?? '').toString()
      : Platform.isWindows
          ? (info['winUrl'] ?? '').toString()
          : '';
  final desktopSha = Platform.isMacOS
      ? (info['macSha'] ?? '').toString()
      : (info['winSha'] ?? '').toString();
  final canAuto = Platform.isAndroid
      ? (info['apkUrl'] ?? '').toString().isNotEmpty
      : desktopUrl.isNotEmpty;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('发现新版本 ${info['latest']}'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前版本 ${info['current'] ?? ''}'),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(notes, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(ctx).pop();
            if (!canAuto) {
              await AppUpdate.openRelease(
                  (info['releaseUrl'] ?? '').toString());
              return;
            }
            if (Platform.isAndroid) {
              messenger.showSnackBar(
                  const SnackBar(content: Text('正在下载新版本…')));
              try {
                await AppUpdate.downloadAndInstall(
                    (info['apkUrl'] ?? '').toString());
              } catch (e) {
                messenger.showSnackBar(
                    SnackBar(content: Text('安装未完成: $e')));
              }
              return;
            }
            await _desktopUpdateFlow(context, info, desktopUrl, desktopSha);
          },
          child: Text(canAuto ? '下载并自动更新' : '打开下载页'),
        ),
      ],
    ),
  );
}

/// 桌面端更新流: 下载 (带进度提示) → 就绪后确认 → 退出换包重启。
Future<void> _desktopUpdateFlow(BuildContext context,
    Map<String, dynamic> info, String url, String sha) async {
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      title: Text('正在下载新版本…'),
      content: Text('下载完成后会询问是否重启更新。'),
    ),
  );
  final File zip;
  try {
    zip = await AppUpdate.downloadDesktopPackage(
        url, sha.isEmpty ? null : sha);
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(content: Text('下载失败: $e')));
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新版本已就绪'),
      content: const Text('重启应用完成更新。更新期间应用会关闭几秒,'
          '之后自动重新打开。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('稍后重启'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('重启更新'),
        ),
      ],
    ),
  );
  if (go != true) return;
  messenger.showSnackBar(const SnackBar(content: Text('正在退出并换包…')));
  try {
    await AppUpdate.applyDesktopStaged(zip);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('换包未完成: $e')));
  }
}
