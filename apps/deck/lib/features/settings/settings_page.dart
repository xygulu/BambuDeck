import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/version.dart';
import '../../data/app_settings.dart';
import '../../data/camera_providers.dart';
import '../../data/cloud_print_helper.dart';
import '../../data/hcnetsdk.dart' show detectLocalIpv4;
import '../../data/hub_server.dart';
import '../../data/log_buffer.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/settings_providers.dart';
import '../../data/vision_guard.dart';
import '../../data/vision_llm.dart';
import 'app_update.dart';

/// Settings center (PRD FR-10, MVP slice): notification switches, run log,
/// config backup via clipboard, about. Theme/accent/i18n land with M5.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  // 文本输入的 controller 必须跨 build 存活：旧实现每次 build 都新建
  // TextEditingController，而 onChanged 又即时保存 → 每敲一个字就触发 provider
  // 更新 → 整页重建 → controller 被替换，光标跳回末尾、输入法合成被打断，
  // 表现为「输一个字就刷新、字符乱序」。这里提升到 State，只在首次初始化。
  late final _visionBase = TextEditingController();
  late final _visionKey = TextEditingController();
  late final _visionModel = TextEditingController();
  late final _visionFallbackBase = TextEditingController();
  late final _visionFallbackKey = TextEditingController();
  late final _visionFallbackModel = TextEditingController();
  late final _helperUrl = TextEditingController();
  late final _helperToken = TextEditingController();
  late final _hubPort = TextEditingController();
  late final _hubToken = TextEditingController();
  bool _ctrlsInit = false;

  void _initCtrls(AppSettings s) {
    if (_ctrlsInit) return;
    _visionBase.text = s.visionBaseUrl;
    _visionKey.text = s.visionApiKey;
    _visionModel.text = s.visionModel;
    _visionFallbackBase.text = s.visionFallbackBaseUrl;
    _visionFallbackKey.text = s.visionFallbackApiKey;
    _visionFallbackModel.text = s.visionFallbackModel;
    _helperUrl.text = s.helperUrl;
    _helperToken.text = s.helperToken;
    _hubPort.text = '${s.hubPort}';
    _hubToken.text = s.hubToken;
    _ctrlsInit = true;
  }

  @override
  void dispose() {
    _visionBase.dispose();
    _visionKey.dispose();
    _visionModel.dispose();
    _visionFallbackBase.dispose();
    _visionFallbackKey.dispose();
    _visionFallbackModel.dispose();
    _helperUrl.dispose();
    _helperToken.dispose();
    _hubPort.dispose();
    _hubToken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).valueOrNull ??
        const AppSettings();
    _initCtrls(settings);
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
        _hubSection(context, ref, settings, notifier),
        _serviceSection(context, ref, settings, notifier),
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
              '版本 $deckVersion · 错误句表版本 $errorTableVersion',
              style: const TextStyle(fontSize: 12)),
          isThreeLine: true,
        ),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('检查更新'),
          subtitle: const Text('从 GitHub Releases 检查新版本 (Android 可直接装)',
              style: TextStyle(fontSize: 12)),
          onTap: () => _checkUpdate(context),
        ),
      ]),
    );
  }

  /// 检查更新 → 有新版就弹更新说明 (Android 直接下载安装; 其它平台给链接)。
  Future<void> _checkUpdate(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        title: Text('检查更新'),
        content: Text('正在检查…'),
      ),
    );
    try {
      final info = await AppUpdate.check();
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      final has = info['hasUpdate'] == true;
      if (!has) {
        messenger.showSnackBar(SnackBar(
            content: Text('已是最新版本 ${info['current'] ?? deckVersion}')));
        return;
      }
      await _showUpdateDialog(context, info);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      messenger.showSnackBar(SnackBar(content: Text('检查更新失败: $e')));
    }
  }

  Future<void> _showUpdateDialog(
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
              Text('当前版本 ${info['current'] ?? deckVersion}'),
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
              if (apk.isEmpty) {
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
            child: const Text('下载并安装'),
          ),
        ],
      ),
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
              controller: _visionBase,
              decoration: const InputDecoration(
                  labelText: 'API 地址(含 /v1 段)',
                  hintText: 'https://open.bigmodel.cn/api/paas/v4',
                  helperText: 'OpenAI 接口填到 /v1 或 /v4 为止;MiniMax 这类 '
                      'Anthropic 兼容接口填 …/anthropic 即可,会自动走 /v1/messages',
                  helperMaxLines: 2),
              onChanged: (v) => save(settings.copyWith(visionBaseUrl: v.trim())),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _visionKey,
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
                  controller: _visionModel,
                  decoration: const InputDecoration(
                      labelText: '模型', hintText: 'glm-4v-flash'),
                  onChanged: (v) =>
                      save(settings.copyWith(visionModel: v.trim())),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            // 备用视觉模型 (2026-10-29): 主用配额用完/超时/网关挂了时自动
            // 换这一条。默认留给阿里云百炼 —— 和智谱不是同一家，一边出事
            // 另一边通常还在。Key 留空 = 不启用。
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                settings.visionFallbackApiKey.isEmpty
                    ? '备用视觉模型（未启用）'
                    : '备用视觉模型：${settings.visionFallbackModel}',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: const Text('主用不可用时自动改用这一条，失败原因见运行日志',
                  style: TextStyle(fontSize: 11)),
              children: [
                TextField(
                  controller: _visionFallbackBase,
                  decoration: const InputDecoration(
                      labelText: '备用 API 地址',
                      hintText: 'https://token-plan.cn-beijing.maas.aliyuncs.com'
                          '/compatible-mode/v1',
                      helperText: '百炼「Token Plan」的 key 是 sk-sp- 开头, 只能配'
                          '这个北京端点; 按量付费的 sk- key 用 '
                          'https://dashscope.aliyuncs.com/compatible-mode/v1',
                      helperMaxLines: 2),
                  onChanged: (v) => save(
                      settings.copyWith(visionFallbackBaseUrl: v.trim())),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _visionFallbackKey,
                      obscureText: true,
                      decoration:
                          const InputDecoration(labelText: '备用 API Key'),
                      onChanged: (v) => save(
                          settings.copyWith(visionFallbackApiKey: v.trim())),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _visionFallbackModel,
                      decoration: const InputDecoration(
                          labelText: '备用模型', hintText: 'qwen3.8-flash'),
                      onChanged: (v) => save(
                          settings.copyWith(visionFallbackModel: v.trim())),
                    ),
                  ),
                ]),
              ],
            ),
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
              const Expanded(
                child: Text(
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

  /// 打印 / 控制服务（bconnect_service.py）：填了地址就通过网络调用那台
  /// Mac 上的自动化，留空则读本机 `~/.bambudeck/helper.json`。
  Widget _serviceSection(BuildContext context, WidgetRef ref,
      AppSettings settings, AppSettingsNotifier notifier) {
    var testing = false;
    String? result;
    return StatefulBuilder(builder: (context, setState) {
      Future<void> save(AppSettings s) => notifier.set(s);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 18),
        _sectionLabel('打印 / 控制服务'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            TextField(
              controller: _helperUrl,
              decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'http://192.168.1.10:8799(留空=本机)'),
              onChanged: (v) => save(settings.copyWith(helperUrl: v.trim())),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _helperToken,
              decoration: const InputDecoration(labelText: '服务令牌'),
              onChanged: (v) => save(settings.copyWith(helperToken: v.trim())),
            ),
            const SizedBox(height: 10),
            Row(children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.wifi_tethering, size: 16),
                label: const Text('测试连接'),
                onPressed: testing
                    ? null
                    : () async {
                        setState(() { testing = true; result = null; });
                        final r = await CloudPrintHelper.instance
                            .probe(_helperUrl.text, _helperToken.text);
                        if (!context.mounted) return;
                        setState(() {
                          testing = false;
                          result = r['ok'] == true
                              ? '✅ 已连接（Connect ${r['app_running'] == true ? "在运行" : "未运行"}）'
                              : '❌ ${r['error'] ?? '连接失败'}';
                        });
                      },
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.download, size: 16),
                label: const Text('读本机 helper'),
                onPressed: () async {
                  final ep = await HelperEndpoint.load();
                  if (!context.mounted) return;
                  if (ep == null) {
                    setState(() => result = '❌ 没找到 ~/.bambudeck/helper.json');
                    return;
                  }
                  _helperUrl.text = ep.url;
                  _helperToken.text = ep.token;
                  save(settings.copyWith(
                      helperUrl: ep.url, helperToken: ep.token));
                  setState(() => result = '✅ 已填入本机服务地址');
                },
              ),
            ]),
            const SizedBox(height: 6),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '手机/平板：填 Mac 的地址，并在 Mac 上用 --lan 启动服务。'
                '留空则读写本机 ~/.bambudeck/helper.json（仅 macOS）。',
                style: TextStyle(fontSize: 11, color: DeckColors.textSecondary),
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(result!,
                    style: TextStyle(
                        fontSize: 12,
                        color: result!.startsWith('✅')
                            ? Colors.green
                            : DeckColors.error)),
              ),
            ],
          ]),
        ),
      ]);
    });
  }

  /// 网页访问 (服务端和网页端 2026-10-20): serves the monitoring page on the
  /// LAN; the shareable URL carries the access token once, the web page
  /// keeps it in localStorage and strips it from the address bar.
  ///
  /// The token is user-definable: the hub reads it from settings on every
  /// request, so a new value takes effect immediately without a restart. It
  /// is limited to URL-unreserved characters so it can travel as `?token=`
  /// without encoding.
  Widget _hubSection(BuildContext context, WidgetRef ref,
      AppSettings settings, AppSettingsNotifier notifier) {
    Future<void> save(AppSettings s) => notifier.set(s);

    void syncToken(String raw) {
      final t = raw.trim();
      if (t == settings.hubToken) return;
      if (t.length < 3) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('令牌至少 3 位，未保存')));
        return;
      }
      save(settings.copyWith(hubToken: t));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('令牌已更新，已打开的网页需用新地址重新打开')));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 18),
      _sectionLabel('网页访问'),
      SwitchListTile(
        title: const Text('启用网页端'),
        subtitle: const Text('局域网内浏览器打开即可查看打印机状态与摄像头画面',
            style: TextStyle(fontSize: 12)),
        value: settings.hubEnabled,
        onChanged: (v) {
          var token = settings.hubToken;
          if (v && token.isEmpty) token = generateHubToken();
          save(settings.copyWith(hubEnabled: v, hubToken: token));
        },
      ),
      if (settings.hubEnabled) ...[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            Row(children: [
              SizedBox(
                width: 120,
                child: TextField(
                  controller: _hubPort,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  decoration: const InputDecoration(labelText: '端口'),
                  onSubmitted: (v) {
                    final port = int.tryParse(v.trim());
                    if (port == null || port < 1 || port > 65535) return;
                    save(settings.copyWith(hubPort: port));
                  },
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '端口修改后自动重启服务',
                  style: TextStyle(
                      fontSize: 11, color: DeckColors.textSecondary),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _hubToken,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9._~-]')),
                LengthLimitingTextInputFormatter(64),
              ],
              decoration: InputDecoration(
                labelText: '访问令牌',
                helperText: '字母、数字和 . _ ~ - 组成，至少 3 位；回车或点 ✓ 保存',
                helperMaxLines: 2,
                suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: '随机生成',
                    icon: const Icon(Icons.casino_outlined, size: 20),
                    onPressed: () {
                      final t = generateHubToken();
                      _hubToken.text = t;
                      save(settings.copyWith(hubToken: t));
                    },
                  ),
                  IconButton(
                    tooltip: '保存令牌',
                    icon: const Icon(Icons.check, size: 20),
                    onPressed: () => syncToken(_hubToken.text),
                  ),
                ]),
              ),
              onSubmitted: syncToken,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制访问地址'),
                onPressed: () async {
                  final host = await detectLocalIpv4();
                  final url =
                      'http://$host:${settings.hubPort}/?token=${settings.hubToken}';
                  await Clipboard.setData(ClipboardData(text: url));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已复制: $url')));
                  }
                },
              ),
            ),
          ]),
        ),
      ],
    ]);
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

