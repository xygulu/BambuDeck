import 'package:deck/data/ptz_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pad convention: pan>0 = right, tilt>0 = up.
///
/// The four keys keep their meaning from the picture's initial view, which is
/// the only view whose key semantics are known; the picture's flip/rotation is
/// carried by drawing the pad through the same transform as the video, so it
/// never reaches the command (用户口径 2026-10-24). All that is left here are
/// the per-camera axis flips.
void main() {
  const up = (0.0, 0.8);
  const down = (0.0, -0.8);
  const left = (-0.8, 0.0);
  const right = (0.8, 0.0);

  (double, double) move((double, double) d,
          {bool invertPan = false, bool invertTilt = false}) =>
      ptzMove(
          invertPan: invertPan,
          invertTilt: invertTilt,
          pan: d.$1,
          tilt: d.$2);

  void expectVec((double, double) actual, (double, double) expected) {
    expect(actual.$1, closeTo(expected.$1, 1e-9));
    expect(actual.$2, closeTo(expected.$2, 1e-9));
  }

  test('base view sends each key its own way', () {
    expectVec(move(up), up);
    expectVec(move(down), down);
    expectVec(move(left), left);
    expectVec(move(right), right);
  });

  test('invertPan mirrors left/right and leaves up/down alone', () {
    expectVec(move(left, invertPan: true), right);
    expectVec(move(right, invertPan: true), left);
    expectVec(move(up, invertPan: true), up);
    expectVec(move(down, invertPan: true), down);
  });

  test('invertTilt mirrors up/down and leaves left/right alone', () {
    expectVec(move(up, invertTilt: true), down);
    expectVec(move(down, invertTilt: true), up);
    expectVec(move(left, invertTilt: true), left);
    expectVec(move(right, invertTilt: true), right);
  });

  test('both flips invert every key (ceiling mount)', () {
    expectVec(move(up, invertPan: true, invertTilt: true), down);
    expectVec(move(left, invertPan: true, invertTilt: true), right);
  });
}
