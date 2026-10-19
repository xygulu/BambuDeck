import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/log_buffer.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';

/// Settings center (PRD FR-10, MVP slice): notification switches, run log,
/// config backup via clipboard, about. Theme/accent/i18n land with M5.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).valueOrNull ??
        const AppSettings();
    final notifier = ref.read(appSettingsProvider.notifier);
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: const Text('设置',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _sectionLabel('通知'),
        SwitchListTile(
          title: const Text('打印完成 / 失败'),
          subtitle: const Text('任务结束时弹系统通知', style: TextStyle(fontSize: 12)),
          value: settings.notifyOnFinish,
          onChanged: (v) =>
              notifier.set(settings.copyWith(notifyOnFinish: v)),
        ),
        SwitchListTile(
          title: const Text('打印机报错'),
          subtitle: const Text('HMS/print_error 出现时弹通知,附错误说明',
              style: TextStyle(fontSize: 12)),
          value: settings.notifyOnError,
          onChanged: (v) =>
              notifier.set(settings.copyWith(notifyOnError: v)),
        ),
        const SizedBox(height: 18),
        _sectionLabel('运行日志'),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: const Text('查看运行日志'),
          subtitle: const Text('连接与指令诊断', style: TextStyle(fontSize: 12)),
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LogPage())),
        ),
        const SizedBox(height: 18),
        _sectionLabel('数据备份'),
        ListTile(
          leading: const Icon(Icons.upload_outlined),
          title: const Text('导出配置到剪贴板'),
          subtitle: Text(
              '${printers.length} 台打印机(含凭据,注意保管)',
              style: const TextStyle(fontSize: 12)),
          onTap: printers.isEmpty
              ? null
              : () => _exportConfig(context, printers),
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('从剪贴板导入配置'),
          subtitle: const Text('将替换当前全部打印机配置',
              style: TextStyle(fontSize: 12)),
          onTap: () => _importConfig(context, ref),
        ),
        const SizedBox(height: 18),
        _sectionLabel('关于'),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('BambuDeck'),
          subtitle: Text('拓竹打印机监控套件 · M1 独立客户端\n'
              '错误句表版本 $errorTableVersion',
              style: const TextStyle(fontSize: 12)),
          isThreeLine: true,
        ),
      ]),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: DeckColors.textSecondary)),
      );

  Future<void> _exportConfig(
      BuildContext context, List<PrinterProfile> printers) async {
    final json = const JsonEncoder.withIndent('  ')
        .convert(printers.map((p) => p.toJson()).toList());
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已复制 ${printers.length} 台打印机的配置 JSON'),
      ));
    }
  }

  Future<void> _importConfig(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入配置'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('粘贴之前导出的配置 JSON。将替换当前全部打印机!',
              style: TextStyle(fontSize: 13)),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            maxLines: 6,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(hintText: '[ {...}, ... ]'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final raw = jsonDecode(ctrl.text) as List;
      final printers = raw
          .whereType<Map<String, dynamic>>()
          .map(PrinterProfile.fromJson)
          .toList();
      await ref.read(printersProvider.notifier).replaceAll(printers);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导入 ${printers.length} 台打印机')));
      }
    } on FormatException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('JSON 解析失败,请检查粘贴内容')));
      }
    }
  }
}

/// Run log: connection diagnostics + command traces (ring buffer).
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final log = LogBuffer.instance;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: const Text('运行日志',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制全部',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: log.dump()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制全部日志')));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空',
            onPressed: log.clear,
          ),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: log.lines,
        builder: (context, lines, _) => lines.isEmpty
            ? const Center(
                child: Text('暂无日志',
                    style: TextStyle(color: DeckColors.textSecondary)))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: lines.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(lines[i],
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: DeckColors.textSecondary)),
                ),
              ),
      ),
    );
  }
}
