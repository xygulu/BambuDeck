import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';

/// Add-printer sheet: LAN direct (ip + access code) or Bambu Cloud
/// (paste token -> pick device). Password / email-code login arrives in a
/// later iteration (PRD FR-8 lists the full flow).
class AddPrinterSheet extends ConsumerStatefulWidget {
  const AddPrinterSheet({super.key});

  @override
  ConsumerState<AddPrinterSheet> createState() => _AddPrinterSheetState();
}

class _AddPrinterSheetState extends ConsumerState<AddPrinterSheet> {
  var _mode = PrinterMode.lan;

  // LAN form
  final _nameCtrl = TextEditingController();
  final _ipCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  // Cloud form
  var _region = CloudRegion.us;
  final _tokenCtrl = TextEditingController();
  List<CloudDevice>? _devices;
  CloudDevice? _selected;
  var _fetching = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _serialCtrl.dispose();
    _codeCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 14,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('添加打印机',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            SegmentedButton<PrinterMode>(
              segments: const [
                ButtonSegment(
                    value: PrinterMode.lan,
                    label: Text('局域网直连'),
                    icon: Icon(Icons.lan)),
                ButtonSegment(
                    value: PrinterMode.cloud,
                    label: Text('Bambu 云端'),
                    icon: Icon(Icons.cloud_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 16),
            if (_mode == PrinterMode.lan)
              _lanForm()
            else
              _cloudForm(),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(
                      color: DeckColors.error, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lanForm() => Column(children: [
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
              labelText: '名称(可选)', hintText: '例如 打印房 P1S'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _ipCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: '打印机 IP', hintText: '192.168.1.42'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _serialCtrl,
          decoration: const InputDecoration(
              labelText: '序列号 (SN)',
              hintText: '打印机屏幕 设置 → 关于 设备 可查'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _codeCtrl,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: '局域网访问码',
              hintText: '打印机屏幕 设置 → 局域网 查看'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saveLan,
          child: const Text('保存并连接'),
        ),
      ]);

  Widget _cloudForm() => Column(children: [
        DropdownButtonFormField<CloudRegion>(
          initialValue: _region,
          decoration: const InputDecoration(labelText: '账号区域'),
          items: const [
            DropdownMenuItem(value: CloudRegion.us, child: Text('国际区 (us)')),
            DropdownMenuItem(value: CloudRegion.eu, child: Text('欧洲区 (eu)')),
            DropdownMenuItem(value: CloudRegion.cn, child: Text('中国区 (cn)')),
          ],
          onChanged: (r) => setState(() => _region = r ?? CloudRegion.us),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _tokenCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
              labelText: '访问 Token',
              hintText: '从浏览器登录拓竹后粘贴(支持后续密码/验证码登录)'),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _fetching ? null : _fetchDevices,
              child: _fetching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('获取打印机列表'),
            ),
          ),
        ]),
        if (_devices != null) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<CloudDevice>(
            initialValue: _selected,
            decoration: const InputDecoration(labelText: '选择打印机'),
            items: [
              for (final d in _devices!)
                DropdownMenuItem(
                  value: d,
                  child: Text('${d.productName} "${d.devName}"'
                      ' (${d.online ? "在线" : "离线"})'),
                ),
            ],
            onChanged: (d) => setState(() => _selected = d),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: (_selected != null) ? _saveCloud : null,
          child: const Text('保存并连接'),
        ),
      ]);

  Future<void> _fetchDevices() async {
    setState(() {
      _error = null;
      _fetching = true;
    });
    final token = _tokenCtrl.text.trim();
    if (token.isEmpty) {
      setState(() {
        _error = '请先粘贴访问 Token';
        _fetching = false;
      });
      return;
    }
    try {
      final api = ref.read(cloudApiProvider);
      final devices = await api.devices(token, _region);
      setState(() {
        _devices = devices;
        _selected = devices.isNotEmpty ? devices.first : null;
        _error = devices.isEmpty ? '该账号下没有绑定的打印机' : null;
        _fetching = false;
      });
    } on Exception catch (e) {
      setState(() {
        _error = '获取列表失败: $e';
        _fetching = false;
      });
    }
  }

  Future<void> _saveLan() async {
    final ip = _ipCtrl.text.trim();
    final serial = _serialCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (ip.isEmpty || serial.isEmpty || code.isEmpty) {
      setState(() => _error = 'IP、序列号和访问码都不能为空');
      return;
    }
    final id = 'p_${DateTime.now().millisecondsSinceEpoch}';
    await ref.read(printersProvider.notifier).add(PrinterProfile(
          id: id,
          name: _nameCtrl.text.trim().isEmpty ? serial : _nameCtrl.text.trim(),
          mode: PrinterMode.lan,
          serial: serial,
          ip: ip,
          accessCode: code,
        ));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveCloud() async {
    final token = _tokenCtrl.text.trim();
    final device = _selected;
    if (device == null || token.isEmpty) {
      setState(() => _error = '请完成 Token 与打印机选择');
      return;
    }
    final api = ref.read(cloudApiProvider);
    final userId = api.userIdFromToken(token) ?? '';
    if (userId.isEmpty) {
      setState(() => _error = '无法从 Token 解析用户 ID,请确认 Token 有效');
      return;
    }
    final id = 'p_${DateTime.now().millisecondsSinceEpoch}';
    await ref.read(printersProvider.notifier).add(PrinterProfile(
          id: id,
          name: device.devName.isEmpty
              ? (device.productName.isEmpty ? device.devId : device.productName)
              : device.devName,
          mode: PrinterMode.cloud,
          serial: device.devId,
          region: _region,
          token: token,
          userId: userId,
        ));
    if (mounted) Navigator.of(context).pop();
  }
}
