import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/camera_profile.dart';
import '../../data/ezviz_cloud.dart';
import '../../data/ezviz_discovery.dart';

/// EZVIZ RTSP URL for one camera on the LAN (verification code as password).
String ezvizRtspUrl({required String ip, required String code}) =>
    'rtsp://admin:$code@$ip:554/h264/ch1/main/av_stream';

/// Verification code hidden inside an existing rtsp://admin:code@host URL,
/// used to prefill the import sheet for cameras added manually before.
String? verificationCodeFromUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final sep = u.userInfo.indexOf(':');
  if (sep < 0) return null;
  return Uri.decodeComponent(u.userInfo.substring(sep + 1));
}

/// 萤石云端导入 (云端账号获取摄像头列表 2026-10-20): sign into the EZVIZ
/// open platform with AppKey/AppSecret, list the account's cameras, match
/// each one to its LAN address by serial (HCNetSDK login readout), and add
/// the picked ones as RTSP profiles. The AppKey/Secret persist in settings;
/// the token is fetched on demand.
Future<void> showEzvizImportSheet(
    BuildContext context, WidgetRef ref) async {
  await showDialog(
    context: context,
    builder: (_) => const _EzvizImportDialog(),
  );
}

class _EzvizImportDialog extends ConsumerStatefulWidget {
  const _EzvizImportDialog();

  @override
  ConsumerState<_EzvizImportDialog> createState() =>
      _EzvizImportDialogState();
}

class _EzvizImportDialogState extends ConsumerState<_EzvizImportDialog> {
  final _appKeyCtrl = TextEditingController();
  final _secretCtrl = TextEditingController();
  final _subnetCtrl = TextEditingController();

