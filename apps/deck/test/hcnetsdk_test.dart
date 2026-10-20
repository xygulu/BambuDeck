import 'dart:typed_data';

import 'package:deck/data/hcnetsdk.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _hex(String h) => [
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16),
    ];

void main() {
  group('hcNetSdkFourRoundAes', () {
    test('matches the pyEzvizApi reference (vector 1)', () {
      final out = hcNetSdkFourRoundAes(
        Uint8List.fromList(List.generate(16, (i) => i)),
        Uint8List.fromList(_hex(
            '2b7e151628aed2a6abf7158809cf4f3c')),
      );
      expect(
          out,
          Uint8List.fromList(
              _hex('1cb52fd44a4fdc8e6aae43f06ca2ba71')));
    });

    test('matches the pyEzvizApi reference (vector 2)', () {
      final out = hcNetSdkFourRoundAes(
        Uint8List.fromList(
            _hex('00112233445566778899aabbccddeeff')),
        Uint8List(16),
      );
      expect(
          out,
          Uint8List.fromList(
              _hex('21b7a8d580af552817dd818972e38856')));
    });
  });

  test('hcNetSdkAuthWord matches the pyEzvizApi reference', () {
    final word = hcNetSdkAuthWord(
      sessionId: Uint8List.fromList([0x32, 0x38, 0x43, 0x39]),
      authSeed: 0x227f987a,
      commandId: 0x11000,
      challenge: Uint8List(32),
    );
    expect(word, 0xcd6bb619);
  });
}
