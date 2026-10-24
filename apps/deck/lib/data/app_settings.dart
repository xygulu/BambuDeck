import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'printer_profile.dart';

/// Kiosk rotation policy (PRD FR-6 自动轮换).
enum KioskMode {
  /// Normal navigation - no auto-rotate.
  off('轮播关'),

  /// Cycle every printer evenly.
  cycle('循环轮播'),

  /// Stay on printing printers; idle ones only get a slow pass.
  printingFirst('优先打印中');

  const KioskMode(this.label);
  final String label;

  KioskMode get next => KioskMode.values[(index + 1) % KioskMode.values.length];
}

/// User preferences (PRD FR-10). JSON blob in the same OS secure store as
/// the printer list; everything defaults on so first run needs no setup.
class AppSettings {
  const AppSettings({
    this.notifyOnFinish = true,
    this.notifyOnError = true,
    this.kioskMode = KioskMode.off,
    this.kioskRotateSec = 15,
    this.builtinCamDefault = true,
    this.cameraMuted = false,
    this.ezvizAppKey = '',
    this.ezvizAppSecret = '',
    this.visionEnabled = false,
    this.visionBaseUrl = 'https://open.bigmodel.cn/api/paas/v4',
    this.visionApiKey = '',
    this.visionModel = 'glm-4v-flash',
    this.visionIntervalSec = 60,
    this.visionAutoPause = false,
    this.hubEnabled = false,
    this.hubPort = 8787,
    this.hubToken = '',
    this.helperUrl = '',
    this.helperToken = '',
  });

  final bool notifyOnFinish;
  final bool notifyOnError;
  final KioskMode kioskMode;
  final int kioskRotateSec;

  /// Global built-in-camera default. Printers whose [PrinterProfile.builtinCam]
  /// is `follow` (the default tri-state) inherit this.
  final bool builtinCamDefault;

  /// Mute state for RTSP camera audio; the tile speaker toggle writes the
  /// same field, so the choice survives restarts (反馈 2026-10-20).
  final bool cameraMuted;

  /// EZVIZ open-platform credentials (萤石云端导入 2026-10-20): the AppKey/
  /// AppSecret pair from open.ys7.com, persisted with the rest of the
  /// settings in the OS secure store. The accessToken is fetched on demand
  /// and never stored - it expires in 7 days anyway.
  final String ezvizAppKey;
  final String ezvizAppSecret;

  /// Vision guard (大模型识别监控画面 2026-10-20): any OpenAI-compatible
  /// vision endpoint. glm-4v-flash (智谱) is the default - it is free and
  /// reads Chinese prompts well. The guard only runs while this is enabled
  /// AND a key is present.
  final bool visionEnabled;
  final String visionBaseUrl;
  final String visionApiKey;
  final String visionModel;
  final int visionIntervalSec;

  /// Auto-pause a print the model flagged as abnormal (suspected 炒面/空打).
  final bool visionAutoPause;

  /// Web access (服务端和网页端 2026-10-20): when on, the app serves a
  /// monitoring page (printers + live MJPEG views) on the LAN. All
  /// non-page routes require the [hubToken]; it is generated on first
  /// enable and shown in settings for the shareable URL.
  final bool hubEnabled;
  final int hubPort;
  final String hubToken;

  /// 打印/控制服务（bconnect_service.py）的网络地址与令牌。
  ///
  /// 留空 = 用本机 `~/.bambudeck/helper.json`（Mac 上跑的 app 默认就这样）。
  /// 手机/平板没有这个文件，填 `http://<Mac 的 IP>:8799` + 服务令牌即可：
  /// 自动化仍然在那台 Mac 上执行，App 只是通过网络调用它。
  final String helperUrl;
  final String helperToken;