  List<EzvizDevice> _devices = const [];
  // Per-device form state, keyed by serial.
  final _codeCtrls = <String, TextEditingController>{};
  final _ipCtrls = <String, TextEditingController>{};
  final _checked = <String>{};
  final _lookingUp = <String>{};
  bool _fetching = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings =
        ref.read(appSettingsProvider).valueOrNull ?? const AppSettings();
    _appKeyCtrl.text = settings.ezvizAppKey;
    _secretCtrl.text = settings.ezvizAppSecret;
    _initSubnet();
  }

  Future<void> _initSubnet() async {
    try {
      final local = await detectLocalIpv4();
      final parts = local.split('.');
      if (parts.length == 4) {
        setState(() =>
            _subnetCtrl.text = '${parts[0]}.${parts[1]}.${parts[2]}');
      }
    } catch (_) {
      // leave empty - the user can type the prefix
    }
  }

  @override
  void dispose() {
    _appKeyCtrl.dispose();
    _secretCtrl.dispose();
    _subnetCtrl.dispose();
    for (final c in _codeCtrls.values) {
      c.dispose();
    }
    for (final c in _ipCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchDevices() async {
    final key = _appKeyCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    if (key.isEmpty || secret.isEmpty) {
      setState(() => _error = '请填写 AppKey 和 AppSecret');
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final client = EzvizCloudClient();
      final token = await client.fetchToken(appKey: key, appSecret: secret);
      final list = await client.fetchDevices(token);
      await ref.read(appSettingsProvider.notifier).set(
          (ref.read(appSettingsProvider).valueOrNull ?? const AppSettings())
              .copyWith(ezvizAppKey: key, ezvizAppSecret: secret));
      // Prefill code/ip from cameras already configured with the same
      // serial (manually added earlier), so a re-import fills itself in.
      final existing = ref.read(camerasProvider).valueOrNull ?? const [];
      for (final d in list) {
        final codeCtrl = TextEditingController();
        final ipCtrl = TextEditingController();
        for (final c in existing) {
          final code = verificationCodeFromUrl(c.url);
          if (code == null) continue;
          final u = Uri.tryParse(c.url);
          if (u == null || u.host.isEmpty) continue;
          // RTSP URLs don't carry the serial; match on the code the user
          // gave before - verification codes are unique per device.
          if (codeCtrl.text.isEmpty) codeCtrl.text = code;
          if (ipCtrl.text.isEmpty) ipCtrl.text = u.host;
        }
        _codeCtrls[d.serial] = codeCtrl;
        _ipCtrls[d.serial] = ipCtrl;
      }
      setState(() {
        _devices = list;
        _checked
          ..clear()
          ..addAll([for (final d in list) if (d.online) d.serial]);
        _fetching = false;
        if (list.isEmpty) _error = '该账号下没有绑定设备';
      });
    } catch (e) {
      setState(() {
        _error = '获取失败: $e';
        _fetching = false;
      });
    }
  }

  Future<void> _lookupIp(String serial) async {
    final code = _codeCtrls[serial]?.text.trim() ?? '';
    final prefix = _subnetCtrl.text.trim();
    if (code.isEmpty ||
        !RegExp(r'^\d{1,3}(\.\d{1,3}){2}$').hasMatch(prefix)) {
      setState(() => _error = '查 IP 前需填验证码和网段前缀(如 192.168.100)');
      return;
    }
    setState(() => _lookingUp.add(serial));
    try {
      final matches = await matchEzvizOnLan(
          subnetPrefix: prefix, verificationCode: code, wanted: {serial});
      setState(() {
        _lookingUp.remove(serial);
        if (matches.isEmpty) {
          _error = '未在 $prefix.x 找到该设备(确认验证码正确、摄像头已联网、路由器未开 AP 隔离)';
        } else {
          _ipCtrls[serial]?.text = matches.first.ip;
          _error = null;
        }
      });
    } catch (e) {
      setState(() {
        _lookingUp.remove(serial);
        _error = '查找失败: $e';
      });
    }
  }

  Future<void> _import() async {
    // Captured before any await - the dialog pops at the end and context
    // must not be touched across that gap.
    final messenger = ScaffoldMessenger.of(context);
    final cameras = ref.read(camerasProvider).valueOrNull ?? const [];
    final existingUrls = [for (final c in cameras) c.url];
    final added = <String>[];
    final skipped = <String>[];
    for (final d in _devices) {
      if (!_checked.contains(d.serial)) continue;
      final code = _codeCtrls[d.serial]?.text.trim() ?? '';
      final ip = _ipCtrls[d.serial]?.text.trim() ?? '';
      if (code.isEmpty || ip.isEmpty) {
        skipped.add('${d.name.isEmpty ? d.serial : d.name}(缺验证码或 IP)');
        continue;
      }
      final url = ezvizRtspUrl(ip: ip, code: code);
      if (existingUrls.contains(url)) continue; // already configured
      await ref.read(camerasProvider.notifier).add(CameraProfile(
            id: 'c_${DateTime.now().millisecondsSinceEpoch}_${added.length}',
            name: d.name.isEmpty ? d.serial : d.name,
            sourceType: CameraSourceType.rtsp,
            url: url,
          ));
      added.add(d.name.isEmpty ? d.serial : d.name);
    }
    if (mounted) Navigator.of(context).pop();
    if (added.isEmpty && skipped.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('没有新的摄像头可导入')));
    } else {
      messenger.showSnackBar(SnackBar(
          content: Text([
        if (added.isNotEmpty) '已导入 ${added.length} 个: ${added.join('、')}'
        else '未导入新摄像头',
        if (skipped.isNotEmpty) '跳过: ${skipped.join('; ')}',
      ].join('  ·  '))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('萤石云端导入'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                  'AppKey / AppSecret 来自 open.ys7.com 控制台 → 应用信息,一个账号覆盖名下所有摄像头。',
                  style: TextStyle(
                      fontSize: 12, color: DeckColors.textSecondary)),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _appKeyCtrl,
                    decoration: const InputDecoration(labelText: 'AppKey'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _secretCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'AppSecret'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _fetching ? null : _fetchDevices,
                  child: _fetching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2))
                      : const Text('获取设备列表'),
                ),
              ]),
              const SizedBox(height: 8),
              TextField(
                controller: _subnetCtrl,
                decoration: const InputDecoration(
                  labelText: '局域网网段前缀(自动查 IP 用)',
                  hintText: '192.168.100',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(
                        color: DeckColors.error, fontSize: 13)),
              ],
              const SizedBox(height: 6),
              for (final d in _devices) _deviceRow(d),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _devices.isEmpty ? null : _import,
          child: const Text('导入选中的摄像头'),
        ),
      ],
    );
  }

  Widget _deviceRow(EzvizDevice d) {
    final name = d.name.isEmpty ? d.serial : d.name;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DeckColors.bg.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              SizedBox(
                width: 28,
                child: Checkbox(
                  value: _checked.contains(d.serial),
                  onChanged: (v) => setState(() => v == true
                      ? _checked.add(d.serial)
                      : _checked.remove(d.serial)),
                ),
              ),
              Expanded(
                child: Text(
                  '$name  ·  ${d.online ? "在线" : "离线"}  ·  ${d.model}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            Text(d.serial,
                style:
                    const TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _codeCtrls[d.serial],
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: '验证码', hintText: '设备标签上的 6 位码'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _ipCtrls[d.serial],
                  decoration: const InputDecoration(
                      labelText: 'IP', hintText: '可点右侧自动查'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _lookingUp.contains(d.serial)
                    ? null
                    : () => _lookupIp(d.serial),
                child: Text(_lookingUp.contains(d.serial) ? '查找中' : '查 IP'),
              ),
            ]),
          ]),
    );
  }
}
