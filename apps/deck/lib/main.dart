import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'data/app_settings.dart';
import 'data/camera_profile.dart';
import 'data/cloud_print_helper.dart';
import 'data/hub_server.dart';
import 'data/log_buffer.dart';
import 'data/print_events.dart';
import 'data/printer_profile.dart';
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
    ref.listenManual(appSettingsProvider, (_, next) {
      final s = next.valueOrNull;
      if (s != null) {
        printEvents.settings = s;
        visionGuard.settings = s;
        _syncHub(s);
      }
    });
    ref.listenManual(camerasProvider, (_, next) {
      final list = next.valueOrNull;
      if (list != null) {
        visionGuard.cameras = list;
        hubServer.cameras = list;
      }
    });
    ref.listenManual(printersProvider, (_, next) {
      final list = next.valueOrNull;
      if (list != null) hubServer.printers = list;
    });
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