  AppSettings copyWith({
    bool? notifyOnFinish,
    bool? notifyOnError,
    KioskMode? kioskMode,
    int? kioskRotateSec,
    bool? builtinCamDefault,
    bool? cameraMuted,
    String? ezvizAppKey,
    String? ezvizAppSecret,
    bool? visionEnabled,
    String? visionBaseUrl,
    String? visionApiKey,
    String? visionModel,
    int? visionIntervalSec,
    bool? visionAutoPause,
    bool? hubEnabled,
    int? hubPort,
    String? hubToken,
    String? helperUrl,
    String? helperToken,
  }) =>
      AppSettings(
        notifyOnFinish: notifyOnFinish ?? this.notifyOnFinish,
        notifyOnError: notifyOnError ?? this.notifyOnError,
        kioskMode: kioskMode ?? this.kioskMode,
        kioskRotateSec: kioskRotateSec ?? this.kioskRotateSec,
        builtinCamDefault: builtinCamDefault ?? this.builtinCamDefault,
        cameraMuted: cameraMuted ?? this.cameraMuted,
        ezvizAppKey: ezvizAppKey ?? this.ezvizAppKey,
        ezvizAppSecret: ezvizAppSecret ?? this.ezvizAppSecret,
        visionEnabled: visionEnabled ?? this.visionEnabled,
        visionBaseUrl: visionBaseUrl ?? this.visionBaseUrl,
        visionApiKey: visionApiKey ?? this.visionApiKey,
        visionModel: visionModel ?? this.visionModel,
        visionIntervalSec: visionIntervalSec ?? this.visionIntervalSec,
        visionAutoPause: visionAutoPause ?? this.visionAutoPause,
        hubEnabled: hubEnabled ?? this.hubEnabled,
        hubPort: hubPort ?? this.hubPort,
        hubToken: hubToken ?? this.hubToken,
        helperUrl: helperUrl ?? this.helperUrl,
        helperToken: helperToken ?? this.helperToken,
      );

  Map<String, dynamic> toJson() => {
        'notifyOnFinish': notifyOnFinish,
        'notifyOnError': notifyOnError,
        'kioskMode': kioskMode.name,
        'kioskRotateSec': kioskRotateSec,
        'builtinCamDefault': builtinCamDefault,
        'cameraMuted': cameraMuted,
        'ezvizAppKey': ezvizAppKey,
        'ezvizAppSecret': ezvizAppSecret,
        'visionEnabled': visionEnabled,
        'visionBaseUrl': visionBaseUrl,
        'visionApiKey': visionApiKey,
        'visionModel': visionModel,
        'visionIntervalSec': visionIntervalSec,
        'visionAutoPause': visionAutoPause,
        'hubEnabled': hubEnabled,
        'hubPort': hubPort,
        'hubToken': hubToken,
        'helperUrl': helperUrl,
        'helperToken': helperToken,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        notifyOnFinish: j['notifyOnFinish'] as bool? ?? true,
        notifyOnError: j['notifyOnError'] as bool? ?? true,
        kioskMode: KioskMode.values.firstWhere((m) => m.name == j['kioskMode'],
            orElse: () => KioskMode.off),
        kioskRotateSec: j['kioskRotateSec'] as int? ?? 15,
        builtinCamDefault: j['builtinCamDefault'] as bool? ?? true,
        cameraMuted: j['cameraMuted'] as bool? ?? false,
        ezvizAppKey: j['ezvizAppKey'] as String? ?? '',
        ezvizAppSecret: j['ezvizAppSecret'] as String? ?? '',
        visionEnabled: j['visionEnabled'] as bool? ?? false,
        visionBaseUrl: j['visionBaseUrl'] as String? ??
            'https://open.bigmodel.cn/api/paas/v4',
        visionApiKey: j['visionApiKey'] as String? ?? '',
        visionModel: j['visionModel'] as String? ?? 'glm-4v-flash',
        visionIntervalSec: j['visionIntervalSec'] as int? ?? 60,
        visionAutoPause: j['visionAutoPause'] as bool? ?? false,
        hubEnabled: j['hubEnabled'] as bool? ?? false,
        hubPort: j['hubPort'] as int? ?? 8787,
        hubToken: j['hubToken'] as String? ?? '',
        helperUrl: j['helperUrl'] as String? ?? '',
        helperToken: j['helperToken'] as String? ?? '',
      );
}

/// Persistence boundary; overridable in tests (same fake as PrinterStore).
abstract class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings s);
}

class SecureSettingsStore implements SettingsStore {
  SecureSettingsStore({required this.storage});

  static const _key = 'bambudeck.settings';

  final SecureStorageAdapter storage;

  @override
  Future<AppSettings> load() async {
    final raw = await storage.read(_key);
    if (raw == null || raw.isEmpty) return const AppSettings();
    try {
      return AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings s) =>
      storage.write(_key, jsonEncode(s.toJson()));
}

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