/// One-shot 视觉判读 test: grabs a frame from the first camera that yields
/// one and asks the configured model. Returns a human line prefixed
/// ✅/❌/⚠ for the inline result label.
///
/// The settings page is an opaque route, so the camera tiles underneath are
/// not painted - grabbing the on-screen tile always missed here. The test
/// therefore pulls a frame straight from each camera's stream.
Future<String> testVisionNow(WidgetRef ref, AppSettings settings) async {
  final cameras = ref.read(camerasProvider).valueOrNull ?? const [];
  if (cameras.isEmpty) return '❌ 没有已配置的摄像头';
  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  for (final c in cameras) {
    if (!c.enabled) continue;
    // 设置页盖住了下面的监控画面，屏幕上那一帧要么没有要么是旧的，
    // 测试要的是眼前这一刻，所以直接走直连视频源；每台最多等 10 秒，
    // 免得几台摄像头都不通时按钮转上一两分钟。
    final png = await cameraGrabber.grab(c,
        printers: printers,
        preferMounted: false,
        timeout: const Duration(seconds: 10));
    if (png == null) continue;
    final chain = VisionChain.fromSettings(settings, log: LogBuffer.instance.add);
    final reply = await chain.analyzeFrame(png);
    final verdict = reply == null ? null : parseVisionVerdict(reply);
    if (verdict == null) {
      return '❌ 判读失败(检查 API 地址 / Key / 模型,详情见运行日志)';
    }
    final abnormal = verdict.isAbnormal ? '⚠ 异常:${verdict.abnormal}' : '✅ 画面正常';
    return '$abnormal · 画面来自 ${c.name} · '
        '平台物体=${verdict.platformHasObject} · '
        '打印中=${verdict.printRunning}\n${verdict.notes}';
  }
  return '❌ 没有可抓取的画面'
      '(已直连 ${cameras.length} 个摄像头的视频源,均未取到帧 —— '
      '检查摄像头地址/密码,或先到监控页确认画面能出)';
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
      body: StreamBuilder<List<String>>(
        stream: log.lines,
        initialData: log.value,
        builder: (context, snapshot) {
          final lines = snapshot.data ?? const <String>[];
          return lines.isEmpty
              ? const Center(
                  child: Text('暂无日志',
                      style: TextStyle(color: DeckColors.textSecondary)))
              // SelectionArea：鼠标可以划选任意几行/半行，⌘C 或右键拷贝；
              // 右上角「复制全部」按钮保留（2026-10-27）。
              : SelectionArea(
                  child: ListView.builder(
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
                );
        },
      ),
    );
  }
}
