import 'dart:math' as math;

/// Default key mapping: undoes the picture's mirror and rotation so a held key
/// moves the view the way the displayed picture shows it.
///
/// The picture is drawn through `T = FlipX(flipH) · RotZ(rotationDeg)`, so the
/// pad's screen-space directions are pushed through `T⁻¹` to reach the camera's
/// pan/tilt. Both arguments use the pad convention (pan > 0 right, tilt > 0 up)
/// and the result keeps it.
///
/// This is only the default. It assumes the camera turns the way the command
/// names say; a mount that disagrees (ceiling 竖装 / 倒装 firmware) needs the
/// measured mapping from [applyPtzCalibration] instead, which supersedes it.
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

/// The pad's four keys, in the order a calibration string lists them.
const ptzKeys = 'UDLR';

/// Which single axis one pad press drives, or '' for a diagonal / zero move.
String ptzAxisOf(double pan, double tilt) => pan > 0
    ? 'R'
    : pan < 0
        ? 'L'
        : tilt > 0
            ? 'U'
            : tilt < 0
                ? 'D'
                : '';

/// True when [calibration] is a permutation of "UDLR" (a usable mapping).
bool isValidPtzCalibration(String calibration) =>
    calibration.length == 4 &&
    calibration.split('').toSet().length == 4 &&
    calibration.split('').every(ptzKeys.contains);

/// Applies a measured key map (云台方向实测校准 2026-10-24).
///
/// [calibration] holds four letters, one per key in [ptzKeys] order: the
/// direction the picture *actually* moved when that key was pressed. Pressing
/// a key must move the picture in the key's own direction, so the command sent
/// is the one whose observed direction equals the pressed key. Identity
/// ("UDLR") sends the key's own axis, i.e. no correction.
///
/// A measured map beats any reasoning about how the mount, the firmware and
/// the picture rotation interact: it records the result the user actually
/// sees, for every camera / mounting / rotation combination.
(double, double) applyPtzCalibration(
    String calibration, double pan, double tilt) {
  final key = ptzAxisOf(pan, tilt);
  if (key.isEmpty || !isValidPtzCalibration(calibration)) return (pan, tilt);
  final i = calibration.indexOf(key);
  if (i < 0) return (pan, tilt);
  final speed = pan.abs() > tilt.abs() ? pan.abs() : tilt.abs();
  return switch (ptzKeys[i]) {
    'U' => (0.0, speed),
    'D' => (0.0, -speed),
    'L' => (-speed, 0.0),
    _ => (speed, 0.0),
  };
}

/// One pad press → the pan/tilt actually sent to the camera.
///
/// A measured [calibration] wins outright: it already records what the user
/// sees for this camera, mount and picture rotation, so applying the default
/// corrections on top of it would corrupt the measurement. Without one, fall
/// back to the picture-orientation inverse plus the per-camera axis flips.
(double, double) resolvedPtzMove({
  required String calibration,
  required bool flipH,
  required int rotationDeg,
  required bool invertPan,
  required bool invertTilt,
  required double pan,
  required double tilt,
}) {
  if (isValidPtzCalibration(calibration)) {
    return applyPtzCalibration(calibration, pan, tilt);
  }
  var (p, t) = orientPanTilt(
      flipH: flipH, rotationDeg: rotationDeg, pan: pan, tilt: tilt);
  if (invertPan) p = -p;
  if (invertTilt) t = -t;
  return (p, t);
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
