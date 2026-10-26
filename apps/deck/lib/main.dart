import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'data/app_settings.dart';
import 'data/camera_audio.dart';
import 'data/camera_profile.dart';
import 'data/camera_providers.dart';
import 'data/cloud_print_helper.dart';
import 'data/hub_config.dart';
import 'data/hub_server.dart';
import 'data/log_buffer.dart';
import 'data/plate_swap.dart';
import 'data/print_events.dart';
import 'data/printer_profile.dart';
import 'data/rtsp_quality.dart';
import 'data/settings_providers.dart';
import 'data/vision_guard.dart';
import 'data/providers.dart';
import 'features/home/home_page.dart';

/// flutter_secure_storage backed adapter (Keychain / Credential Manager /
/// Keystore depending on platform).
class SecureAdapter implements SecureStorageAdapter {
  const SecureAdapter(this._storage);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// flutter_local_notifications implementation of the app seam.
class LocalDeckNotifier implements DeckNotifier {
  LocalDeckNotifier(this._plugin);

  final FlutterLocalNotificationsPlugin _plugin;
  var _id = 1;

  @override
  Future<void> show({required String title, required String body}) {
    return _plugin.show(
      id: _id++,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized(); // libmpv for camera streams (FR-3)

  // print 命令走未签名直发: 2025+ 固件对未签名 print 帧回 84033543,唯一
  // 实用解是打印机开「开发者模式」(设置→网络→仅局域网模式→开发者模式,再
  // 重启)。签名信封补不了这块——开发者模式关时固件还要求 url_enc/param_enc
  // 字段加密 + app_cert_install 装证书,缺了照样静默失败(换盘 2026-10-21)。
  // 私钥路径 ~/.bambudeck/signing_key.pem 已停用,避免过期私钥的法律风险。
  LogBuffer.instance.add('[签名] 未签名直发(需打印机开启开发者模式)');

  // 网页页面与换盘模型: App 从打包资产读; 独立服务(bin/hub.dart)读磁盘文件。
  hubServer.pageLoader = () => rootBundle.loadString(kHubPageAsset);
  plateSwapBytesLoader = () async =>
      (await rootBundle.load(kPlateSwapAsset)).buffer.asUint8List();

  // Desktop notifications: init asks macOS for permission on first run.
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        macOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestSoundPermission: true,
        ),
      ),
    );
    deckNotifier = LocalDeckNotifier(plugin);
  } catch (e) {
    // Notifications are best-effort; the app must run without them.
    debugPrint('notification init failed: $e');
  }

  runApp(ProviderScope(
    overrides: [
      storeProvider.overrideWith(
          (ref) => SecurePrinterStore(storage: const SecureAdapter(
                FlutterSecureStorage(),
              ))),
      settingsStoreProvider.overrideWith(
          (ref) => SecureSettingsStore(storage: const SecureAdapter(
                FlutterSecureStorage(),
              ))),
      cameraStoreProvider.overrideWith(
          (ref) => SecureCameraStore(storage: const SecureAdapter(
                FlutterSecureStorage(),
              ))),
    ],
    child: const DeckApp(),
  ));
}

class DeckApp extends ConsumerStatefulWidget {
  const DeckApp({super.key});

  @override
  ConsumerState<DeckApp> createState() => _DeckAppState();
}

