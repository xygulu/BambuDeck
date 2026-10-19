import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:bambu_protocol/src/error_text_tables.dart';
import 'package:test/test.dart';

void main() {
  group('error text tables', () {
    test('feed version stamp survived generation', () {
      expect(errorTableVersion, isNotEmpty);
      expect(int.tryParse(errorTableVersion.substring(0, 8)), isNotNull);
    });

    test('known HMS code resolves to its sentence', () {
      // 0300010000010001 - heatbed short circuit, first feed entry.
      const e = HmsEntry(attr: 0x03000100, code: 0x00010001);
      expect(hmsDescription(e),
          contains('heatbed temperature is abnormal'));
      expect(e.ecode, 'HMS_0300-0100-0001-0001');
    });

    test('unknown HMS code returns null (no crash, no empty string)', () {
      const e = HmsEntry(attr: 0x0FFFFFFF, code: 0xFFFFFFFF);
      expect(hmsDescription(e), isNull);
    });

    test('ecode formatting splits attr/code into 4 groups', () {
      const e = HmsEntry(attr: 0x0300_0200, code: 0x0002_0005);
      expect(e.ecode, 'HMS_0300-0200-0002-0005');
    });

    test('known print_error code resolves to its sentence', () {
      // 03004000 - Z axis homing failed (first err entry in the feed).
      expect(printErrorDescription(0x03004000),
          contains('Z axis homing failed'));
    });

    test('unknown print_error code returns null', () {
      expect(printErrorDescription(0xDEADBEEF), isNull);
    });

    test('wiki path exists for at least one code and lacks the host', () {
      const e = HmsEntry(attr: 0x03000100, code: 0x00010003);
      final path = hmsWikiPath(e);
      expect(path, isNotNull);
      expect(path, isNot(startsWith('http')));
      expect(path, contains('troubleshooting/hmscode/0300_0100_0001_0003'));
    });

    test('tables are non-trivial (feed actually loaded)', () {
      expect(kHmsErrorText.length, greaterThan(2000));
      expect(kPrintErrorText.length, greaterThan(400));
    });
  });
}
