import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'data/app_settings.dart';
import 'data/camera_profile.dart';
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

  // MQTT 命令签名私钥(打印类命令不签名会被新固件拒收 84033543)。文件在
  // 仓库外 ~/.bambudeck/,见 bambu_protocol/src/bambu_signing.dart -
  // 缺失只降级(未签名路径),绝不阻塞启动。
  try {
    final home = Platform.environment['HOME'];
    final keyFile = home == null ? null : File('$home/.bambudeck/signing_key.pem');
    if (keyFile != null && keyFile.existsSync()) {
      bambuSigningKeyPem = keyFile.readAsStringSync();
      LogBuffer.instance.add('[签名] 已装载命令签名私钥 (~/.bambudeck)');
    } else {
      LogBuffer.instance.add('[签名] 未找到 ~/.bambudeck/signing_key.pem,'
          '打印命令将不带签名(会被固件拒收)');
    }
  } catch (_) {
    // Best-effort - never block startup on key loading.
  }

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
    visionGuard.pauseCommand = (printerId) async =>
        await ref.read(connectionProvider(printerId).notifier).pause();
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
