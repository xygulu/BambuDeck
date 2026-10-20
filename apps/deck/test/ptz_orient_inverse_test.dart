import 'dart:math' as math;

import 'package:deck/data/ptz_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replicates CameraTile._orient: FlipX then RotZ, in exactly the call order
/// the widget uses (`m.scale(...)` then `m.rotateZ(...)`).
Matrix4 orientMatrix(bool flipH, int rotationDeg) {
  final m = Matrix4.identity();
  if (flipH) m.scale(-1.0, 1.0, 1.0);
  if (rotationDeg != 0) m.rotateZ(rotationDeg * math.pi / 180.0);
  return m;
}

/// Camera direction (pan>0 right, tilt>0 up) in the screen's y-down coords:
/// the same vector the video frame carries before the transform is applied.
Offset camVec(double pan, double tilt) => Offset(pan, -tilt);

/// `orientPanTilt` must be the exact inverse of the picture transform: feeding
/// its output back through `_orient`'s matrix has to land on the original pad
/// direction. This ties the remap to the real matrix instead of a hand-derived
/// guess, so a wrong flip/rotate order or a flipped rotation sign fails loudly.
void main() {
  for (final flipH in const [false, true]) {
    for (final deg in const [0, 90, 180, 270]) {
      test('inverse of picture transform (flip=$flipH deg=$deg)', () {
        final m = orientMatrix(flipH, deg);
        for (final d in const [
          (1.0, 0.0),
          (-1.0, 0.0),
          (0.0, 1.0),
          (0.0, -1.0),
          (0.6, 0.8),
        ]) {
          final (p, t) = orientPanTilt(
              flipH: flipH, rotationDeg: deg, pan: d.$1, tilt: d.$2);
          final screen = MatrixUtils.transformPoint(m, camVec(p, t));
          final want = camVec(d.$1, d.$2);
          expect(screen.dx, closeTo(want.dx, 1e-9));
          expect(screen.dy, closeTo(want.dy, 1e-9));
        }
      });
    }
  }
}
