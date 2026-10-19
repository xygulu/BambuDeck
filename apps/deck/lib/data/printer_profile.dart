import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';

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

  String get modeLabel => mode == PrinterMode.lan ? '局域网' : '云端';

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
      );
}

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
