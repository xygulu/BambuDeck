import 'dart:async';
import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'camera_profile.dart';
import 'cloud_device_sync.dart';
import 'cloud_print_helper.dart';
import 'lan_printer_probe.dart';
import 'hub_config.dart';
import 'hub_server.dart';
import 'log_buffer.dart';
import 'plate_swap.dart';
import 'printer_link.dart';
import 'printer_profile.dart';
import 'rtsp_quality.dart';

/// 独立网页服务：不依赖 GUI app，直接读 `~/.bambudeck/hub.json` 起一套
/// [HubServer]，并自己管理每台打印机的 MQTT 连接。
///
/// 控制路由与 App 内完全一致（见 main.dart 的 hubServer 接线）：
///   dev-ON 的 LAN 打印机 → 局域网 MQTT 直发（秒回）
///   其余（云 / dev-OFF）→ Bambu Connect 自动化（本机 helper）
/// 调速 → Connect 自动化（helper 在线时），退回局域网直发并如实标注「未确认」。
class HubService {
  HubService({
    required this.configFile,
    required this.pageFile,
    required this.plateSwapFile,
    Future<HttpServer> Function(InternetAddress, int)? bind,
    void Function(String message)? log,
  }) : hub = HubServer(bind: bind, log: log ?? LogBuffer.instance.add) {
    hub.pageLoader = () => File(pageFile).readAsString();
    plateSwapBytesLoader = () => File(plateSwapFile).readAsBytes();
  }

  final File configFile;
  final String pageFile;
  final String plateSwapFile;
  final HubServer hub;

  HubConfig config = const HubConfig();

  final _links = <String, PrinterLink>{};
  final _states = <String, BambuState?>{};
  final _statuses = <String, BambuConnStatus>{};

  /// 云账号设备同步（产品化 2026-10-28）：bind 列表为打印机清单的活源头。
  CloudDeviceSync cloudSync = CloudDeviceSync();
  Timer? _cloudSyncTimer;

  bool get running => hub.running;

  Future<void> start() async {
    config = await loadHubConfig(configFile);

    hub.settings = config.settings;
    hub.printers = config.printers;
    hub.cameras = config.cameras;
    CloudPrintHelper.instance.settings = config.settings;

    // 和 App 走同一条路由（见 main.dart 的 hubServer 接线）。
    hub.controlHandler = _control;
    hub.plateSwapHandler = _plateSwap;
    hub.setHandler = _set;
    hub.connStatusOf = (id) => (_statuses[id] ?? BambuConnStatus.disconnected).name;
    hub.cameraHandler = _camera;
    hub.muteHandler = _mute;
    hub.accounts = config.accounts;
    hub.cloudLoginHandler = _cloudLogin;
    hub.accountsHandler = _accountsStatus;
    hub.accountUpdateHandler = _accountUpdate;

    LogBuffer.instance.add('[独立服务] 载入 ${config.printers.length} 台打印机、'
        '${config.cameras.length} 个摄像头 (${configFile.path})');
    for (final p in config.printers) {
      _connect(p);
    }

    await hub.start();

    // 云同步：先起服务（用缓存清单，不阻塞），随后立即拉一次 bind，之后每
    // 5 分钟复查。变化落盘 → bin/hub.dart 的 mtime 监视退出重启 → 新清单生效。
    if (config.accounts.any((a) => !a.suspended && a.accessToken.isNotEmpty)) {
      unawaited(_runCloudSync());
      _cloudSyncTimer = Timer.periodic(
          const Duration(minutes: 5), (_) => unawaited(_runCloudSync()));
    }

    // 云同步来的 LAN 打印机可能缺 IP (见 _resolveLanIps): 补完落盘触发
    // mtime 重启, 重启后再进来就是补齐状态, 不发散。
    unawaited(_resolveLanIps());
  }

