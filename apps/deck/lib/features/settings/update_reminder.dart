import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_update.dart';

/// 全局 navigatorKey: 更新提醒弹窗不依赖任何页面上下文, MaterialApp 挂上
/// 即可随时弹。
final deckNavKey = GlobalKey<NavigatorState>();

/// 版本更新提醒 (2026-10-30): 检查全自动 —— 启动后 8s 静默查一次, 之后每
/// 12h; GitHub 被断是常态, 失败不出声。装不装由人决定: 有新版弹一次
/// 「发现新版本」对话框, Android 可直接下载安装, 其它平台给下载页。
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
/// Android 下载 APK 交给系统安装器; 其它平台打开/复制下载页链接。
Future<void> showUpdateDialog(
    BuildContext context, Map<String, dynamic> info) async {
  final notes = (info['notes'] ?? '').toString().trim();
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
            final apk = (info['apkUrl'] ?? '').toString();
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(ctx).pop();
            // apkUrl 是安卓包; 其它平台就算拿到了也只该去下载页
            if (apk.isEmpty || !Platform.isAndroid) {
              await AppUpdate.openRelease(
                  (info['releaseUrl'] ?? '').toString());
              return;
            }
            messenger.showSnackBar(
                const SnackBar(content: Text('正在下载新版本…')));
            try {
              await AppUpdate.downloadAndInstall(apk);
            } catch (e) {
              messenger.showSnackBar(
                  SnackBar(content: Text('安装未完成: $e')));
            }
          },
          child: Text(Platform.isAndroid ? '下载并安装' : '打开下载页'),
        ),
      ],
    ),
  );
}
