import 'package:deck/data/ptz_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pad convention: pan>0 = right, tilt>0 = up. `orientPanTilt` must undo
/// the picture transform so a held key moves the view the way the flipped /
/// rotated image shows it.
void main() {
  // direction -> (pan, tilt)
  const up = (0.0, 1.0);
  const down = (0.0, -1.0);
  const left = (-1.0, 0.0);
  const right = (1.0, 0.0);

  (double, double) map(bool flipH, int deg, (double, double) d) =>
      orientPanTilt(flipH: flipH, rotationDeg: deg, pan: d.$1, tilt: d.$2);

  void expectVec((double, double) actual, (double, double) expected) {
    expect(actual.$1, closeTo(expected.$1, 1e-9));
    expect(actual.$2, closeTo(expected.$2, 1e-9));
  }

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
    // Mirrored picture: up stays up-then-rotated, but left/right swap relative
    // to the unflipped 90° case.
    expectVec(map(true, 90, up), left);
    expectVec(map(true, 90, left), up);
    expectVec(map(true, 90, down), right);
    expectVec(map(true, 90, right), down);
  });
}
