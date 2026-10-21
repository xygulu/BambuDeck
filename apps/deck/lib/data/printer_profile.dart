import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';

/// Whether a printer's built-in camera loads by default. `follow` defers
/// to the global setting in AppSettings (PRD 机内摄像头默认开关).
enum BuiltinCamSetting { follow, on, off }

/// One configured printer. Credentials ride inside the profile; the store
/// keeps the whole list in the platform secure store (Keychain /
/// Credential Manager / Keystore), never plaintext (PRD FR-8).
class PrinterProfile {
  PrinterProfile({
    required this.id,
    required this.name,
    required this.mode,
    required this.serial,
    this.ip = '',
    this.accessCode = '',
    this.region = CloudRegion.us,
    this.token = '',
    this.userId = '',
    this.model = '',
    this.builtinCam = BuiltinCamSetting.follow,
    this.autoPlateSwap = false,
  });

  final String id;
  final String name;
  final PrinterMode mode;

  final String serial;

  // LAN mode
  final String ip;
  final String accessCode;

  // Cloud mode
  final CloudRegion region;
  final String token;
  final String userId; // "u_{uid}"

  /// Model name (A1 / A1 mini / P1P / P1S / X1C / X1E / P2S / H2D / H2S …).
  /// Decides which camera transport the printer speaks - see
  /// [cameraSchemeForModel] in camera_profile.dart.
  final String model;

  /// Built-in camera default-load policy for this printer.
  final BuiltinCamSetting builtinCam;

  /// Whether the printer is set up for automatic plate swapping (是否具备
  /// 自动换盘): shows the 一键换盘 button that prints the bundled swap model
  /// (its tail gcode shakes the print off and ejects the plate).
  final bool autoPlateSwap;

  String get modeLabel => mode == PrinterMode.lan ? '局域网' : '云端';

  /// Value-comparable key of the fields that actually decide the MQTT
  /// connection. [ConnectionNotifier] reconnects only when this changes, so
  /// cosmetic edits (name / builtinCam / model) don't tear down the live
  /// link and blank the monitoring page.
  (String, String, String, String, CloudRegion, String, String)
      get connectionKey =>
          (mode.name, serial, ip, accessCode, region, token, userId);

  /// Effective default-load decision given the global switch.
  bool builtinCamDefaultOn(bool globalDefault) => switch (builtinCam) {
        BuiltinCamSetting.on => true,
        BuiltinCamSetting.off => false,
        BuiltinCamSetting.follow => globalDefault,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'mode': mode.name,
        'serial': serial,
        'ip': ip,
        'accessCode': accessCode,
        'region': region.name,
        'token': token,
        'userId': userId,
        'model': model,
        'builtinCam': builtinCam.name,
        'autoPlateSwap': autoPlateSwap,
      };

  factory PrinterProfile.fromJson(Map<String, dynamic> j) => PrinterProfile(
        id: j['id'] as String,
        name: j['name'] as String,
        mode: PrinterMode.values.byName(j['mode'] as String),
        serial: j['serial'] as String? ?? '',
        ip: j['ip'] as String? ?? '',
        accessCode: j['accessCode'] as String? ?? '',
        region: CloudRegion.values
            .byName(j['region'] as String? ?? CloudRegion.us.name),
        token: j['token'] as String? ?? '',
        userId: j['userId'] as String? ?? '',
        model: j['model'] as String? ?? '',
        builtinCam: j['builtinCam'] is String
            ? BuiltinCamSetting.values.firstWhere(
                (v) => v.name == j['builtinCam'],
                orElse: () => BuiltinCamSetting.follow)
            : BuiltinCamSetting.follow,
        autoPlateSwap: j['autoPlateSwap'] as bool? ?? false,
      );

  BambuMqttConfig toMqttConfig() => mode == PrinterMode.lan
      ? BambuMqttConfig.lan(ip: ip, serial: serial, accessCode: accessCode)
      : BambuMqttConfig.cloud(
          region: region, serial: serial, userId: userId, token: token);

  PrinterProfile copyWith({
    String? name,
    String? ip,
    String? accessCode,
    CloudRegion? region,
    String? token,
    String? userId,
    String? model,
    BuiltinCamSetting? builtinCam,
    bool? autoPlateSwap,
  }) =>
      PrinterProfile(
        id: id,
        name: name ?? this.name,
        mode: mode,
        serial: serial,
        ip: ip ?? this.ip,
        accessCode: accessCode ?? this.accessCode,
        region: region ?? this.region,
        token: token ?? this.token,
        userId: userId ?? this.userId,
        model: model ?? this.model,
        builtinCam: builtinCam ?? this.builtinCam,
        autoPlateSwap: autoPlateSwap ?? this.autoPlateSwap,
      );
}

/// 控制路由判定（暂停/恢复/停止）：
///   LAN 连接 + 开发者模式确认为开(`print.fun` bit29=0) → 局域网 MQTT 直发(秒回)
///   其余(云模式 / dev-OFF / 固件未报 fun) → Bambu Connect 自动化(dev-OFF 的
///   LAN MQTT 控制会被固件 84033543 拦)。[state] 为 null(尚未连上)时同样不直发。
bool useLanControl(PrinterProfile profile, BambuState? state) =>
    profile.mode == PrinterMode.lan && state?.developerModeOff == false;

/// Persistence boundary for the printer list. Overridable in tests.
abstract class PrinterStore {
  Future<List<PrinterProfile>> load();
  Future<void> save(List<PrinterProfile> printers);
}

/// JSON list in the OS secure store.
class SecurePrinterStore implements PrinterStore {
  SecurePrinterStore({required this.storage});

  static const _key = 'bambudeck.printers';

  final SecureStorageAdapter storage;

  @override
  Future<List<PrinterProfile>> load() async {
    final raw = await storage.read(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(PrinterProfile.fromJson)
          .toList();
      return list;
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> save(List<PrinterProfile> printers) {
    final raw = jsonEncode(printers.map((p) => p.toJson()).toList());
    return storage.write(_key, raw);
  }
}

/// Narrow interface so the secure store can be faked in widget tests.
abstract class SecureStorageAdapter {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}
