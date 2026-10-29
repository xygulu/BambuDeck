import 'dart:io';

import 'package:deck/core/version.dart';
import 'package:flutter_test/flutter_test.dart';

/// hub 版本号来源 (2026-10-29)。
///
/// `dart build cli` 不支持 `--dart-define`, AOT 出来的 hub 只能从包根的
/// `version.txt` 拿版本。读不到就算 dev —— dev 在比较里永远小于正式版,
/// 所以「读不到」不能当成「已是最新」, 否则自更新会一直弹。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('deckver'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('version.txt 带 v 前缀与换行也认', () {
    File('${tmp.path}/version.txt').writeAsStringSync('v3.9.4\r\n');
    expect(readVersionFile(tmp.path), '3.9.4');
  });

  test('没有文件返回空串 (调用方回落 dev)', () {
    expect(readVersionFile(tmp.path), '');
  });

  test('空文件返回空串', () {
    File('${tmp.path}/version.txt').writeAsStringSync('  \n');
    expect(readVersionFile(tmp.path), '');
  });

  test('比较: 正式版 > dev, 同版本相等', () {
    expect(compareVersions('3.9.4', 'dev'), greaterThan(0));
    expect(compareVersions('3.9.4', '3.9.4'), 0);
    expect(compareVersions('3.9.4', '3.9.10'), lessThan(0));
  });
}
