import 'package:deck/core/gh_mirror.dart';
import 'package:flutter_test/flutter_test.dart';

/// GitHub Release 资产镜像兜底 (2026-10-29)。
///
/// 盒子实测: api.github.com 通, 但 302 后的 release-assets.githubusercontent.com
/// TLS 握手被拦 -> 直连必失败。这里锁住「直连永远第一、github.com 才加镜像、
/// 别的地址不乱改」三条, 防止兜底把信任面扩大。
void main() {
  const gh =
      'https://github.com/xygulu/BambuDeck/releases/download/v3.9.2/'
      'deck-hub-windows.zip';

  test('直连永远排在第一位', () {
    expect(GhMirror.candidates(gh).first, gh);
  });

  test('github.com 地址给每个镜像一个候选, 前缀式拼接', () {
    final c = GhMirror.candidates(gh);
    expect(c.length, 1 + GhMirror.prefixes.length);
    for (var i = 0; i < GhMirror.prefixes.length; i++) {
      expect(c[i + 1], GhMirror.prefixes[i] + gh);
      expect(c[i + 1].endsWith(gh), isTrue);
    }
  });

  test('非 github.com 地址不加镜像 (别把别的站也代进去)', () {
    const other = 'https://example.com/deck-hub-windows.zip';
    expect(GhMirror.candidates(other), <String>[other]);
    expect(GhMirror.candidates('https://api.github.com/repos/x/y'),
        <String>['https://api.github.com/repos/x/y']);
  });
}
