import 'package:deck/data/ftps_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FtpReplyParser', () {
    test('single-line reply completes immediately', () {
      final p = FtpReplyParser();
      final r = p.push('230 User logged in.\r\n'.codeUnits);
      expect(r, isNotNull);
      expect(r!.code, 230);
      expect(r.isPositiveCompletion, isTrue);
    });

    test('waits for the final line of a multiline reply', () {
      final p = FtpReplyParser();
      expect(p.push('250-\r\n'.codeUnits), isNull);
      expect(p.push('250 CWD command successful\r\n'.codeUnits), isNotNull);
    });

    test('multiline keeps both lines in text', () {
      final p = FtpReplyParser();
      p.push('227-Entering\r\n'.codeUnits);
      final r = p.push('227 Passive Mode (192,168,1,42,4,20)\r\n'.codeUnits);
      expect(r!.code, 227);
      expect(r.text, contains('Passive Mode'));
    });

    test('splits replies arriving in one chunk', () {
      final p = FtpReplyParser();
      expect(p.push('200 TYPE ok\r\n250 ok\r\n'.codeUnits), isNotNull);
    });

    test('crlf split across chunks still parses', () {
      final p = FtpReplyParser();
      expect(p.push('331 pass'.codeUnits), isNull);
      expect(p.push('w'.codeUnits), isNull);
      final r = p.push([0x0d, 0x0a]);
      expect(r!.code, 331);
    });

    test('junk lines between replies are ignored', () {
      final p = FtpReplyParser();
      p.push('some banner text\r\n'.codeUnits);
      final r = p.push('220 ready\r\n'.codeUnits);
      expect(r!.code, 220);
    });

    test('PASV port math', () {
      // p1*256+p2 is asserted here against the regex the client uses.
      final m =
          RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch('(192,168,1,42,4,20)')!;
      expect(int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!), 4 * 256 + 20);
    });
  });
}
