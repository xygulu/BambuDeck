import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bambu_mjpeg.dart';
import 'printer_profile.dart';

/// Where a camera stream comes from (PRD FR-3).
enum CameraSourceType {
  /// Generic RTSP / ONVIF camera, full URL given by the user.
  rtsp,

  /// The printer's own camera, derived from the linked printer's LAN
  /// credentials. Transport depends on the model: A1/A1 mini/P1/P1P speak
  /// MJPEG over TLS :6000 (bmjpeg:// scheme), X1/P1S/P2S/H2 speak
  /// RTSPS :322.
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

  /// Playback URL, resolving the bambu type against the printer profile
  /// and its model's camera transport. Returns null when a bambu camera
  /// has no (usable) linked printer. Legacy M2 entries stored built-in
  /// cameras as `rtsp://bblp:code@ip/stream_live`; when such an rtsp URL
  /// points at the linked LAN printer it is re-derived from the model so
  /// it rides the right transport instead of hitting mpv blind.
  String? resolveUrl(PrinterProfile? linked) {
    if (sourceType == CameraSourceType.bambu) {
      if (linked == null ||
          linked.mode != PrinterMode.lan ||
          linked.ip.isEmpty) {
        return null;
      }
      return _builtInUrl(linked);
    }
    if (url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (linked != null &&
        linked.mode == PrinterMode.lan &&
        linked.ip.isNotEmpty &&
        u != null &&
        u.userInfo.startsWith('bblp') &&
        u.host == linked.ip) {
      return _builtInUrl(linked);
    }
    return url;
  }

  String _builtInUrl(PrinterProfile linked) =>
      cameraSchemeForModel(linked.model) == BambuCameraScheme.rtsps
          ? 'rtsps://bblp:${linked.accessCode}@${linked.ip}:322/streaming/live/1'
          : 'bmjpeg://bblp:${linked.accessCode}@${linked.ip}';

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