  /// LAN 发现 (2026-10-28): 云端只给序列号, LAN 直连还缺 IP 的打印机在
  /// 这里补上。两段: SSDP 组播 (同网段, 零流量) → 8883 扫网+访问码认证
  /// (跨网段; 组播不过路由, A1 也不回单播 M-SEARCH, 只有 MQTT 必通)。
  /// 补不到就下次重启再试, 不重试风暴。
  Future<void> _resolveLanIps() async {
    final need = config.printers
        .where((p) =>
            p.mode == PrinterMode.lan &&
            p.serial.trim().isNotEmpty &&
            p.ip.trim().isEmpty)
        .toList();
    if (need.isEmpty) return;
    final bySerial = <String, SsdpHit>{};

    // (1) SSDP 组播。
    try {
      final hits = await ssdpDiscoverPrinters(
          wait: const Duration(seconds: 6)).timeout(const Duration(seconds: 40));
      for (final h in hits) {
        bySerial[h.serial] = h;
      }
    } catch (e) {
      LogBuffer.instance.add('[云同步] SSDP 发现失败: ${_oneLine(e)}');
    }

    // (2) 8883 扫网认证, 只补 SSDP 没认出来且有访问码的。
    final rest = need
        .where((p) =>
            !bySerial.containsKey(p.serial.trim()) && p.accessCode.isNotEmpty)
        .toList();
    if (rest.isNotEmpty) {
      final prefixes = await _subnetSeeds();
      if (prefixes.isNotEmpty) {
        try {
          final found = await locateLanPrinters(
            targets: [
              for (final p in rest)
                LanProbeTarget(serial: p.serial.trim(), accessCode: p.accessCode),
            ],
            subnetPrefixes: prefixes,
          ).timeout(const Duration(minutes: 3));
          for (final e in found.entries) {
            bySerial[e.key] = SsdpHit(ip: e.value, serial: e.key);
          }
          LogBuffer.instance.add('[云同步] 8883 扫网: '
              '${prefixes.join("/")} → 认出 ${found.length}/${rest.length}');
        } catch (e) {
          LogBuffer.instance.add('[云同步] 8883 扫网失败: ${_oneLine(e)}');
        }
      }
    }

    if (bySerial.isEmpty) return;
    final printers = [...config.printers];
    var changed = false;
    for (var i = 0; i < printers.length; i++) {
      final p = printers[i];
      if (p.mode != PrinterMode.lan ||
          p.serial.trim().isEmpty ||
          p.ip.trim().isNotEmpty) {
        continue;
      }
      final hit = bySerial[p.serial.trim()];
      if (hit == null) continue;
      printers[i] = p.copyWith(ip: hit.ip);
      changed = true;
      LogBuffer.instance.add(
          '[云同步] LAN 发现补上 ${p.name} (${p.serial}) 的 IP ${hit.ip}');
    }
    if (!changed) return;
    config = HubConfig(
      settings: config.settings,
      printers: printers,
      cameras: config.cameras,
      accounts: config.accounts,
    );
    hub.printers = printers;
    await saveHubConfig(config, configFile);
    LogBuffer.instance.add('[云同步] IP 已补齐, 重启加载');
  }

