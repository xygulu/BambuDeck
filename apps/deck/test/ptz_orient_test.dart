import 'package:deck/data/ptz_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pad convention: pan>0 = right, tilt>0 = up.
///
/// Only the picture's horizontal mirror takes part in the mapping. The
/// picture's rotation is intentionally not a parameter: rotation corrects how
/// the camera is mounted, while the motors turn the camera in room space, so
/// remapping through it would compensate the mounting twice (竖装/倒装 实测
/// 2026-10-24: 90°/270° sent pan from the up/down keys, 180° sent tilt from the
/// left/right keys).
void main() {
  // direction -> (pan, tilt)
  const up = (0.0, 1.0);
  const down = (0.0, -1.0);
  const left = (-1.0, 0.0);
  const right = (1.0, 0.0);

  (double, double) map(bool flipH, (double, double) d) =>
      orientPanTilt(flipH: flipH, pan: d.$1, tilt: d.$2);

  void expectVec((double, double) actual, (double, double) expected) {
    expect(actual.$1, closeTo(expected.$1, 1e-9));
    expect(actual.$2, closeTo(expected.$2, 1e-9));
  }

  test('identity without a mirror', () {
    expectVec(map(false, up), up);
    expectVec(map(false, down), down);
    expectVec(map(false, left), left);
    expectVec(map(false, right), right);
  });

  test('horizontal mirror swaps left/right only', () {
    expectVec(map(true, up), up);
    expectVec(map(true, down), down);
    expectVec(map(true, left), right);
    expectVec(map(true, right), left);
  });

  test('up/down never leave the tilt axis', () {
    for (final flip in [false, true]) {
      expect(map(flip, up).$1, 0, reason: 'flip=$flip');
      expect(map(flip, up).$2, 1, reason: 'flip=$flip');
      expect(map(flip, down).$1, 0, reason: 'flip=$flip');
      expect(map(flip, down).$2, -1, reason: 'flip=$flip');
    }
  });

  test('left/right never leave the pan axis', () {
    for (final flip in [false, true]) {
      expect(map(flip, left).$2, 0, reason: 'flip=$flip');
      expect(map(flip, right).$2, 0, reason: 'flip=$flip');
    }
  });
}
