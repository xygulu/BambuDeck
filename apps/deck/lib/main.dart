import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:media_kit/media_kit.dart';

import 'core/theme.dart';
import 'data/app_settings.dart';
import 'data/camera_profile.dart';
import 'data/print_events.dart';
import 'data/printer_profile.dart';
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
    ref.listenManual(appSettingsProvider, (_, next) {
      final s = next.valueOrNull;
      if (s != null) printEvents.settings = s;
    });
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
