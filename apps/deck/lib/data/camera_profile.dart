import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'bambu_mjpeg.dart';
import 'printer_profile.dart';
import 'rtsp_quality.dart';

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
///
/// Binding is many-to-many for RTSP cameras ([printerIds]); built-in
/// (bambu) cameras stay 1:1 - their URL is derived from the one printer
/// they physically belong to.
class CameraProfile {
  CameraProfile({
    required this.id,
    required this.name,
    required this.sourceType,
    this.url = '',
    this.printerIds = const [],
    this.enabled = true,
    this.quality = RtspQuality.main,
    this.flipH = false,
    this.rotationDeg = 0,
    this.ptzInvertPan = false,
    this.ptzInvertTilt = false,
  });

  final String id;
  final String name;
  final CameraSourceType sourceType;

  /// Stream URL for [CameraSourceType.rtsp], e.g. rtsp://user:pass@host:554/1
  final String url;

  /// Bound printers (FR-4 组合画面 / 监控屏右侧画面). Built-in cameras
  /// carry exactly one; RTSP cameras may carry several.
  final List<String> printerIds;

  final bool enabled;

  /// Main vs sub stream preference for RTSP sources.
  final RtspQuality quality;

  /// Horizontal mirror (left-right flip) for a camera mounted so its
  /// picture comes out mirrored (画面翻转 2026-10-20).
  final bool flipH;

  /// Clockwise rotation in degrees to right a sideways/upside-down mount:
  /// one of 0 / 90 / 180 / 270 (画面旋转 2026-10-20).
  final int rotationDeg;

  /// PTZ direction calibration (云台方向校准 2026-10-21): some cameras -
  /// ceiling mounts, certain EZVIZ firmware - physically invert one axis
  /// against the HIK/ONVIF command semantics, so two arrows track the
  /// picture and the other two move the wrong way. These flip the pad's
  /// pan / tilt in the picture's initial view; the picture's own
  /// flip/rotation is carried by the pad widget instead.
  final bool ptzInvertPan;
  final bool ptzInvertTilt;

  CameraProfile copyWith({
    String? name,
    String? url,
    List<String>? printerIds,
    bool? enabled,
    RtspQuality? quality,
    bool? flipH,
    int? rotationDeg,
    bool? ptzInvertPan,
    bool? ptzInvertTilt,
  }) =>
      CameraProfile(
        id: id,
        name: name ?? this.name,
        sourceType: sourceType,
        url: url ?? this.url,
        printerIds: printerIds ?? this.printerIds,
        enabled: enabled ?? this.enabled,
        quality: quality ?? this.quality,
        flipH: flipH ?? this.flipH,
        rotationDeg: rotationDeg ?? this.rotationDeg,
        ptzInvertPan: ptzInvertPan ?? this.ptzInvertPan,
        ptzInvertTilt: ptzInvertTilt ?? this.ptzInvertTilt,
      );

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
    return applyRtspQuality(url, quality);
  }

  String _builtInUrl(PrinterProfile linked) => cameraSchemeForModel(
              linked.model) ==
          BambuCameraScheme.rtsps
      ? 'rtsps://bblp:${linked.accessCode}@${linked.ip}:322/streaming/live/1'
      : 'bmjpeg://bblp:${linked.accessCode}@${linked.ip}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourceType': sourceType.name,
        'url': url,
        'printerIds': printerIds,
        // Legacy single-binding key kept so an older app build can still
        // read at least the first binding.
        'printerId': printerIds.isEmpty ? '' : printerIds.first,
        'enabled': enabled,
        'quality': quality.name,
        'flipH': flipH,
        'rotationDeg': rotationDeg,
        'ptzInvertPan': ptzInvertPan,
        'ptzInvertTilt': ptzInvertTilt,
      };

  factory CameraProfile.fromJson(Map<String, dynamic> j) {
    final ids = <String>[
      ...((j['printerIds'] as List<dynamic>? ?? const []).whereType<String>()),
      if (j['printerId'] is String && (j['printerId'] as String).isNotEmpty)
        j['printerId'] as String,
    ];
    return CameraProfile(
      id: j['id'] as String,
      name: j['name'] as String? ?? '',
      sourceType: CameraSourceType.values.firstWhere(
          (t) => t.name == j['sourceType'],
          orElse: () => CameraSourceType.rtsp),
      url: j['url'] as String? ?? '',
      printerIds: ids.toSet().toList(),
      enabled: j['enabled'] as bool? ?? true,
      quality: rtspQualityFromName(j['quality'] as String?),
      flipH: j['flipH'] as bool? ?? false,
      rotationDeg: j['rotationDeg'] as int? ?? 0,
      ptzInvertPan: j['ptzInvertPan'] as bool? ?? false,
      ptzInvertTilt: j['ptzInvertTilt'] as bool? ?? false,
    );
  }
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
