import 'package:deck/data/ezviz_cloud.dart';
import 'package:deck/features/cameras/ezviz_import_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ezviz open-platform envelope parsing', () {
    test('token: code as string, data carries accessToken', () {
      final token = parseTokenResponse({
        'code': '200',
        'msg': '操作成功!',
        'data': {'accessToken': 'at.abc123', 'expireTime': 86400},
      });
      expect(token, 'at.abc123');
    });

    test('token: numeric code and missing token both raise', () {
      expect(
          () => parseTokenResponse({
                'code': 200,
                'data': {},
              }),
          throwsA(isA<EzvizApiException>()));
      expect(
          () => parseTokenResponse({
                'code': '10002',
                'msg': 'appSecret错误',
              }),
          throwsA(isA<EzvizApiException>().having(
              (e) => e.message, 'message', 'appSecret错误')));
    });

    test('device list maps the documented fields', () {
      final devices = parseDeviceListResponse({
        'code': '200',
        'data': [
          {
            'deviceSerial': 'C12345678',
            'deviceName': '打印房门口',
            'model': 'CS-C5S-1B2WFR',
            'status': 1,
            'isEncrypt': 1,
          },
          {
            'deviceSerial': 'D87654321',
            'deviceName': '车间',
            'model': 'CS-H8c',
            'status': '0',
            'isEncrypt': '0',
          },
          {'deviceSerial': '', 'deviceName': '无序列号的脏数据'},
          'not-a-map',
        ],
      });
      expect(devices.length, 2);
      expect(devices[0].serial, 'C12345678');
      expect(devices[0].online, isTrue);
      expect(devices[0].isEncrypt, isTrue);
      expect(devices[1].online, isFalse);
      expect(devices[1].isEncrypt, isFalse);
    });

    test('device list error envelope throws', () {
      expect(
          () => parseDeviceListResponse({
                'code': '20018',
                'msg': 'accessToken失效',
              }),
          throwsA(isA<EzvizApiException>()));
    });

    test('client walks pages until a short page', () async {
      final pageRequests = <Map<String, String>>[];
      final client = EzvizCloudClient(
        postOverride: (uri, fields) async {
          pageRequests.add(fields);
          final page = int.parse(fields['pageNum']!);
          return {
            'code': '200',
            'data': [
              for (var i = 0; i < (page == 1 ? 50 : 3); i++)
                {
                  'deviceSerial': 'S${page}_$i',
                  'deviceName': 'dev',
                  'status': '1',
                  'isEncrypt': '1',
                },
            ],
          };
        },
      );
      final devices = await client.fetchDevices('tok');
      expect(devices.length, 53);
      expect(pageRequests.map((f) => f['pageNum']), ['1', '2']);
    });
  });

  group('verification-code prefill', () {
    test('ezvizRtspUrl round-trips through code extraction', () {
      final url = ezvizRtspUrl(ip: '192.168.100.66', code: 'ABC123');
      expect(
          url, 'rtsp://admin:ABC123@192.168.100.66:554/h264/ch1/main/av_stream');
      expect(verificationCodeFromUrl(url), 'ABC123');
      expect(verificationCodeFromUrl('rtsp://nocode@host/x'), isNull);
      expect(verificationCodeFromUrl('not a url'), isNull);
    });
  });
}