class _DeckAppState extends ConsumerState<DeckApp> {
  @override
  void initState() {
    super.initState();
    // Keep the notification watcher's switches in step with settings.
    // 视觉守卫自动暂停与仪表盘控制按钮同一路由: LAN + 开发者模式确认为开 →
    // LAN MQTT 直发(秒回); 其余(云 / dev-OFF) → Bambu Connect 自动化(全链路 ~8s)。
    visionGuard.pauseCommand = (printerId) async {
      final profile =
          printerByIdOf(ref.read(printersProvider).valueOrNull, printerId);
      if (profile == null) return false;
      if (profile.serial.trim().isEmpty) {
        LogBuffer.instance
            .add('[视觉] 自动暂停失败: ${profile.name} 未配置序列号');
        return false;
      }
      final state = ref.read(connectionProvider(printerId)).state;
      if (useLanControl(profile, state)) {
        final ok =
            await ref.read(connectionProvider(printerId).notifier).pause();
        LogBuffer.instance.add(
            '[视觉] 自动暂停 ${profile.name}: 局域网直发${ok ? "已发送" : "失败"}');
        return ok;
      }
      final r =
          await CloudPrintHelper.instance.control(profile.serial, 'pause');
      if (!r.ok) {
        LogBuffer.instance.add('[视觉] 自动暂停失败: ${r.error ?? "未知错误"}');
      }
      return r.ok;
    };
    // 网页端(手机/平板浏览器)的暂停、继续、停止与一键换盘: 和 App 内按钮
    // 走同一条路由 —— dev-ON 局域网直发, 其余走 Bambu Connect helper。
    hubServer.controlHandler = (profile, command) async {
      final state = ref.read(connectionProvider(profile.id)).state;
      if (useLanControl(profile, state)) {
        final n = ref.read(connectionProvider(profile.id).notifier);
        final ok = switch (command) {
          'pause' => await n.pause(),
          'resume' => await n.resume(),
          'stop' => await n.stop(),
          _ => false,
        };
        LogBuffer.instance.add(
            '[网页] $command ${profile.name}: 局域网直发${ok ? "已发送" : "失败"}');
        return <String, dynamic>{
          'ok': ok,
          'command': command,
          'printer': profile.name,
          'method': 'lan',
          if (!ok) 'error': '局域网直发失败(检查开发者模式与网络)',
        };
      }
      if (profile.serial.trim().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': '「${profile.name}」未配置序列号, Connect 自动化无法定位打印机',
        };
      }
      final r = await CloudPrintHelper.instance.control(profile.serial, command);
      LogBuffer.instance.add('[网页] ${r.command ?? command} ${profile.name}: '
          'ok=${r.ok}${r.error == null ? '' : ' err=${r.error}'}');
      return <String, dynamic>{
        'ok': r.ok,
        'command': r.command ?? command,
        'printer': r.printer ?? profile.name,
        'method': r.method ?? 'connect',
        if (r.elapsed != null) 'elapsed': r.elapsed,
        if (r.error != null) 'error': r.error,
      };
    };
    hubServer.plateSwapHandler = (profile) async {
      if (profile.serial.trim().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': '「${profile.name}」未配置序列号, Connect 自动化无法定位打印机',
        };
      }
      if (!await CloudPrintHelper.instance.health()) {
        return <String, dynamic>{
          'ok': false,
          'error': '打印服务不可用（Mac 上的 bconnect_service.py 没在跑）',
        };
      }
      final r = await startCloudPlateSwap(profile);
      LogBuffer.instance.add('[网页] 换盘 ${profile.name}: ok=${r.ok}'
          '${r.error == null ? '' : ' err=${r.error}'}');
      return <String, dynamic>{
        'ok': r.ok,
        'printer': profile.name,
        if (r.taskId != null) 'task': r.taskId,
        if (r.taskStatus != null) 'taskStatus': r.taskStatus,
        if (r.elapsedTotal != null) 'elapsed': r.elapsedTotal,
        if (r.error != null) 'error': r.error,
        // CloudPrintStep 不是 JSON 原生类型；直接塞进去会让整个响应编码失败，
        // 换盘明明成功了网页却收到 500。
        'steps': r.steps.map((s) => s.toJson()).toList(),
      };
    };
    // 网页端速度档位 / 腔灯。调速和 App 控制卡一样走 Bambu Connect 自动化
    // (点 Connect 设备页的档位按钮, 由 Connect 用官方身份发 print_speed),
    // 腔灯仍发到本机 MQTT 连接 —— 固件拦的是 App 自己发的 print_speed。
    hubServer.setHandler = (profile, {speed, light}) async {
      final n = ref.read(connectionProvider(profile.id).notifier);
      var ok = true;
      var speedConfirmed = true;
      String? speedNote;
      String? speedError;
      if (speed != null) {
        if (profile.serial.trim().isEmpty) {
          ok = false;
          speedError = '「${profile.name}」未配置序列号，Connect 自动化无法定位打印机';
        } else if (!await CloudPrintHelper.instance.health()) {
          // helper 没跑: 退回局域网直发。结果如实标注「未确认」——publish
          // 成功不代表改档成功, 别让网页显示「已发送」。
          final r = await n.setSpeedConfirmed(speed);
          ok = r.sent && ok;
          speedConfirmed = r.confirmed;
          speedNote = r.note;
          if (!r.sent) speedError = '局域网直发失败(打印机未连接或不在局域网)';
          LogBuffer.instance.add('[网页] 速度${speedLevelName(speed)} '
              '${profile.name}: 局域网直发${r.sent ? '' : '失败'}'
              '${r.confirmed ? '' : '(未确认)'} (Connect 服务未运行)');
        } else {
          final r = await CloudPrintHelper.instance.control(
            profile.serial,
            'speed',
            params: {'level': speed},
            timeout: const Duration(seconds: 45),
          );
          ok = r.ok && ok;
          // Connect 界面上的百分比要绕云端一圈才刷新 (2~20s), 不能当确认。
          // 用局域网状态帧里的 spd_lvl 收口 —— 打印机直报的, 秒级。
          speedConfirmed =
              r.ok && await n.awaitSpeed(speed, within: const Duration(seconds: 10));
          if (r.ok && !speedConfirmed) {
            speedNote = '已在 Bambu Connect 点了这一档，但打印机还没回报新档位'
                '（不在打印中时通常不生效）';
          }
          LogBuffer.instance.add('[网页] 速度${speedLevelName(speed)} '
              '${profile.name}: via Connect ok=${r.ok}'
              '${r.ok ? (speedConfirmed ? ' 已确认' : ' 未确认') : ''}'
              '${r.error == null ? '' : ' err=${r.error}'}'
              '${r.elapsed == null ? '' : ' ${r.elapsed!.round()}s'}');
          if (!r.ok) speedError = r.error ?? 'Connect 调速失败';
        }
      }
      if (light != null) ok = await n.setLight(light) && ok;
      if (speed == null && light != null) {
        LogBuffer.instance.add('[网页] 设置 ${profile.name}: '
            '腔灯${light ? '开' : '关'} ${ok ? '已发送' : '失败(打印机未连接?)'}');
      }
      return <String, dynamic>{
        'ok': ok,
        'printer': profile.name,
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
    };
    // 网页端摄像头按钮 (和 App 的 CameraTile 一一对应):
    // 翻转/旋转/码流写回摄像头配置, 静音切全局设置并立刻作用到正在播放的画面上。
    hubServer.connStatusOf = (printerId) =>
        ref.read(connectionProvider(printerId)).status.name;
    hubServer.cameraHandler = (cameraId,
        {bool? flipH, int? rotationDeg, RtspQuality? quality}) async {
      final list = ref.read(camerasProvider).valueOrNull ?? const [];
      CameraProfile? cam;
      for (final c in list) {
        if (c.id == cameraId) cam = c;
      }
      if (cam == null) {
        return <String, dynamic>{'ok': false, 'error': '摄像头已不存在'};
      }
      await ref.read(camerasProvider.notifier).replace(cam.copyWith(
            flipH: flipH,
            rotationDeg: rotationDeg,
            quality: quality,
          ));
      // 立刻同步给网页快照, 不等 provider 监听的下一次调度 —— 页面收到响应
      // 就会马上换 src 重拉流, 那时代码必须已经读到新配置。
      hubServer.cameras = ref.read(camerasProvider).valueOrNull ?? list;
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
    };
    hubServer.muteHandler = (muted) async {
      final s = ref.read(appSettingsProvider).valueOrNull;
      if (s == null) return;
      if (s.cameraMuted != muted) {
        await ref
            .read(appSettingsProvider.notifier)
            .set(s.copyWith(cameraMuted: muted));
      }
      cameraAudioBus.apply(muted);
      LogBuffer.instance.add('[网页] 摄像头声音${muted ? '已静音' : '已恢复'}');
    };
    // 打印/控制服务：远程地址优先（手机/平板），留空则用本机 helper.json。
    void syncService(AppSettings s) {
      CloudPrintHelper.instance.settings = s;
      printEvents.settings = s;
      visionGuard.settings = s;
      _syncHub(s);
    }

    final loaded = ref.read(appSettingsProvider).valueOrNull;
    if (loaded != null) syncService(loaded);
    ref.listenManual(appSettingsProvider, (_, next) {
      final s = next.valueOrNull;
      if (s != null) {
        syncService(s);
        _exportHub();
      }
    });
    ref.listenManual(camerasProvider, (_, next) {
      final list = next.valueOrNull;
      if (list != null) {
        visionGuard.cameras = list;
        hubServer.cameras = list;
        _exportHub();
      }
    }, fireImmediately: true);
    ref.listenManual(printersProvider, (_, next) {
      final list = next.valueOrNull;
      if (list != null) {
        // The headless vision grab needs the bound printer for a Bambu
        // camera's IP / access code.
        visionGuard.printers = list;
        hubServer.printers = list;
        _exportHub();
      }
    }, fireImmediately: true);
  }

  /// 把当前 printers/cameras/settings 导出到 `~/.bambudeck/hub.json`, 供独立
  /// 网页服务(bin/hub.dart)读取。内容含局域网访问码/摄像头地址等凭据, 故只写
  /// 家目录(与 helper.json / signing_key.pem 同级信任)。
  void _exportHub() {
    final printers = ref.read(printersProvider).valueOrNull ?? const [];
    final cameras = ref.read(camerasProvider).valueOrNull ?? const [];
    final settings = ref.read(appSettingsProvider).valueOrNull;
    if (settings == null) return;
    unawaited(saveHubConfig(HubConfig(
      settings: settings,
      printers: printers,
      cameras: cameras,
    )));
  }

  /// Start/stop the web hub (网页访问) with its switch; a port change while
  /// running restarts the listener.
  void _syncHub(AppSettings s) {
    hubServer.settings = s;
    if (s.hubEnabled && (!hubServer.running || hubServer.port != s.hubPort)) {
      hubServer.stop().whenComplete(hubServer.start);
    } else if (!s.hubEnabled && hubServer.running) {
      hubServer.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BambuDeck',
      debugShowCheckedModeBanner: false,
      theme: buildDeckTheme(),
      home: const HomePage(),
    );
  }
}
