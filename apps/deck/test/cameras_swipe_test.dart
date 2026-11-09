import 'package:deck/features/cameras/cameras_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('swipeCameraStep', () {
    test('上滑(负) = 下一台, 下滑(正) = 上一台', () {
      expect(swipeCameraStep(-120), 1);
      expect(swipeCameraStep(120), -1);
    });

    test('位移不够阈值不算换台 (轻点/抖动)', () {
      expect(swipeCameraStep(0), isNull);
      expect(swipeCameraStep(40), isNull);
      expect(swipeCameraStep(-40), isNull);
    });

    test('阈值可调', () {
      expect(swipeCameraStep(-60, threshold: 80), isNull);
      expect(swipeCameraStep(-90, threshold: 80), 1);
    });
  });
}
