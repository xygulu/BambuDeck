import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';

/// 编辑打印机 (反馈 2026-10-20): 名称, 局域网连接信息 (IP / 访问码 /
/// 序列号)。云端打印机默认只改名, 但补上 IP+访问码即转 LAN 直连 (云同步
/// 只带序列号; 机内摄像头等局域网能力都靠直连, 2026-10-31)。保存即写回
/// profile, ConnectionNotifier 对 profile 的 watch 会自动用新配置重连。
/// 访问码输入框打码, 且不落日志。
Future<void> showEditPrinterDialog(
    BuildContext context, WidgetRef ref, PrinterProfile profile) async {
  final lan = profile.mode == PrinterMode.lan;
  final nameCtrl = TextEditingController(text: profile.name);
  final ipCtrl = TextEditingController(text: profile.ip);
  final codeCtrl = TextEditingController(text: profile.accessCode);
  final serialCtrl = TextEditingController(text: profile.serial);
  var autoPlateSwap = profile.autoPlateSwap;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: Text('编辑打印机 · ${profile.name}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            if (!lan) ...[
              const SizedBox(height: 12),
              Text(
                '云端模式:监控走拓竹云。补上 IP 和访问码即转局域网直连 '
                '(机内画面、秒级控制都靠它)。',
                style: TextStyle(
                    fontSize: 12,
                    color: DeckColors.textSecondary.withValues(alpha: 0.9)),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: ipCtrl,
              decoration: const InputDecoration(
                  labelText: 'IP / 主机', hintText: '192.168.100.110'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: '访问码', hintText: '打印机屏幕 >> 局域网'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: serialCtrl,
              decoration: const InputDecoration(labelText: '序列号'),
            ),
            const SizedBox(height: 4),
            StatefulBuilder(builder: (ctx, setDialogState) {
              return CheckboxListTile(
                value: autoPlateSwap,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('支持自动换盘',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                    '显示「一键换盘」按钮:打印内置换盘模型,热床震动甩下成品并送出打印板(换盘 2026-10-20)',
                    style: TextStyle(fontSize: 11)),
                onChanged: (v) =>
                    setDialogState(() => autoPlateSwap = v ?? false),
              );
            }),
          ]),
        ),
      ),
      // AlertDialog.actions 由 OverflowBar 布局, 只接受按钮: 放 Spacer
      // (Flexible) 会抛 "Incorrect use of ParentDataWidget", 整个对话框
      // 构建失败, 用户只看到一片灰 (反馈 2026-10-25)。删除靠左用
      // spaceBetween + 右侧按钮组实现。
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        // 删除收进编辑对话框 (2026-10-21: 显眼位置易误触), 二次确认后执行。
        TextButton(
          style: TextButton.styleFrom(foregroundColor: DeckColors.error),
          onPressed: () async {
            final yes = await showDialog<bool>(
              context: ctx,
              builder: (dctx) => AlertDialog(
                backgroundColor: DeckColors.surface,
                title: const Text('删除打印机'),
                content: Text('确定删除「${profile.name}」吗?凭据将同时清除。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dctx, false),
                      child: const Text('取消')),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: DeckColors.error),
                    onPressed: () => Navigator.pop(dctx, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            );
            if (yes != true) return;
            await ref.read(printersProvider.notifier).remove(profile.id);
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('删除打印机'),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          const SizedBox(width: 4),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ]),
      ],
    ),
  );
  if (ok != true) return;

  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  PrinterProfile edited(PrinterProfile p) {
    final name = nameCtrl.text.trim();
    final serial = serialCtrl.text.trim();
    final ip = ipCtrl.text.trim();
    final code = codeCtrl.text.trim();
    // 云模式补齐 IP+访问码 → 转 LAN 直连 (两者缺一不可: LAN MQTT
    // 认证用的就是访问码)。
    final toLan =
        p.mode != PrinterMode.lan && ip.isNotEmpty && code.isNotEmpty;
    return PrinterProfile(
      id: p.id,
      name: name.isEmpty ? p.name : name,
      mode: toLan ? PrinterMode.lan : p.mode,
      serial: serial.isEmpty ? p.serial : serial,
      ip: ip,
      accessCode: code,
      region: p.region,
      token: p.token,
      userId: p.userId,
      model: p.model,
      builtinCam: p.builtinCam,
      autoPlateSwap: autoPlateSwap,
      accountId: p.accountId,
      createdAt: p.createdAt,
    );
  }

  await ref.read(printersProvider.notifier).replaceAll([
    for (final p in printers)
      if (p.id == profile.id) edited(p) else p,
  ]);
}
