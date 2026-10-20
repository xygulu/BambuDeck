import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/camera_profile.dart';
import '../../data/log_buffer.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/vision_guard.dart';
import '../../data/vision_llm.dart';

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
        _sectionLabel('摄像头'),
        SwitchListTile(
          title: const Text('机内摄像头默认开启'),
          subtitle: const Text('点击打印机后自动加载机内画面;'
              '每台打印机可在监控画面的「机内画面」开关或「绑定摄像头」里单独覆盖',
              style: TextStyle(fontSize: 12)),
          value: settings.builtinCamDefault,
          onChanged: (v) =>
              notifier.set(settings.copyWith(builtinCamDefault: v)),
        ),
        _visionSection(context, ref, settings, notifier),
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

  /// 视觉监控 (大模型识别监控画面 2026-10-20): any OpenAI-compatible vision
  /// endpoint watches printing cameras on an interval; findings notify and
  /// may auto-pause.「测试判读」 grabs the first visible camera once and
  /// shows the verdict inline.
  Widget _visionSection(BuildContext context, WidgetRef ref,
      AppSettings settings, AppSettingsNotifier notifier) {
    final baseCtrl = TextEditingController(text: settings.visionBaseUrl);
    final keyCtrl = TextEditingController(text: settings.visionApiKey);
    final modelCtrl = TextEditingController(text: settings.visionModel);
    var testing = false;
    String? testResult;
    return StatefulBuilder(builder: (context, setState) {
      Future<void> save(AppSettings s) => notifier.set(s);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 18),
        _sectionLabel('视觉监控(大模型判读)'),
        SwitchListTile(
          title: const Text('启用视觉监控'),
          subtitle: const Text('打印进行中时定时抓取绑定摄像头画面交给视觉大模型判读;'
              '发现炒面/空打等异常弹通知', style: TextStyle(fontSize: 12)),
          value: settings.visionEnabled,
          onChanged: (v) => save(settings.copyWith(visionEnabled: v)),
        ),
        SwitchListTile(
          title: const Text('异常时自动暂停'),
          subtitle: const Text('判读为疑似炒面/空打时自动发送暂停(默认只通知)',
              style: TextStyle(fontSize: 12)),
          value: settings.visionAutoPause,
          onChanged: (v) => save(settings.copyWith(visionAutoPause: v)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            TextField(
              controller: baseCtrl,
              decoration: const InputDecoration(
                  labelText: 'API 地址(含 /v1 段)',
                  hintText: 'https://open.bigmodel.cn/api/paas/v4'),
              onChanged: (v) => save(settings.copyWith(visionBaseUrl: v.trim())),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration:
                      const InputDecoration(labelText: 'API Key'),
                  onChanged: (v) =>
                      save(settings.copyWith(visionApiKey: v.trim())),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: modelCtrl,
                  decoration: const InputDecoration(
                      labelText: '模型', hintText: 'glm-4v-flash'),
                  onChanged: (v) =>
                      save(settings.copyWith(visionModel: v.trim())),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Text('判读间隔',
                  style: TextStyle(
                      fontSize: 12, color: DeckColors.textSecondary)),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 30, label: Text('30秒')),
                    ButtonSegment(value: 60, label: Text('1分钟')),
                    ButtonSegment(value: 120, label: Text('2分钟')),
                    ButtonSegment(value: 300, label: Text('5分钟')),
                  ],
                  selected: {settings.visionIntervalSec},
                  onSelectionChanged: (s) =>
                      save(settings.copyWith(visionIntervalSec: s.first)),
                  style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle:
                          WidgetStatePropertyAll(TextStyle(fontSize: 11))),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: testing
                    ? null
                    : () async {
                        setState(() {
                          testing = true;
                          testResult = null;
                        });
                        final result =
                            await testVisionNow(ref, settings);
                        if (context.mounted) {
                          setState(() {
                            testing = false;
                            testResult = result;
                          });
                        }
                      },
                icon: testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.visibility_outlined, size: 16),
                label: const Text('测试判读'),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: const Text(
                  '仅打印进行中时运行;glm-4v-flash 免费',
                  style: TextStyle(
                      fontSize: 11, color: DeckColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            if (testResult != null) ...[
              const SizedBox(height: 6),
              Text(testResult!,
                  style: TextStyle(
                      fontSize: 12,
                      color: testResult!.startsWith('✅')
                          ? Colors.green
                          : DeckColors.error)),
            ],
          ]),
        ),
      ]);
    });
  }

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

/// One-shot 视觉判读 test: grabs the first mounted camera frame and asks
/// the configured model. Returns a human line prefixed ✅/❌/⚠ for the
/// inline result label.
Future<String> testVisionNow(WidgetRef ref, AppSettings settings) async {
  final cameras = ref.read(camerasProvider).valueOrNull ?? const [];
  if (cameras.isEmpty) return '❌ 没有已配置的摄像头';
  for (final c in cameras) {
    final png = await frameRegistry.grab(c.id);
    if (png == null) continue;
    final client = VisionLlmClient(
      baseUrl: settings.visionBaseUrl,
      apiKey: settings.visionApiKey,
      model: settings.visionModel,
      log: LogBuffer.instance.add,
    );
    final reply = await client.analyzeFrame(png);
    final verdict = reply == null ? null : parseVisionVerdict(reply);
    if (verdict == null) {
      return '❌ 判读失败(检查 API 地址 / Key / 模型,详情见运行日志)';
    }
    final abnormal = verdict.isAbnormal ? '⚠ 异常:${verdict.abnormal}' : '✅ 画面正常';
    return '$abnormal · 平台物体=${verdict.platformHasObject} · '
        '打印中=${verdict.printRunning}\n${verdict.notes}';
  }
  return '❌ 没有可抓取的画面(对应摄像头的监控页未显示?)';
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
