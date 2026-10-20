import 'dart:math' as math;

/// Remaps a directional-pad (pan, tilt) onto the camera's physical axis,
/// undoing the tile's horizontal mirror and clockwise rotation so a held key
/// moves the view the way the picture shows it (上键=画面向上 2026-10-20).
///
/// The picture is drawn through `T = FlipX(flipH) · RotZ(rotationDeg)`; the
/// pad's directions are screen-space, so they must be pushed through `T⁻¹`
/// to reach the camera's own pan/tilt. Both arguments use the pad convention
/// (pan > 0 right, tilt > 0 up) and the result keeps it.
(double, double) orientPanTilt({
  required bool flipH,
  required int rotationDeg,
  required double pan,
  required double tilt,
}) {
  if (!flipH && rotationDeg == 0) return (pan, tilt);
  // Screen-space direction vector (x right, y down).
  var x = pan;
  final y = -tilt;
  // T⁻¹ = RotZ(-rotationDeg) · FlipX.
  if (flipH) x = -x;
  final th = rotationDeg * math.pi / 180.0;
  final c = math.cos(th);
  final s = math.sin(th);
  final nx = c * x + s * y;
  final ny = -s * x + c * y;
  return (nx, -ny);
}

/// Common press-and-hold PTZ surface for a monitoring tile's directional pad.
/// Two transports implement it: [OnvifPtz] (generic ONVIF cameras) and
/// [HcNetSdkPtz] (Hikvision/EZVIZ cameras over the HCNetSDK command port).
abstract class PtzClient {
  bool get available;
  Future<bool> probe();
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0});
  Future<void> stop();
  void dispose();
}

/// Probes [clients] in order and delegates to the first one that reports
/// available. An EZVIZ camera with ONVIF disabled falls back to its
/// command-port client; a generic ONVIF camera never reaches the HCNetSDK
/// client because ONVIF answers first.
class FallbackPtz implements PtzClient {
  FallbackPtz(this._clients);

  final List<PtzClient> _clients;
  PtzClient? _active;

  @override
  bool get available => _active != null;

  @override
  Future<bool> probe() async {
    for (final client in _clients) {
      try {
        if (await client.probe()) {
          _active = client;
          return true;
        }
      } catch (_) {
        // try the next transport
      }
    }
    return false;
  }

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    await _active?.move(pan: pan, tilt: tilt, zoom: zoom);
  }

  @override
  Future<void> stop() async {
    await _active?.stop();
  }

  @override
  void dispose() {
    for (final client in _clients) {
      client.dispose();
    }
  }
}
