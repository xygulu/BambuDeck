import 'package:deck/data/ezviz_cloud.dart';
import 'package:deck/data/ezviz_ptz.dart';
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

  group('cloud device management', () {
    test('device info maps name/model/version/status', () {
      final info = parseDeviceInfoResponse({
        'code': '200',
        'data': {
          'deviceSerial': 'C12345678',
          'deviceName': '门口',
          'deviceType': 'CS-C6',
          'deviceVersion': 'V5.7.3',
          'status': 1,
          'isEncrypt': 1,
        },
      });
      expect(info.name, '门口');
      expect(info.model, 'CS-C6');
      expect(info.version, 'V5.7.3');
      expect(info.online, isTrue);
      expect(info.isEncrypt, isTrue);
    });

    test('device info falls back to model and rejects a missing serial', () {
      final info = parseDeviceInfoResponse({
        'code': '200',
        'data': {'deviceSerial': 'S1', 'model': 'CS-H8', 'status': '2'},
      });
      expect(info.model, 'CS-H8');
      expect(info.online, isFalse);
      expect(
          () => parseDeviceInfoResponse({
                'code': '200',
                'data': {'deviceName': 'x'},
              }),
          throwsA(isA<EzvizApiException>()));
    });

    test('live address accepts data.url and data.ret.url shapes', () {
      expect(
          parseLiveAddressResponse({
            'code': '200',
            'data': {'url': 'https://hls.example/a.m3u8'},
          }),
          'https://hls.example/a.m3u8');
      expect(
          parseLiveAddressResponse({
            'code': '200',
            'data': {
              'ret': {'url': 'https://flv.example/b.flv'},
            },
          }),
          'https://flv.example/b.flv');
      // Official v2 shape: data is a list of address objects.
      expect(
          parseLiveAddressResponse({
            'code': '200',
            'data': [
              {'id': 'x', 'ret': '200', 'url': 'https://hls.example/c.m3u8'},
            ],
          }),
          'https://hls.example/c.m3u8');
      expect(
          () => parseLiveAddressResponse({'code': '200', 'data': {}}),
          throwsA(isA<EzvizApiException>()));
    });

    test('capture returns picUrl, including the list shape', () {
      expect(
          parseCaptureResponse({
            'code': '200',
            'data': {'picUrl': 'https://pic.example/1.jpg'},
          }),
          'https://pic.example/1.jpg');
      expect(
          parseCaptureResponse({
            'code': '200',
            'data': {
              'picUrlList': ['https://pic.example/2.jpg'],
            },
          }),
          'https://pic.example/2.jpg');
    });

    test('client sends the documented fields for every endpoint', () async {
      final calls = <(String, Map<String, String>)>[];
      Future<Map<String, dynamic>> post(Uri uri, Map<String, String> f) async {
        calls.add((uri.path, f));
        if (uri.path.endsWith('/device/info')) {
          return {
            'code': '200',
            'data': {'deviceSerial': 'S1', 'status': '1'},
          };
        }
        if (uri.path.endsWith('/device/capture')) {
          return {
            'code': '200',
            'data': {'picUrl': 'https://pic.example/x.jpg'},
          };
        }
        if (uri.path.endsWith('/v2/live/address/get')) {
          return {
            'code': '200',
            'data': {'url': 'https://live.example/x.flv'},
          };
        }
        return {'code': '200', 'data': null};
      }

      final client = EzvizCloudClient(postOverride: post);
      await client.fetchDeviceInfo('tok', 'S1');
      await client.renameDevice('tok', 'S1', '新名字');
      await client.capture('tok', 'S1');
      await client.liveAddress('tok', 'S1', protocol: 4, quality: 1);
      await client.ptzStart('tok', 'S1', 6, speed: 2);
      await client.ptzStop('tok', 'S1', 6);

      expect(calls.map((c) => c.$1), [
        '/api/lapp/device/info',
        '/api/lapp/device/name/update',
        '/api/lapp/device/capture',
        '/api/lapp/v2/live/address/get',
        '/api/lapp/device/ptz/start',
        '/api/lapp/device/ptz/stop',
      ]);
      expect(calls[1].$2['deviceName'], '新名字');
      expect(calls[2].$2['channelNo'], '1');
      expect(calls[3].$2['protocol'], '4');
      expect(calls[3].$2['quality'], '1');
      expect(calls[3].$2['type'], '1');
      expect(calls[4].$2['direction'], '6');
      expect(calls[4].$2['speed'], '2');
      // Stop must repeat the same direction (platform requirement).
      expect(calls[5].$2['direction'], '6');
    });
  });

  group('cloud PTZ direction mapping', () {
    test('arrows map to the documented direction codes', () {
      expect(EzvizCloudPtz.directionFor(tilt: 0.5), 0); // 上
      expect(EzvizCloudPtz.directionFor(tilt: -0.5), 1); // 下
      expect(EzvizCloudPtz.directionFor(pan: -0.5), 2); // 左
      expect(EzvizCloudPtz.directionFor(pan: 0.5), 3); // 右
      expect(EzvizCloudPtz.directionFor(pan: -0.5, tilt: 0.5), 4); // 左上
      expect(EzvizCloudPtz.directionFor(pan: -0.5, tilt: -0.5), 5); // 左下
      expect(EzvizCloudPtz.directionFor(pan: 0.5, tilt: 0.5), 6); // 右上
      expect(EzvizCloudPtz.directionFor(pan: 0.5, tilt: -0.5), 7); // 右下
      expect(EzvizCloudPtz.directionFor(zoom: 0.5), 8); // 放大
      expect(EzvizCloudPtz.directionFor(zoom: -0.5), 9); // 缩小
      expect(EzvizCloudPtz.directionFor(), isNull);
    });
  });
}
