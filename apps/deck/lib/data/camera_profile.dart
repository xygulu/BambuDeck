import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'printer_profile.dart';

/// Where a camera stream comes from (PRD FR-3).
enum CameraSourceType {
  /// Generic RTSP / ONVIF camera, full URL given by the user.
  rtsp,

  /// The printer's own camera (X1/P1 family), derived from the linked
  /// printer's LAN credentials. A1 / A1 mini have no camera hardware.
  bambu;

  String get label => switch (this) {
        rtsp => 'RTSP / ONVIF',
        bambu => '打印机自带',
      };
}

/// One configured video source. Credentials ride inside the profile like
/// printer profiles do; the store keeps them in the OS secure store.
class CameraProfile {
  CameraProfile({
    required this.id,
    required this.name,
    required this.sourceType,
    this.url = '',
    this.printerId = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final CameraSourceType sourceType;

  /// Stream URL for [CameraSourceType.rtsp], e.g. rtsp://user:pass@host:554/1
  final String url;

  /// Linked printer for [CameraSourceType.bambu] and for the dashboard
  /// embed (FR-4 组合画面): the camera shows on that printer's dashboard.
  final String printerId;

  final bool enabled;

  /// Playback URL, resolving the bambu type against the printer profile.
  /// Returns null when a bambu camera has no (usable) linked printer.
  String? resolveUrl(PrinterProfile? linked) => switch (sourceType) {
        CameraSourceType.rtsp => url.isEmpty ? null : url,
        CameraSourceType.bambu =>
          linked == null || linked.mode != PrinterMode.lan
              ? null
              : 'rtsp://bblp:${linked.accessCode}@${linked.ip}/stream_live',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceType': sourceType.name,
        'url': url,
        'printerId': printerId,
        'enabled': enabled,
      };

  factory CameraProfile.fromJson(Map<String, dynamic> j) => CameraProfile(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        sourceType: CameraSourceType.values.firstWhere(
            (t) => t.name == j['sourceType'],
            orElse: () => CameraSourceType.rtsp),
        url: j['url'] as String? ?? '',
        printerId: j['printerId'] as String? ?? '',
        enabled: j['enabled'] as bool? ?? true,
      );
}

/// Persistence boundary; overridable in tests.
abstract class CameraStore {
  Future<List<CameraProfile>> load();
  Future<void> save(List<CameraProfile> cameras);
}

/// JSON list in the OS secure store.
class SecureCameraStore implements CameraStore {
  SecureCameraStore({required this.storage});

  static const _key = 'bambudeck.cameras';

  final SecureStorageAdapter storage;

  @override
  Future<List<CameraProfile>> load() async {
    final raw = await storage.read(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(CameraProfile.fromJson)
          .toList();
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> save(List<CameraProfile> cameras) {
    final raw = jsonEncode(cameras.map((c) => c.toJson()).toList());
    return storage.write(_key, raw);
  }
}

class CamerasNotifier extends AsyncNotifier<List<CameraProfile>> {
  @override
  Future<List<CameraProfile>> build() async =>
      ref.watch(cameraStoreProvider).load();

  Future<void> add(CameraProfile camera) async {
    final store = ref.read(cameraStoreProvider);
    state = AsyncData([...state.valueOrNull ?? [], camera]);
    await store.save(state.valueOrNull ?? []);
  }

  Future<void> remove(String id) async {
    final store = ref.read(cameraStoreProvider);
    state = AsyncData(
        (state.valueOrNull ?? []).where((c) => c.id != id).toList());
    await store.save(state.valueOrNull ?? []);
  }
}

final cameraStoreProvider = Provider<CameraStore>(
    (ref) => throw UnimplementedError('override cameraStoreProvider'));

final camerasProvider =
    AsyncNotifierProvider<CamerasNotifier, List<CameraProfile>>(
        CamerasNotifier.new);