  /// 扫网种子子网: 已知打印机的网段 (同站点打印机通常同网段) + 本机各网卡
  /// 的网段。
  Future<List<String>> _subnetSeeds() async {
    final out = <String>{};
    for (final p in config.printers) {
      final parts = p.ip.split('.');
      if (parts.length == 4) out.add(parts.sublist(0, 3).join('.'));
    }
    try {
      for (final iface in await NetworkInterface.list()) {
        for (final a in iface.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4 && a.type == InternetAddressType.IPv4) {
            out.add(parts.sublist(0, 3).join('.'));
          }
        }
      }
    } catch (_) {}
    return out.toList();
  }

  Future<void> _runCloudSync() async {
    // 从盘上重读：mtime 重启可能在上一轮同步写盘后发生，内存里的 config 已旧。
    final config = await loadHubConfig(configFile);
    if (!config.accounts.any((a) => !a.suspended && a.accessToken.isNotEmpty)) {
      return;
    }
    final changed = await cloudSync.syncAll(config, configFile);
    if (changed) {
      LogBuffer.instance.add('[云同步] 账号设备清单有变化，即将重启加载');
    }
  }

  Future<void> stop() async {
    _cloudSyncTimer?.cancel();
    for (final link in _links.values) {
      link.dispose();
    }
    _links.clear();
    _states.clear();
    _statuses.clear();
    await hub.stop();
  }

  BambuState? _stateOf(PrinterProfile p) => _states[p.id];

  void _connect(PrinterProfile p) {
    final link = MqttPrinterLink(p);
    _links[p.id] = link;
    _statuses[p.id] = BambuConnStatus.connecting;
    link.status.listen((s) {
      _statuses[p.id] = s;
      LogBuffer.instance.add('[独立服务] ${p.name}: ${s.name}');
    });
    link.states.listen((s) {
      _states[p.id] = s;
      hub.observeState(p, s);
    });
    link.connect();
  }

  // -- handlers (mirror main.dart's hubServer wiring) ----------------------

  Future<Map<String, dynamic>> _control(
      PrinterProfile p, String command) async {
    final state = _stateOf(p);
    if (useLanControl(p, state)) {
      final link = _links[p.id];
      final bool ok;
      if (link == null) {
        ok = false;
      } else {
        ok = switch (command) {
          'pause' => await link.pause(),
          'resume' => await link.resume(),
          'stop' => await link.stop(),
          _ => false,
        };
      }
      LogBuffer.instance
          .add('[网页] $command ${p.name}: 局域网直发${ok ? "已发送" : "失败"}');
      return <String, dynamic>{
        'ok': ok,
        'command': command,
        'printer': p.name,
        'method': 'lan',
        if (!ok) 'error': '局域网直发失败(检查开发者模式与网络)',
      };
    }
    if (p.serial.trim().isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '「${p.name}」未配置序列号, Connect 自动化无法定位打印机',
      };
    }
    final r = await CloudPrintHelper.instance.control(p.serial, command);
    LogBuffer.instance.add('[网页] ${r.command ?? command} ${p.name}: '
        'ok=${r.ok}${r.error == null ? '' : ' err=${r.error}'}');
    return <String, dynamic>{
      'ok': r.ok,
      'command': r.command ?? command,
      'printer': r.printer ?? p.name,
      'method': r.method ?? 'connect',
      if (r.elapsed != null) 'elapsed': r.elapsed,
      if (r.error != null) 'error': r.error,
    };
  }

  Future<Map<String, dynamic>> _plateSwap(PrinterProfile p) async {
    if (p.serial.trim().isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '「${p.name}」未配置序列号, Connect 自动化无法定位打印机',
      };
    }
    if (!await CloudPrintHelper.instance.health()) {
      return <String, dynamic>{
        'ok': false,
        'error': '打印服务不可用（本机 bconnect_service.py 没在跑）',
      };
    }
    final r = await startCloudPlateSwap(p);
    LogBuffer.instance.add('[网页] 换盘 ${p.name}: ok=${r.ok}'
        '${r.error == null ? '' : ' err=${r.error}'}');
    return <String, dynamic>{
      'ok': r.ok,
      'printer': p.name,
      if (r.taskId != null) 'task': r.taskId,
      if (r.taskStatus != null) 'taskStatus': r.taskStatus,
      if (r.elapsedTotal != null) 'elapsed': r.elapsedTotal,
      if (r.error != null) 'error': r.error,
      'steps': r.steps.map((s) => s.toJson()).toList(),
    };
  }

  Future<Map<String, dynamic>> _set(PrinterProfile p,
      {int? speed, bool? light}) async {
    final link = _links[p.id];
    var ok = true;
    var speedConfirmed = true;
    String? speedNote;
    String? speedError;
    if (speed != null) {
      if (p.serial.trim().isEmpty) {
        ok = false;
        speedError = '「${p.name}」未配置序列号，Connect 自动化无法定位打印机';
      } else if (!await CloudPrintHelper.instance.health()) {
        final r = link == null
            ? (sent: false, confirmed: false, note: null)
            : await confirmSpeedLevel(link, speed, state: () => _stateOf(p));
        ok = r.sent && ok;
        speedConfirmed = r.confirmed;
        speedNote = r.note;
        if (!r.sent) speedError = '局域网直发失败(打印机未连接或不在局域网)';
        LogBuffer.instance.add('[网页] 速度${speedLevelName(speed)} '
            '${p.name}: 局域网直发${r.sent ? '' : '失败'}'
            '${r.confirmed ? '' : '(未确认)'} (Connect 服务未运行)');
      } else {
        final r = await CloudPrintHelper.instance.control(
          p.serial,
          'speed',
          params: {'level': speed},
          timeout: const Duration(seconds: 45),
        );
        ok = r.ok && ok;
        speedConfirmed = r.ok &&
            (link == null
                ? false
                : await awaitSpeedLevel(speed, () => _stateOf(p),
                    within: const Duration(seconds: 10)));
        if (r.ok && !speedConfirmed) {
          speedNote = '已在 Bambu Connect 点了这一档，但打印机还没回报新档位'
              '（不在打印中时通常不生效）';
        }
        LogBuffer.instance.add('[网页] 速度${speedLevelName(speed)} '
            '${p.name}: via Connect ok=${r.ok}'
            '${r.ok ? (speedConfirmed ? ' 已确认' : ' 未确认') : ''}'
            '${r.error == null ? '' : ' err=${r.error}'}'
            '${r.elapsed == null ? '' : ' ${r.elapsed!.round()}s'}');
        if (!r.ok) speedError = r.error ?? 'Connect 调速失败';
      }
    }
    if (light != null) {
      final lightOk = link == null ? false : await link.setLight(light);
      ok = lightOk && ok;
      if (speed == null) {
        LogBuffer.instance.add('[网页] 设置 ${p.name}: '
            '腔灯${light ? '开' : '关'} ${lightOk ? '已发送' : '失败(打印机未连接?)'}');
      }
    }
    return <String, dynamic>{
      'ok': ok,
      'printer': p.name,
      if (speed != null) 'speed': speed,
      if (speed != null) 'confirmed': speedConfirmed,
      if (light != null) 'light': light,
      if (speedError != null) 'error': speedError,
      if (!ok && speedError == null) 'error': '局域网直发失败(打印机未连接或不在局域网)',
      if (ok && speed != null && !speedConfirmed)
        'note': speedNote ??
            '速度已发给打印机，但打印机没有确认切档'
                '（不在打印中时通常不生效）',
    };
  }

  Future<Map<String, dynamic>> _camera(String cameraId,
      {bool? flipH, int? rotationDeg, RtspQuality? quality}) async {
    CameraProfile? cam;
    for (final c in hub.cameras) {
      if (c.id == cameraId) cam = c;
    }
    if (cam == null) {
      return <String, dynamic>{'ok': false, 'error': '摄像头已不存在'};
    }
    final updated = cam.copyWith(
      flipH: flipH,
      rotationDeg: rotationDeg,
      quality: quality,
    );
    hub.cameras = [
      for (final c in hub.cameras) c.id == cameraId ? updated : c,
    ];
    config = HubConfig(
      settings: config.settings,
      printers: config.printers,
      cameras: hub.cameras,
      accounts: config.accounts,
    );
    await saveHubConfig(config, configFile);
    LogBuffer.instance.add('[网页] 摄像头 ${cam.name}: '
        '${flipH == null ? '' : '翻转${flipH ? '开' : '关'} '}'
        '${rotationDeg == null ? '' : '旋转$rotationDeg° '}'
        '${quality == null ? '' : '${quality == RtspQuality.sub ? '子' : '主'}码流'}');
    return <String, dynamic>{
      'ok': true,
      'camera': cameraId,
      if (flipH != null) 'flipH': flipH,
      if (rotationDeg != null) 'rotation': rotationDeg,
      if (quality != null) 'quality': quality.name,
    };
  }

  Future<void> _mute(bool muted) async {
    if (config.settings.cameraMuted != muted) {
      config = HubConfig(
        settings: config.settings.copyWith(cameraMuted: muted),
        printers: config.printers,
        cameras: config.cameras,
        accounts: config.accounts,
      );
      hub.settings = config.settings;
      await saveHubConfig(config, configFile);
    }
    LogBuffer.instance.add('[网页] 摄像头声音${muted ? '已静音' : '已恢复'}');
  }

  // -- 云账号管理（产品化 2026-10-28） ------------------------------------
  //
  // 网页登录向导的三个入口。落盘后 bin/hub.dart 的 mtime 监视会退出重启，
  // 新账号/暂定/退出一律经「保存→自动重启」生效（守护循环 3 秒内拉起）。

  Future<Map<String, dynamic>> _cloudLogin(Map<String, dynamic> body) async {
    final regionName = (body['region'] ?? 'cn').toString().trim();
    final CloudRegion region;
    try {
      region = CloudRegion.values.byName(regionName);
    } catch (_) {
      return {'ok': false, 'error': '未知区域 $regionName'};
    }
    final account = (body['account'] ?? '').toString().trim();
    final password = (body['password'] ?? '').toString();
    final code = (body['code'] ?? '').toString();
    if (account.isEmpty) return {'ok': false, 'error': '请输入账号'};
    if (password.isEmpty && code.isEmpty) {
      return {'ok': false, 'error': '请输入密码或验证码'};
    }

    // 1. 登录（密码或验证码；TOTP 账号引导走验证码路径）。
    final String token;
    try {
      final outcome = await cloudLogin(
        region: region,
        account: account,
        password: password.isEmpty ? null : password,
        code: code.isEmpty ? null : code,
      ).timeout(const Duration(seconds: 25));
      if (outcome is LoginNeedsTfa) {
        return {
          'ok': false,
          'needsCode': true,
          'error': '该账号开启了两步验证，请改用邮箱验证码登录',
        };
      }
      if (outcome is LoginNeedsEmailCode) {
        return {
          'ok': false,
          'needsCode': true,
          'error': '该账号需要验证码，请先点「发送验证码」',
        };
      }
      token = (outcome as LoginToken).token;
    } on TimeoutException {
      return {'ok': false, 'error': '登录超时，请重试'};
    } catch (e) {
      return {'ok': false, 'error': '登录失败: ${_oneLine(e)}'};
    }

    // 2. 设备清单 + uid（uid 给云 MQTT 用；拉不到设备则当次登录作废重试）。
    final List<CloudDevice> devices;
    try {
      devices = await fetchCloudDevices(token, region)
          .timeout(const Duration(seconds: 25));
    } catch (e) {
      return {'ok': false, 'error': '登录成功但拉取设备失败: ${_oneLine(e)}'};
    }
    var uid = '';
    try {
      uid = await resolveCloudUserId(token, region)
              .timeout(const Duration(seconds: 15)) ??
          '';
    } catch (_) {}

    // 3. upsert 账号（同账号同区域复用既有 id），合并设备，落盘。
    final idx = config.accounts
        .indexWhere((a) => a.account == account && a.region == region);
    final acc = CloudAccount(
      id: idx >= 0
          ? config.accounts[idx].id
          : 'a${uid.isNotEmpty ? uid.replaceFirst('u_', '') : DateTime.now().millisecondsSinceEpoch}',
      region: region,
      account: account,
      accessToken: token,
      userId: uid,
      suspended: false,
      createdAt:
          idx >= 0 ? config.accounts[idx].createdAt : DateTime.now().millisecondsSinceEpoch,
    );
    final accounts = [...config.accounts];
    if (idx >= 0) {
      accounts[idx] = acc;
    } else {
      accounts.add(acc);
    }
    final (printers, _) = mergeCloudDevices(
        printers: config.printers, account: acc, devices: devices);
    config = HubConfig(
      settings: config.settings,
      printers: printers,
      cameras: config.cameras,
      accounts: accounts,
    );
    hub.accounts = accounts;
    await saveHubConfig(config, configFile);
    LogBuffer.instance.add('[云同步] $account 登录成功，'
        '${devices.length} 台设备已同步（重启加载）');
    return {
      'ok': true,
      'count': devices.length,
      'devices': [
        for (final d in devices)
          {
            'serial': d.devId,
            'name': d.devName.isNotEmpty ? d.devName : d.productName,
            'model': d.productName.isNotEmpty ? d.productName : d.modelName,
            'online': d.online,
            'hasCode': d.accessCode.isNotEmpty,
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _accountsStatus() async => {
        'ok': true,
        'accounts': [
          for (final a in config.accounts)
            {
              'id': a.id,
              'account': a.account,
              'region': a.region.name,
              'suspended': a.suspended,
              'printers': config.printers.where((p) => p.accountId == a.id).length,
              ..._syncStatusJson(a.id),
            },
        ],
      };

  Map<String, dynamic> _syncStatusJson(String accountId) {
    final s = cloudSync.status[accountId];
    if (s == null) return const {};
    return {
      'syncOk': s.ok,
      'syncAt': s.at.toIso8601String(),
      'syncCount': s.count,
      if (s.error.isNotEmpty) 'syncError': s.error,
    };
  }

  Future<Map<String, dynamic>> _accountUpdate(Map<String, dynamic> body) async {
    final id = (body['id'] ?? '').toString();
    final action = (body['action'] ?? '').toString();
    final idx = config.accounts.indexWhere((a) => a.id == id);
    if (idx < 0) return {'ok': false, 'error': '账号不存在'};
    final name = config.accounts[idx].account;
    var accounts = config.accounts;
    var printers = config.printers;
    switch (action) {
      case 'suspend':
        accounts = [...accounts]..[idx] = accounts[idx].copyWith(suspended: true);
      case 'resume':
        accounts = [...accounts]..[idx] = accounts[idx].copyWith(suspended: false);
      case 'logout':
        accounts = [...accounts]..removeAt(idx);
        printers = printers.where((p) => p.accountId != id).toList();
      default:
        return {'ok': false, 'error': '未知操作 $action'};
    }
    config = HubConfig(
      settings: config.settings,
      printers: printers,
      cameras: config.cameras,
      accounts: accounts,
    );
    hub.accounts = accounts;
    await saveHubConfig(config, configFile);
    LogBuffer.instance.add('[云同步] 账号 $name: $action 已保存');
    return {'ok': true};
  }

  String _oneLine(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}
