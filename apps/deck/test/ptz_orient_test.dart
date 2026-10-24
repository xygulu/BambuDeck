import 'package:deck/data/ptz_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pad convention: pan>0 = right, tilt>0 = up.
///
/// Two layers are covered here:
///  * [orientPanTilt] - the default guess, which undoes the picture's mirror
///    and rotation so the pad tracks the displayed picture;
///  * [applyPtzCalibration] - the measured key map, which wins outright when
///    the hardware does not behave like the guess (云台方向 2026-10-24).
void main() {
  // direction -> (pan, tilt)
  const up = (0.0, 1.0);
  const down = (0.0, -1.0);
  const left = (-1.0, 0.0);
  const right = (1.0, 0.0);

  (double, double) map(bool flipH, int deg, (double, double) d) =>
      orientPanTilt(flipH: flipH, rotationDeg: deg, pan: d.$1, tilt: d.$2);

  void expectVec((double, double) actual, (double, double) expected,
      {String? reason}) {
    expect(actual.$1, closeTo(expected.$1, 1e-9), reason: reason);
    expect(actual.$2, closeTo(expected.$2, 1e-9), reason: reason);
  }

  group('default mapping', () {
    test('identity when no flip/rotation', () {
      expectVec(map(false, 0, up), up);
      expectVec(map(false, 0, down), down);
      expectVec(map(false, 0, left), left);
      expectVec(map(false, 0, right), right);
    });

    test('horizontal mirror swaps left/right only', () {
      expectVec(map(true, 0, up), up);
      expectVec(map(true, 0, down), down);
      expectVec(map(true, 0, left), right);
      expectVec(map(true, 0, right), left);
    });

    test('90° clockwise turns the compass one step', () {
      expectVec(map(false, 90, up), left);
      expectVec(map(false, 90, left), down);
      expectVec(map(false, 90, down), right);
      expectVec(map(false, 90, right), up);
    });

    test('180° inverts both axes', () {
      expectVec(map(false, 180, up), down);
      expectVec(map(false, 180, down), up);
      expectVec(map(false, 180, left), right);
      expectVec(map(false, 180, right), left);
    });

    test('270° clockwise (90° counter-clockwise)', () {
      expectVec(map(false, 270, up), right);
      expectVec(map(false, 270, right), down);
      expectVec(map(false, 270, down), left);
      expectVec(map(false, 270, left), up);
    });

    test('flip + 90°: mirror left/right first, then rotate', () {
      expectVec(map(true, 90, up), left);
      expectVec(map(true, 90, left), up);
      expectVec(map(true, 90, down), right);
      expectVec(map(true, 90, right), down);
    });
  });

  group('measured calibration', () {
    test('rejects malformed maps', () {
      expect(isValidPtzCalibration(''), isFalse);
      expect(isValidPtzCalibration('UDL'), isFalse);
      expect(isValidPtzCalibration('UDLU'), isFalse);
      expect(isValidPtzCalibration('UDLX'), isFalse);
      expect(isValidPtzCalibration('UDLR'), isTrue);
      expect(isValidPtzCalibration('RLDU'), isTrue);
    });

    test('identity map sends each key to its own axis', () {
      const cal = 'UDLR';
      expectVec(applyPtzCalibration(cal, up.$1, up.$2), up);
      expectVec(applyPtzCalibration(cal, down.$1, down.$2), down);
      expectVec(applyPtzCalibration(cal, left.$1, left.$2), left);
      expectVec(applyPtzCalibration(cal, right.$1, right.$2), right);
    });

    test('a swapped map sends the key whose observation matches', () {
      // Measured: up/down move the picture sideways, left/right move it
      // vertically (the reported 90°/270° symptom).
      const cal = 'RLUD';
      // Asking for "picture up" must send the key that was seen to move it up.
      expectVec(applyPtzCalibration(cal, up.$1, up.$2), left, reason: 'U -> L');
      expectVec(applyPtzCalibration(cal, down.$1, down.$2), right,
          reason: 'D -> R');
      expectVec(applyPtzCalibration(cal, left.$1, left.$2), down,
          reason: 'picture-left came from the down key');
      expectVec(applyPtzCalibration(cal, right.$1, right.$2), up,
          reason: 'picture-right came from the up key');
    });

    test('180° calibration inverts every key', () {
      const cal = 'DULR';
      expectVec(applyPtzCalibration(cal, up.$1, up.$2), down);
      expectVec(applyPtzCalibration(cal, down.$1, down.$2), up);
    });

    test('speed magnitude survives the remap', () {
      final (p, t) = applyPtzCalibration('RLUD', 0, -0.35);
      expectVec((p, t), (0.35, 0.0));
    });

    test('invalid map falls back to the input', () {
      expectVec(applyPtzCalibration('nope', up.$1, up.$2), up);
    });

    test('a calibration beats orientation and invert flags', () {
      // Rotation 90 alone would send up -> pan-left; the measured map wins.
      const cal = 'DULR';
      final (p, t) = resolvedPtzMove(
        calibration: cal,
        flipH: true,
        rotationDeg: 90,
        invertPan: true,
        invertTilt: true,
        pan: up.$1,
        tilt: up.$2,
      );
      expectVec((p, t), down);
    });

    test('without a calibration the default corrections still apply', () {
      final (p, t) = resolvedPtzMove(
        calibration: '',
        flipH: false,
        rotationDeg: 90,
        invertPan: false,
        invertTilt: false,
        pan: up.$1,
        tilt: up.$2,
      );
      expectVec((p, t), left);
    });
  });
}
