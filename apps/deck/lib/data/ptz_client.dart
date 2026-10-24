/// One pad press → the pan/tilt sent to the camera.
///
/// The pad's keys keep their meaning from the picture's *initial* view
/// (rotation 0, no flip) - pressing 上 sends tilt-up, and so on. The picture's
/// flip/rotation is never applied here: the pad itself is drawn through the
/// very same transform as the video (see `CameraTile._orient`), so the arrow
/// the user sees always points the way the picture moves, for any mount and
/// any angle (用户口径 2026-10-24: 初始画面的按键动作跟着画面旋转或翻转).
///
/// Only the per-camera axis flips remain: some HIK/EZVIZ mounts run pan or
/// tilt opposite to the command names even in the initial view.
(double, double) ptzMove({
  required bool invertPan,
  required bool invertTilt,
  required double pan,
  required double tilt,
}) =>
    (invertPan ? -pan : pan, invertTilt ? -tilt : tilt);

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
