/// Remaps a directional-pad (pan, tilt) onto the camera's own axes.
///
/// Only the picture's horizontal mirror takes part. A flip is a purely digital
/// mirror of the frame, so the left/right keys have to mirror with it; the
/// up/down keys are untouched.
///
/// The picture's rotation deliberately does NOT take part. Rotation exists to
/// compensate how the camera is mounted (竖装 / 倒装), and the pan/tilt motors
/// turn the camera itself in room space - the room does not rotate with the
/// picture. Feeding the rotation back through the command side compensates it
/// twice: at 90°/270° the up/down keys drive pan (so they move the picture
/// sideways), at 180° the left/right keys drive tilt (竖装/倒装 实测 2026-10-24).
///
/// Both arguments use the pad convention (pan > 0 right, tilt > 0 up) and the
/// result keeps it.
(double, double) orientPanTilt({
  required bool flipH,
  required double pan,
  required double tilt,
}) =>
    (flipH ? -pan : pan, tilt);

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
