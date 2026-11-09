import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
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
import 'data/hub_rescue.dart';
import 'data/hub_server.dart';
import 'data/file_secure_storage.dart';
import 'data/hub_service_control.dart';
import 'data/log_buffer.dart';
import 'data/plate_swap.dart';
import 'data/print_events.dart';
import 'data/lan_printer_probe.dart' show needsLanIp;
import 'data/printer_profile.dart';
import 'data/rtsp_quality.dart';
import 'data/settings_providers.dart';
import 'data/vision_guard.dart';
import 'data/providers.dart';
import 'features/home/home_page.dart';
import 'features/settings/update_reminder.dart';

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

  // 版本更新提醒: 检查全自动 (启动后 8s + 每 12h), 有新版弹窗由人决定装不装。
  UpdateReminder.start();

  // 存储后端(2026-11-03 根治「更新后数据被清空」):
  // Keychain 的访问判定挂在代码签名身份上 —— DP Keychain 在 CI 的 adhoc 包
  // (无 entitlements)下整体砖化(读空/写抛,2026-11-02 事故根源),legacy
  // Keychain 换签名要重新授权、无人值守时读会被拒。macOS 改用 0600 文件
  // (~/.bambudeck/secure_store.json),与签名身份完全解耦,更新永不触碰;
  // 启动前把 Keychain 里还能读出的历史数据种子合并进来(文件为权威,只补缺
  // —— DP 条目里可能有丢掉的访问码/萤石密钥)。其他平台维持原样。
  final SecureStorageAdapter storageAdapter;
  if (!kIsWeb && Platform.isMacOS) {
    final fileStore = FileSecureStorage(
        '${Platform.environment['HOME'] ?? '.'}/.bambudeck/secure_store.json');
    try {
      await seedFileStore(fileStore);
    } catch (e) {
      // 种子迁移失败不阻断启动:文件存储自身照常用,hub_rescue 兜底。
      debugPrint('[存储] Keychain 种子迁移失败: $e');
    }
    storageAdapter = fileStore;
  } else {
    storageAdapter = const SecureAdapter(FlutterSecureStorage());
  }
  runApp(ProviderScope(
    overrides: [
      storeProvider.overrideWith(
          (ref) => SecurePrinterStore(storage: storageAdapter)),
      settingsStoreProvider.overrideWith(
          (ref) => SecureSettingsStore(storage: storageAdapter)),
      cameraStoreProvider.overrideWith(
          (ref) => SecureCameraStore(storage: storageAdapter)),
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
      // 串行化: 快速连续改设置时避免并发 probe/start 抢同一个服务管理器。
      _hubSyncChain = _hubSyncChain.then((_) => _syncHub(s));
    }

    // 启动自救必须先于第一批导出(见 _startupHubRescue / _exportHub 门)。
    unawaited(_startupHubRescue());

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
        // 摄像头清单和打印机清单谁先加载完不确定: 打印机先到时补挂会因
        // 摄像头还没载入而跳过,这里在摄像头落位后再补一次,幂等。
        final printersNow = ref.read(printersProvider).valueOrNull;
        if (printersNow != null) {
          unawaited(_ensureBuiltinCams(printersNow));
        }
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
        // 云端添加的打印机 (有访问码没 IP): 补一次 LAN 发现, 命中就升级
        // LAN 直连 —— 机内摄像头的开关只对 LAN 模式放开 (2026-10-31)。
        // 自救完成后再补扫:盘上补回的 ip 通常已让补扫无事可做,也避免
        // 慢速发现结果回头覆盖自救合回来的清单。
        if (_hubRescueDone && !_lanBackfillRan && list.any(needsLanIp)) {
          _lanBackfillRan = true;
          unawaited(backfillLanIps(
              ref.read(printersProvider.notifier), list,
              log: LogBuffer.instance.add));
        }
        // 机内摄像头自动补挂(2026-11-03 / 2026-11-09): 打印机有访问码就补
        // 一台绑定的机内摄像头(先离线形态,补扫到 IP 后自动亮)。每轮都跑,
        // 幂等;用户手删过的按墓碑跳过,不会被复活。
        unawaited(_ensureBuiltinCams(list));
      }
    }, fireImmediately: true);
  }

  /// 把当前 printers/cameras/settings 导出到 `~/.bambudeck/hub.json`, 供独立
  /// 网页服务(bin/hub.dart)读取。内容含局域网访问码/摄像头地址等凭据, 故只写
  /// 家目录(与 helper.json / signing_key.pem 同级信任)。
  ///
  /// 产品化(2026-10-28):accounts 段(网页登录的云账号)与 accountId 归属的
  /// 打印机是网页服务(云同步)的地盘, App 导出不得覆盖 —— 按盘上现有文件合并:
  /// 云账号原样带回, 云账号名下的打印机在 App 本地清单之外原样追加。
  /// 导出排队(2026-11-03): 打印机/摄像头在同一次操作里连续变化时,
  /// [_exportHub] 会被连发多次。以前每次各自异步读盘再写盘,先读到旧快照
  /// 的那次可能后落盘 —— 云端补码那一刻实测: secure_store 已经写进 4 个
  /// 摄像头,hub.json 里却只剩 1 个,网页端就少了三台机内摄像头。现在串行
  /// 执行,并在真正执行时才读 provider: 拿到的永远是最新状态;执行期间的新
  /// 触发只置脏标,排到下一轮再导一次。
  Future<void> _exportChain = Future<void>.value();
  bool _exportDirty = false;

  void _exportHub() {
    // 自救(启动回填)完成前不许写盘 —— 否则 Keychain 降级状态会先冲掉盘上
    // 的完整数据,自救就没了数据源(2026-11-02 19:56 的数据丢失正是这个顺序)。
    if (!_hubRescueDone) return;
    _exportDirty = true;
    _exportChain = _exportChain.then((_) async {
      if (!_exportDirty) return;
      _exportDirty = false;
      try {
        await _exportHubNow();
      } catch (e) {
        LogBuffer.instance.add('[导出] hub.json 写入失败: $e');
      }
    });
  }

  Future<void> _exportHubNow() async {
    final printers = ref.read(printersProvider).valueOrNull;
    final cameras = ref.read(camerasProvider).valueOrNull;
    final settings = ref.read(appSettingsProvider).valueOrNull;
    // 三个 provider 任一还在载入就不导出: 用空列表兜底会把「半空状态」写盘,
    // 冷启动 Keychain 慢时尤其危险(hub.log 里 0/0→1/0→1/1 的渐进重载即此)。
    if (settings == null || printers == null || cameras == null) return;
    final disk = await loadHubConfig();
    // 非破坏性导出(2026-11-03):设置段里 App 空着的密钥/地址类字段一律用
    // 盘上值补(rescueSettings 的补空逻辑复用, 含 hubToken)。Keychain 一旦
    // 降级,导出再也不能成为「把盘上密钥冲掉」的第二事故源。
    final settingsOut = rescueSettings(settings, disk.settings) ?? settings;
    // 打印机段:App 清单可能因存储降级而少(不是用户删的)。只有墓碑里的
    // 那台才允许消失,其余以盘上为准 —— 导出不再是「把盘上清空」的第二
    // 事故源(2026-11-03 事故链最后一环)。
    final pStore = ref.read(storeProvider);
    final tombstones = pStore is TombstoneStore
        ? await (pStore as TombstoneStore).loadTombstones()
        : const <String>{};
    final merged = mergeExportPrinters(
        app: printers, disk: disk.printers, tombstoned: tombstones);
    // 摄像头段:同样只让「用户显式删过的」消失。
    final cStore = ref.read(cameraStoreProvider);
    final camTombstones = cStore is TombstoneStore
        ? await (cStore as TombstoneStore).loadTombstones()
        : const <String>{};
    final mergedCams = [
      ...cameras,
      for (final c in disk.cameras)
        if (!cameras.any((q) => q.id == c.id) &&
            !camTombstones.contains('c:${c.id}'))
          c,
    ];
    await saveHubConfig(HubConfig(
      settings: settingsOut,
      printers: merged,
      cameras: mergedCams,
      accounts: disk.accounts,
    ));
  }

  /// Start/stop the web hub (网页访问) with its switch (2026-10-31 重构).
  ///
  /// 装了独立 hub 服务(mac launchd / Windows 计划任务)的机器: 开关打开就把
  /// 独立服务拉起(幂等), 内置网页服务让位 —— 独立服务不随 App 退出而停。
  /// **「关」不在这里执行**: App 启动/改配置都不该顺手把正在跑的服务停掉
  /// (比如盒子上手工装好的 hub 不该被一次无关的设置改动杀掉), 停止只发生
  /// 在设置页里明确的开关动作(settings_page._stopStandalone)。
  /// 没装独立服务的机器保持原行为: 内置服务, 随 App 存活。
  Future<void> _syncHub(AppSettings s) async {
    hubServer.settings = s;
    final svc = HubServiceControl.instance;
    if (svc.supported) {
      final st = await svc.probe(s);
      if (st.installed) {
        // 独立服务接管 8787, 内置服务停掉避免抢端口。
        if (hubServer.running) await hubServer.stop();
        if (s.hubEnabled) {
          final err = await svc.start(s);
          if (err != null) {
            svc.lastStatus = HubServiceStatus(
                installed: true,
                serving: svc.lastStatus.serving,
                error: err);
            LogBuffer.instance.add('[网页服务] 独立服务启动失败: $err');
          }
        }
        return;
      }
    }
    if (s.hubEnabled && (!hubServer.running || hubServer.port != s.hubPort)) {
      await hubServer.stop().whenComplete(hubServer.start);
    } else if (!s.hubEnabled && hubServer.running) {
      await hubServer.stop();
    }
  }

  Future<void> _hubSyncChain = Future.value();

  /// 云端添加的打印机缺 IP: 启动后补一次 LAN 发现 (每次进程生命周期一次,
  /// 失败等下次启动, 不重试风暴 —— 与独立服务 _resolveLanIps 同策略)。
  bool _lanBackfillRan = false;

  /// 启动自救是否已完成; 完成前 _exportHub 一律不写盘。
  bool _hubRescueDone = false;

  /// 自动补机内摄像头正在跑,避免并发两轮各算一份清单。
  bool _ensuringBuiltin = false;

  /// 有访问码的打印机自动补一台绑定的机内摄像头 (2026-11-03 需求,
  /// 2026-11-09 放宽): 手机上用云端账号一键添加打印机后,摄像头要自己出现。
  ///
  /// 以前只在「凭据发生变化」时补,新装的 App 第一次看到打印机时凭据
  /// 指纹是空的,永远不触发 —— 手机端因此一台机内摄像头都不会有。
  /// 现在每轮都跑: 用户显式删掉的按相机墓碑跳过,不会复活;幂等,没得补
  /// 就返回 null 不落盘。
  Future<void> _ensureBuiltinCams(List<PrinterProfile> list) async {
    if (_ensuringBuiltin) return;
    final cameras = ref.read(camerasProvider).valueOrNull;
    if (cameras == null) return; // 摄像头清单未载入,无从判断「已有绑定」
    _ensuringBuiltin = true;
    try {
      var deleted = const <String>{};
      final store = ref.read(cameraStoreProvider);
      if (store is TombstoneStore) {
        try {
          // CameraStore 与 TombstoneStore 是互不相干的接口,静态类型不会
          // 被 is 提升,显式转型。
          deleted = await (store as TombstoneStore).loadTombstones();
        } catch (_) {
          // 墓碑读不出来不该挡住自动补挂,只是可能复活一条手删条目。
        }
      }
      final next =
          ensureBuiltinCameras(list, cameras, deletedIds: deleted);
      if (next == null) return;
      await ref.read(camerasProvider.notifier).replaceAll(next);
      LogBuffer.instance.add('[摄像头] 打印机有访问码,已自动添加机内摄像头');
    } catch (e) {
      LogBuffer.instance.add('[摄像头] 自动添加机内摄像头失败: $e');
    } finally {
      _ensuringBuiltin = false;
    }
  }

  /// 启动自救(2026-11-02 事故修复): App 的 printers/cameras/settings 存
  /// Keychain, 更新换包(adhoc 签名每次构建身份不同)会让部分条目读不出来
  /// 或回到默认; ~/.bambudeck/hub.json 保有最近一次完整导出。在首导出前按
  /// 「本地为权威, 只补本地缺的」合回盘上数据, 完成后才放行导出与 LAN 补扫。
  Future<void> _startupHubRescue() async {
    // 三段(设置/打印机/摄像头)各自独立落位:一段失败(比如 Keychain 拒写,
    // adhoc 换包后实测会发生)不再拖垮其余两段 —— 2026-11-03 早上的实测就是
    // settings 写 Keychain 抛异常,后面打印机/摄像头的合并全被跳过。
    var ok = true;
    try {
      final disk = await loadHubConfig();
      final settings = await ref.read(appSettingsProvider.future);
      final printers = await ref.read(printersProvider.future);
      final cameras = await ref.read(camerasProvider.future);
      final r = rescueHubData(
          settings: settings,
          printers: printers,
          cameras: cameras,
          disk: disk);
      if (r.settings != null) {
        try {
          await ref.read(appSettingsProvider.notifier).set(r.settings!);
          LogBuffer.instance.add('[自救] 设置已从 hub.json 补回'
              '(${settingsLookDefault(settings) ? '本地整包丢失, 整包采纳' : '补空字段'})');
        } catch (e) {
          ok = false;
          LogBuffer.instance.add('[自救] 设置补回失败: $e');
        }
      }
      if (r.printers != null) {
        try {
          await ref.read(printersProvider.notifier).replaceAll(r.printers!);
          LogBuffer.instance.add('[自救] 打印机清单已按 hub.json 补齐 '
              '(${r.printers!.length} 台)');
        } catch (e) {
          ok = false;
          LogBuffer.instance.add('[自救] 打印机补回失败: $e');
        }
      }
      if (r.cameras != null) {
        try {
          await ref.read(camerasProvider.notifier).replaceAll(r.cameras!);
          LogBuffer.instance.add('[自救] 摄像头清单已从 hub.json 补回 '
              '(${r.cameras!.length} 个)');
        } catch (e) {
          ok = false;
          LogBuffer.instance.add('[自救] 摄像头补回失败: $e');
        }
      }
      if (ok && r.settings == null && r.printers == null && r.cameras == null) {
        LogBuffer.instance.add('[自救] 本地数据完整, 无需回填');
      }
    } catch (e) {
      ok = false;
      LogBuffer.instance.add('[自救] 失败: $e');
    } finally {
      _hubRescueDone = true;
      if (ok) {
        _exportHub();
      } else {
        // 救援没全成功就导出 = 把降级状态写回盘上,冲掉自救的数据源。
        // 暂停本次导出,盘上 hub.json 原样保住,重启再试。
        LogBuffer.instance.add('[自救] 有段失败, 本次暂停导出 —— 保住盘上数据');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BambuDeck',
      debugShowCheckedModeBanner: false,
      navigatorKey: deckNavKey,
      theme: buildDeckTheme(),
      home: const HomePage(),
    );
  }
}
