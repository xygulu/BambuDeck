import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:test/test.dart';

void main() {
  // A1 mini 实机 device.xml 的骨架 (标签大小写/命名空间随固件)。
  const xml = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <URLBase>http://192.168.100.110</URLBase>
  <device>
    <deviceType>urn:bambulab-com:device:3dprinter::1</deviceType>
    <friendlyName>A1 mini</friendlyName>
    <serialNumber>00M00A4B0600001</serialNumber>
    <presentationURL>/webcam</presentationURL>
  </device>
</root>
''';

  test('extractTag finds serial, name and type case-insensitively', () {
    expect(extractTag(xml, 'serialNumber'), '00M00A4B0600001');
    expect(extractTag(xml, 'friendlyName'), 'A1 mini');
    expect(extractTag(xml, 'deviceType'),
        'urn:bambulab-com:device:3dprinter::1');
    expect(extractTag(xml, 'nonexistent'), isNull);
    expect(extractTag(xml, 'SERIALNUMBER'), '00M00A4B0600001');
  });

  test('headerValue tolerates any casing and CRLF responses', () {
    final res = 'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'LOCATION: http://192.168.100.110:2021/device.xml?uuid=ab-cd\r\n'
        'Server: Built-in UPnP/1.0\r\n'
        'ST: urn:bambulab-com:device:3dprinter::1\r\n'
        '\r\n';
    expect(headerValue(res, 'location'),
        'http://192.168.100.110:2021/device.xml?uuid=ab-cd');
    expect(headerValue(res, 'st'), 'urn:bambulab-com:device:3dprinter::1');
    expect(headerValue(res, 'USN'), isNull);
  });

  test('headerValue handles LF-only responses too', () {
    // 有些固件用 \n 分行。
    final res = 'HTTP/1.1 200 OK\nLOCATION: http://10.0.0.5/device.xml\n\n';
    expect(headerValue(res, 'LOCATION'), 'http://10.0.0.5/device.xml');
  });
}
