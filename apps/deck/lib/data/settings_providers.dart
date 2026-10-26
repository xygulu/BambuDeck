import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';

/// Riverpod wiring for the app's settings (kept out of [AppSettings]'s file so
/// the data class / store stay pure Dart for the standalone web service).
class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() => ref.watch(settingsStoreProvider).load();

  Future<void> set(AppSettings s) async {
    state = AsyncData(s);
    await ref.read(settingsStoreProvider).save(s);
  }
}

final settingsStoreProvider = Provider<SettingsStore>(
    (ref) => throw UnimplementedError('override settingsStoreProvider'));

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
        AppSettingsNotifier.new);
