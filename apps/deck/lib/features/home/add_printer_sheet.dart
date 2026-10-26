import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/bambu_mjpeg.dart';
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
  String? _lanModel;

  // Cloud form. Region follows the system language on open (zh -> cn):
  // a wrong-region login reads as "wrong password", which nobody debugs.
  late var _region = WidgetsBinding
              .instance.platformDispatcher.locale.languageCode == 'zh'
      ? CloudRegion.cn
      : CloudRegion.us;
  final _tokenCtrl = TextEditingController();
  List<CloudDevice>? _devices;
  final Set<String> _selectedSerials = {};
  var _fetching = false;
  String? _error;

  // Cloud sign-in (token obtained in-app instead of pasted)
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _loginCodeCtrl = TextEditingController();
  var _loginBusy = false;
  String? _loginMsg;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _serialCtrl.dispose();
    _codeCtrl.dispose();
    _tokenCtrl.dispose();
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    _loginCodeCtrl.dispose();
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
          onChanged: (s) {
            // Auto-guess until the user picks a model themselves.
            if (_lanModel != null) return;
            final guess = guessModelFromSerial(s);
            if (guess != null) setState(() => _lanModel = guess);
          },
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
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(
          initialValue: _lanModel,
          decoration: const InputDecoration(
              labelText: '机型(决定摄像头取流方式)',
              hintText: '按序列号自动猜'),
          items: [
            for (final m in const [
              'A1',
              'A1 mini',
              'P1P',
              'P1S',
              'X1C',
              'X1E',
              'P2S',
              'H2D',
              'H2S',
              '其他/不确定',
            ])
              DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (m) => setState(() => _lanModel = m),
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
        _loginSection(),
        const SizedBox(height: 10),
        TextField(
          controller: _tokenCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
              labelText: '访问 Token(登录后自动填入,也可手动粘贴)',
              hintText: '浏览器登录拓竹后从请求头/cookie 复制'),
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
        if (_devices != null && _devices!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Text(
                '已选 ${_selectedSerials.length}/${_devices!.length} 台',
                style: const TextStyle(
                    fontSize: 12, color: DeckColors.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => _toggleAll(!_allSelected),
              child: Text(_allSelected ? '取消全选' : '全选'),
            ),
          ]),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(children: [
              for (final d in _devices!)
                CheckboxListTile(
                  value: _selectedSerials.contains(d.devId),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selectedSerials.add(d.devId);
                    } else {
                      _selectedSerials.remove(d.devId);
                    }
                  }),
                  title: Text(_deviceLabel(d)),
                  subtitle: Text(d.online ? '在线' : '离线'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: _selectedSerials.isEmpty ? null : _addSelected,
              child: Text('添加选中 (${_selectedSerials.length})'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.tonal(
              onPressed: (_devices != null && _devices!.isNotEmpty)
                  ? _addAll
                  : null,
              child: const Text('一键添加全部'),
            ),
          ),
        ]),
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
      debugPrint('[cloud] fetching devices, region=${_region.name}, '
          'token=${token.length}B, jwt=${token.split('.').length}段');
      final devices = await api.devices(token, _region);
      debugPrint('[cloud] devices: ${devices.length}');
      setState(() {
        _devices = devices;
        // Default to all selected: batch-add is the common case, the user
        // unchecks the few they don't want.
        _selectedSerials
          ..clear()
          ..addAll(devices.map((d) => d.devId));
        _error = devices.isEmpty ? '该账号下没有绑定的打印机' : null;
        _fetching = false;
      });
    } on Exception catch (e) {
      // Full failure detail goes to the run log; the sheet shows a short line.
      debugPrint('[cloud] list FAILED: $e');
      setState(() {
        _error = '获取列表失败: $e';
        _fetching = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // In-app sign-in. Flows ported from BambuHelper cloud_login.cpp: account
  // (phone/email) + password, or an emailed login code. Both land the token
  // in _tokenCtrl and immediately pull the device list.
  // ---------------------------------------------------------------------------

  Widget _loginSection() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('账号登录(自动获取 Token)',
              style:
                  TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
          const SizedBox(height: 8),
          TextField(
            controller: _accountCtrl,
            decoration: const InputDecoration(
                labelText: '手机号 / 邮箱', hintText: '与 Bambu Handy 相同的账号'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _passwordCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                    labelText: '密码',
                    hintText: '国内手机号账号用密码登录'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: _loginBusy ? null : _loginWithPassword,
              child: const Text('登录'),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _loginCodeCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: '验证码', hintText: '手机号发短信 / 邮箱发邮件'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _loginBusy ? null : _sendLoginCode,
              child: const Text('发验证码'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _loginBusy ? null : _loginWithCode,
              child: const Text('验证码登录'),
            ),
          ]),
          if (_loginMsg != null) ...[
            const SizedBox(height: 8),
            Text(_loginMsg!,
                style: const TextStyle(
                    fontSize: 12, color: DeckColors.textSecondary)),
          ],
        ]),
      );

  Future<void> _runLogin(Future<LoginOutcome> Function() flow) async {
    setState(() {
      _loginBusy = true;
      _loginMsg = null;
    });
    try {
      final outcome = await flow();
      switch (outcome) {
        case LoginToken(:final token):
          _tokenCtrl.text = token;
          setState(() => _loginMsg = '登录成功,Token 已填入');
          await _fetchDevices();
        case LoginNeedsEmailCode():
          final emailish = _accountCtrl.text.trim().contains('@');
          setState(() => _loginMsg = emailish
              ? '该账号需要验证码登录:点「发验证码」(发到邮箱),收到后填入再点「验证码登录」'
              : '该账号需要验证码登录(手机号注册,验证码走短信):点「发验证码」,收到后填入再点「验证码登录」');
        case LoginNeedsTfa():
          setState(() => _loginMsg =
              '该账号开启了两步验证,暂不支持动态口令——请改用「验证码登录」,或到拓竹官网关闭两步验证后用密码登录');
      }
    } on Exception catch (e) {
      debugPrint('[cloud] login FAILED: $e');
      setState(() => _loginMsg = '登录失败: $e');
    } finally {
      if (mounted) setState(() => _loginBusy = false);
    }
  }

  Future<void> _loginWithPassword() async {
    final account = _accountCtrl.text.trim();
    if (account.isEmpty || _passwordCtrl.text.isEmpty) {
      setState(() => _loginMsg = '请填写账号和密码');
      return;
    }
    await _runLogin(() => cloudLogin(
        region: _region, account: account, password: _passwordCtrl.text));
  }

  Future<void> _sendLoginCode() async {
    final account = _accountCtrl.text.trim();
    if (account.isEmpty) {
      setState(() => _loginMsg = '请先填写账号(手机号或邮箱)');
      return;
    }
    setState(() {
      _loginBusy = true;
      _loginMsg = null;
    });
    try {
      await cloudSendLoginCode(region: _region, account: account);
      setState(() =>
          _loginMsg = '验证码已发送到 $account(${account.contains("@") ? "邮件" : "短信"})');
    } on Exception catch (e) {
      debugPrint('[cloud] send code FAILED: $e');
      setState(() => _loginMsg = '发送失败: $e');
    } finally {
      if (mounted) setState(() => _loginBusy = false);
    }
  }

  Future<void> _loginWithCode() async {
    final account = _accountCtrl.text.trim();
    final code = _loginCodeCtrl.text.trim();
    if (account.isEmpty || code.isEmpty) {
      setState(() => _loginMsg = '请填写账号和验证码');
      return;
    }
    await _runLogin(
        () => cloudLogin(region: _region, account: account, code: code));
  }

  Future<void> _saveLan() async {
    final ip = _ipCtrl.text.trim();
    final serial = _serialCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (ip.isEmpty || serial.isEmpty || code.isEmpty) {
      setState(() => _error = 'IP、序列号和访问码都不能为空');
      return;
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final id = 'p_$stamp';
    await ref.read(printersProvider.notifier).add(PrinterProfile(
          id: id,
          name: _nameCtrl.text.trim().isEmpty ? serial : _nameCtrl.text.trim(),
          mode: PrinterMode.lan,
          serial: serial,
          ip: ip,
          accessCode: code,
          model: _lanModel == '其他/不确定'
              ? ''
              : (_lanModel ?? guessModelFromSerial(serial) ?? ''),
          createdAt: stamp,
        ));
    if (mounted) Navigator.of(context).pop();
  }

  bool get _allSelected =>
      _devices != null &&
      _devices!.isNotEmpty &&
      _selectedSerials.length == _devices!.length;

  void _toggleAll(bool on) => setState(() {
        _selectedSerials.clear();
        if (on) _selectedSerials.addAll(_devices!.map((d) => d.devId));
      });

  /// Dropdown / checkbox label: `A1 "打印房"`, or the best available fallback.
  String _deviceLabel(CloudDevice d) {
    final name = d.devName.trim();
    final product = d.productName.trim();
    if (name.isNotEmpty && product.isNotEmpty) return '$product "$name"';
    if (name.isNotEmpty) return name;
    if (product.isNotEmpty) return product;
    return d.devId;
  }

  /// Stored profile name (no product prefix).
  String _deviceName(CloudDevice d) {
    final name = d.devName.trim();
    if (name.isNotEmpty) return name;
    final product = d.productName.trim();
    if (product.isNotEmpty) return product;
    return d.devId;
  }

  Future<void> _addSelected() async {
    await _addDevices(
        _devices!.where((d) => _selectedSerials.contains(d.devId)).toList());
  }

  Future<void> _addAll() async {
    await _addDevices(List.of(_devices!));
  }

  Future<void> _addDevices(List<CloudDevice> devices) async {
    final token = _tokenCtrl.text.trim();
    if (token.isEmpty) {
      setState(() => _error = '请先登录获取 Token');
      return;
    }
    final api = ref.read(cloudApiProvider);
    final userId = await api.userIdFromToken(token, _region);
    if (userId == null || userId.isEmpty) {
      setState(() => _error = '无法从 Token 解析用户 ID,请确认 Token 有效');
      return;
    }
    final existing =
        ref.read(printersProvider).valueOrNull ?? const <PrinterProfile>[];
    final existingSerials = existing.map((p) => p.serial).toSet();
    final notifier = ref.read(printersProvider.notifier);
    var added = 0;
    var skipped = 0;
    for (final d in devices) {
      if (existingSerials.contains(d.devId)) {
        skipped++;
        continue;
      }
      // id is stable per serial, so a re-add is idempotent instead of piling
      // duplicates; the serial check above already guards the list.
      await notifier.add(PrinterProfile(
        id: 'p_${d.devId}',
        name: _deviceName(d),
        mode: PrinterMode.cloud,
        serial: d.devId,
        region: _region,
        token: token,
        userId: userId,
        model: d.modelName,
        accessCode: d.accessCode,
      ));
      added++;
    }
    if (!mounted) return;
    if (added == 0 && skipped > 0) {
      setState(() => _error = '所选打印机均已添加过');
      return;
    }
    Navigator.of(context).pop();
  }
}
