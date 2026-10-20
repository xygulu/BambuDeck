import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Ground truth for the PTZ orientation inverse: which way does
// Matrix4.rotateZ(+) actually turn a child on screen? The pad's
// orientPanTilt assumes +angle = clockwise in Flutter's y-down space;
// if that assumption were flipped, 90/270° mappings would invert
// (180° is insensitive - which matches "rotation breaks only some
// directions" reports). Render a rotated box and paint-locate its
// right-edge midpoint via localToGlobal (paint transforms included).
void main() {
  testWidgets('rotateZ(+90°) is visually clockwise', (tester) async {
    await tester.pumpWidget(
      Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()..rotateZ(math.pi / 2),
          child: const SizedBox(width: 100, height: 40),
        ),
      ),
    );
    final box = tester.renderObject<RenderBox>(find.byType(SizedBox));
    // Local right-edge midpoint of the 100x40 child; untransformed it sits
    // at viewport center + (50, 0).
    final rightMid = box.localToGlobal(const Offset(100, 20));
    final center = box.localToGlobal(const Offset(50, 20));
    // Clockwise ⇒ right edge swings to below the center line (y-down).
    expect(rightMid.dy, greaterThan(center.dy),
        reason: 'rotateZ(+90°) rendered counterclockwise - the PTZ inverse '
            'in ptz_client.dart assumes clockwise and must flip its sign');
  });
}
