import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'camera_profile.dart';
import 'cloud_print_helper.dart';
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

    LogBuffer.instance.add('[独立服务] 载入 ${config.printers.length} 台打印机、'
        '${config.cameras.length} 个摄像头 (${configFile.path})');
    for (final p in config.printers) {
      _connect(p);
    }

    await hub.start();
  }

  Future<void> stop() async {
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
      );
      hub.settings = config.settings;
      await saveHubConfig(config, configFile);
    }
    LogBuffer.instance.add('[网页] 摄像头声音${muted ? '已静音' : '已恢复'}');
  }
}
