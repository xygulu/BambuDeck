import 'dart:convert';
import 'dart:io';

import 'package:deck/data/file_secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// 数 Keychain 被读了几次 —— 种过一次后必须是 0 次(弹窗根治)。
class _KeychainSpy implements FlutterSecureStorage {
  _KeychainSpy(this.data);
  final Map<String, String?> data;
  int reads = 0;

  @override
  Future<String?> read(
      {required String key,
      IOSOptions? iOptions,
      AndroidOptions? aOptions,
      LinuxOptions? lOptions,
      WebOptions? webOptions,
      MacOsOptions? mOptions,
      WindowsOptions? wOptions}) async {
    reads++;
    return data[key];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory dir;
  late FileSecureStorage store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('deck_file_store_test');
    store = FileSecureStorage('${dir.path}/secure_store.json');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  group('FileSecureStorage', () {
    test('missing file reads as null, write/read roundtrips', () async {
      expect(await store.read('a'), isNull);
      await store.write('a', 'v1');
      expect(await store.read('a'), 'v1');
    });

    test('second write keeps a .bak with the previous content', () async {
      await store.write('k', 'old');
      await store.write('k', 'new');
      final bak = File('${dir.path}/secure_store.json.bak');
      expect(bak.existsSync(), isTrue);
      expect(jsonDecode(bak.readAsStringSync())['k'], 'old');
      expect(await store.read('k'), 'new');
    });

    test('corrupt main file falls back to .bak', () async {
      await store.write('k', 'good');
      await store.write('k2', 'x'); // 触发第二次落盘,bak 里是第一版
      File('${dir.path}/secure_store.json').writeAsStringSync('{broken');
      expect(await store.read('k'), 'good');
    });

    test('concurrent writes do not lose updates', () async {
      await Future.wait([
        store.write('a', '1'),
        store.write('b', '2'),
        store.write('c', '3'),
      ]);
      expect(await store.read('a'), '1');
      expect(await store.read('b'), '2');
      expect(await store.read('c'), '3');
    });
  });

  group('mergeSeedSegment', () {
    test('settings: local non-default wins, empty secrets filled from seed',
        () {
      final local = jsonEncode({
        'notifyOnFinish': false, // 用户改过的痕迹
        'hubToken': 'local-token',
        'visionApiKey': '',
      });
      final seed = jsonEncode({
        'notifyOnFinish': true,
        'hubToken': 'seed-token',
        'visionApiKey': 'seed-vision',
      });
      final out =
          jsonDecode(mergeSeedSegment('bambudeck.settings', local, seed))
              as Map<String, dynamic>;
      expect(out['notifyOnFinish'], false); // 本地权威
      expect(out['hubToken'], 'local-token'); // 非空不被覆盖
      expect(out['visionApiKey'], 'seed-vision'); // 空缺被补
    });

    test('settings: local default + seed has values -> wholesale adopt', () {
      final local = jsonEncode({'notifyOnFinish': true});
      final seed = jsonEncode({
        'notifyOnFinish': true,
        'ezvizAppKey': 'k',
        'ezvizAppSecret': 's',
      });
      final out =
          jsonDecode(mergeSeedSegment('bambudeck.settings', local, seed))
              as Map<String, dynamic>;
      expect(out['ezvizAppKey'], 'k');
      expect(out['ezvizAppSecret'], 's');
    });

    test('printers: fills empty accessCode/ip from seed, keeps local values',
        () {
      final local = jsonEncode([
        {
          'id': 'p1',
          'name': 'n1',
          'mode': 'lan',
          'serial': 'SN-A',
          'ip': '1.1.1.1',
          'accessCode': '',
          'token': '',
        },
      ]);
      final seed = jsonEncode([
        {
          'id': 'p1',
          'name': 'n1',
          'mode': 'cloud',
          'serial': 'SN-A',
          'ip': '2.2.2.2',
          'accessCode': 'code-A',
          'token': 'tk',
        },
      ]);
      final out =
          jsonDecode(mergeSeedSegment('bambudeck.printers', local, seed))
              as List<dynamic>;
      expect(out, hasLength(1));
      final p = out.first as Map<String, dynamic>;
      expect(p['accessCode'], 'code-A'); // 本地空 → 补
      expect(p['ip'], '1.1.1.1'); // 本地非空 → 保留
      expect(p['mode'], 'lan'); // 不降级
    });

    test('printers: seed-only printers appended', () {
      final local = jsonEncode([
        {
          'id': 'p1',
          'name': 'n1',
          'mode': 'lan',
          'serial': 'SN-A',
          'ip': '1.1.1.1',
          'accessCode': 'c',
        },
      ]);
      final seed = jsonEncode([
        {
          'id': 'p1',
          'name': 'n1',
          'mode': 'lan',
          'serial': 'SN-A',
          'ip': '1.1.1.1',
          'accessCode': 'c',
        },
        {
          'id': 'p2',
          'name': 'n2',
          'mode': 'cloud',
          'serial': 'SN-B',
          'ip': '',
          'accessCode': 'c2',
          'token': 't2',
        },
      ]);
      final out =
          jsonDecode(mergeSeedSegment('bambudeck.printers', local, seed))
              as List<dynamic>;
      expect(out, hasLength(2));
      expect((out.last as Map<String, dynamic>)['serial'], 'SN-B');
    });

    test('cameras: union by id, local wins', () {
      final local = jsonEncode([
        {'id': 'c1', 'name': 'a', 'sourceType': 'rtsp', 'url': 'mine'},
      ]);
      final seed = jsonEncode([
        {'id': 'c1', 'name': 'a', 'sourceType': 'rtsp', 'url': 'seed'},
        {'id': 'c2', 'name': 'b', 'sourceType': 'bambu', 'url': ''},
      ]);
      final out = jsonDecode(mergeSeedSegment('bambudeck.cameras', local, seed))
          as List<dynamic>;
      expect(out, hasLength(2));
      expect((out.first as Map<String, dynamic>)['url'], 'mine');
      expect((out.last as Map<String, dynamic>)['id'], 'c2');
    });

    test('broken seed keeps local untouched', () {
      final local = jsonEncode([
        {'id': 'c1', 'name': 'a', 'sourceType': 'rtsp', 'url': 'mine'},
      ]);
      final out =
          jsonDecode(mergeSeedSegment('bambudeck.cameras', local, '{broken'))
              as List<dynamic>;
      expect(out, hasLength(1));
      expect((out.first as Map<String, dynamic>)['url'], 'mine');
    });

    test('unknown key returns local raw as-is', () {
      expect(mergeSeedSegment('other.key', 'localraw', 'seedraw'), 'localraw');
    });
  });

  group('seedFileStore', () {
    test('文件已有数据就完全不碰 Keychain (不再弹授权框)', () async {
      await store.write('bambudeck.settings', '{}');
      final spy = _KeychainSpy({
        'bambudeck.printers': '[{"id":"p"}]',
        'bambudeck.settings': '{"hubToken":"seed"}',
        'bambudeck.cameras': '[]',
      });
      await seedFileStore(store, legacySource: spy, dpSource: spy);
      expect(spy.reads, 0);
    });

    test('空文件(全新安装)才从 Keychain 捞一次', () async {
      final spy = _KeychainSpy({
        'bambudeck.printers': '[{"id":"p"}]',
        'bambudeck.settings': null,
        'bambudeck.cameras': '[]',
      });
      await seedFileStore(store, legacySource: spy, dpSource: spy);
      // legacy 三个键 + dp 三个键 (settings 在 legacy 缺,dp 也来一遍)。
      expect(spy.reads, 6);
      expect(await store.read('bambudeck.printers'), '[{"id":"p"}]');
    });
  });
}
