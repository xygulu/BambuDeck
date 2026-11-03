import 'package:deck/data/app_settings.dart';
import 'package:deck/data/ezviz_cloud.dart';
import 'package:deck/data/ezviz_session.dart';
import 'package:deck/data/ezviz_streams.dart';
import 'package:flutter_test/flutter_test.dart';

/// 萤石云端取流缓存 (直接读云端 2026-11-03): TTL、单飞、失效与节流。
void main() {
  AppSettings fakeSettings() =>
      const AppSettings(ezvizAppKey: 'k', ezvizAppSecret: 's');

  /// Wraps a live-address fake so the session's /token/get (which [EzvizSession]
  /// calls first) gets the object-shaped data it parses.
  Future<Map<String, dynamic>> Function(Uri, Map<String, String>) fakePost(
    Future<Map<String, dynamic>> Function(Uri uri, Map<String, String> fields)
        live,
  ) =>
      (uri, fields) async {
        if (uri.path.endsWith('/token/get')) {
          return {
            'code': '200',
            'data': {'accessToken': 'tok', 'expireTime': 604800},
          };
        }
        return live(uri, fields);
      };

  EzvizSession sessionWith(
    Future<Map<String, dynamic>> Function(Uri uri, Map<String, String> fields)
        post,
  ) =>
      EzvizSession(
        settings: fakeSettings,
        client: EzvizCloudClient(postOverride: fakePost(post)),
      );

  test('fetch resolves FLV main and caches within ttl', () async {
    final paths = <String>[];
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        paths.add(uri.path);
        expect(fields['deviceSerial'], 'S1');
        expect(fields['protocol'], '4');
        return {
          'code': '200',
          'data': [
            {
              'url': 'https://gw.flv/x?sign=1',
              'ret': {'code': 0}
            },
          ],
        };
      }),
    );
    final url = await cache.fetch('S1');
    expect(url, 'https://gw.flv/x?sign=1');
    expect(paths, ['/api/lapp/v2/live/address/get']);
    expect(cache.cached('S1'), url);
    // Second fetch within ttl serves the cache - no extra API call.
    expect(await cache.fetch('S1'), url);
    expect(paths.length, 1);
  });

  test('expired entry is not handed out; refetch replaces it', () async {
    var now = DateTime(2026, 11, 3);
    var calls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/call$calls.flv'},
          ],
        };
      }),
      now: () => now,
    );
    final first = await cache.fetch('S1');
    expect(first, 'https://gw/call1.flv');
    now = now.add(const Duration(minutes: 5)); // ttl is 4 min
    expect(cache.cached('S1'), isNull);
    final second = await cache.fetch('S1');
    expect(second, 'https://gw/call2.flv');
    expect(calls, 2);
  });

  test('FLV failure falls back to HLS', () async {
    final protocols = <String>[];
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        protocols.add(fields['protocol']!);
        if (fields['protocol'] == '4') {
          return {'code': '60000', 'msg': '获取直播地址失败'};
        }
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/x.m3u8'},
          ],
        };
      }),
    );
    expect(await cache.fetch('S1'), 'https://gw/x.m3u8');
    expect(protocols, ['4', '2']);
  });

  test('failure returns null, logs, and does not cache', () async {
    var calls = 0;
    final logs = <String>[];
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        return {'code': '60000', 'msg': 'device offline'};
      }),
      log: logs.add,
    );
    expect(await cache.fetch('S1'), isNull);
    expect(await cache.fetch('S1'), isNull); // no cache entry -> tries again
    // 每次 fetch 都是 FLV(4) 失败退 HLS(2) 各打一次, 两轮共 4 次。
    expect(calls, 4);
    expect(logs, isNotEmpty);
    expect(cache.cached('S1'), isNull);
  });

  test('invalidate drops the entry; forced refetch is throttled', () async {
    var calls = 0;
    var now = DateTime(2026, 11, 3);
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/call$calls.flv'},
          ],
        };
      }),
      now: () => now,
    );
    expect(await cache.fetch('S1'), isNotNull);
    cache.invalidate('S1');
    expect(cache.cached('S1'), isNull);

    // markFailed-style forced refetch goes through once...
    now = now.add(const Duration(seconds: 1));
    final fresh = await cache.fetch('S1', force: true);
    expect(fresh, 'https://gw/call2.flv');
    expect(calls, 2);

    // ...but an immediate second forced fetch stays inside the throttle
    // window: nothing new is requested, and since the fresh entry is still
    // valid the cached address comes back.
    final throttled = await cache.fetch('S1', force: true);
    expect(throttled, 'https://gw/call2.flv');
    expect(calls, 2);

    // After the window the next forced fetch really refetches.
    now = now.add(const Duration(seconds: 16));
    expect(await cache.fetch('S1', force: true), 'https://gw/call3.flv');
    expect(calls, 3);
  });

  test('empty serial never hits the API', () async {
    var calls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        return {'code': '200', 'data': []};
      }),
    );
    expect(await cache.fetch(''), isNull);
    expect(await cache.fetch('  '), isNull);
    expect(calls, 0);
  });

  test('concurrent fetches share one request (single-flight)', () async {
    var calls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/once.flv'},
          ],
        };
      }),
    );
    final results = await Future.wait(
        [cache.fetch('S1'), cache.fetch('S1'), cache.fetch('S1')]);
    expect(results, everyElement('https://gw/once.flv'));
    expect(calls, 1);
  });

  test('H265 智能编码设备被拒后带 supportH265=1 重试成功', () async {
    final h265Flags = <String>[];
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        h265Flags.add(fields['supportH265'] ?? '(缺省)');
        if (fields['supportH265'] != '1') {
          return {'code': '60000', 'msg': '视频编码类型非 H264'};
        }
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/h265.flv'},
          ],
        };
      }),
    );
    expect(await cache.fetchOrThrow('S1'), 'https://gw/h265.flv');
    // 第一次带 supportH265=0 被拒, 重试那次带上了 supportH265=1。
    expect(h265Flags, ['0', '1']);
    expect(cache.cached('S1'), 'https://gw/h265.flv');
  });

  test('60019 自动关闭视频加密后重取成功', () async {
    var offCalls = 0;
    var liveCalls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        if (uri.path.endsWith('/device/encrypt/off')) {
          offCalls++;
          expect(fields['deviceSerial'], 'S1');
          return {'code': '200', 'msg': '操作成功!'};
        }
        liveCalls++;
        if (liveCalls == 1) return {'code': '60019', 'msg': '加密已开启'};
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/after_off.flv'},
          ],
        };
      }),
    );
    expect(await cache.fetchOrThrow('S1'), 'https://gw/after_off.flv');
    expect(offCalls, 1);
    expect(liveCalls, 2); // 60019 -> 关加密 -> 重取
  });

  test('自动关闭被平台拒绝时给可行动的提示', () async {
    var offCalls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        if (uri.path.endsWith('/device/encrypt/off')) {
          offCalls++;
          return {'code': '20010', 'msg': '设备验证码错误'};
        }
        return {'code': '60019', 'msg': '加密已开启'};
      }),
    );
    await expectLater(
      cache.fetchOrThrow('S1'),
      throwsA(isA<EzvizApiException>()
          .having((e) => e.code, 'code', '60019')
          .having((e) => e.message, 'message', contains('自动关闭失败'))
          .having((e) => e.message, 'message', contains('设备验证码错误'))),
    );
    expect(offCalls, 1);
    expect(cache.cached('S1'), isNull);
  });

  test('fetchOrThrow serves the ttl cache without an API call', () async {
    var calls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/live.flv'},
          ],
        };
      }),
    );
    expect(await cache.fetchOrThrow('S1'), 'https://gw/live.flv');
    expect(await cache.fetchOrThrow('S1'), 'https://gw/live.flv');
    expect(calls, 1);
  });

  test('连续断流后优先 HLS; HLS 打不通回落 FLV 即恢复 FLV 优先', () async {
    final protocols = <String>[];
    var hlsFails = false;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        final p = fields['protocol']!;
        protocols.add(p);
        if (p == '2' && hlsFails) return {'code': '60000', 'msg': 'HLS 不可用'};
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/p$p.m3u8'},
          ],
        };
      }),
    );
    expect(await cache.fetch('S1'), 'https://gw/p4.m3u8');
    expect(protocols, ['4']); // 默认 FLV

    cache
      ..invalidate('S1')
      ..invalidate('S1');
    protocols.clear();
    expect(await cache.fetch('S1'), 'https://gw/p2.m3u8');
    expect(protocols, ['2']); // 断两次后改走 HLS

    // HLS 打不通时回落 FLV, FLV 成功即清零计数。
    hlsFails = true;
    cache
      ..invalidate('S1')
      ..invalidate('S1');
    protocols.clear();
    expect(await cache.fetch('S1'), 'https://gw/p4.m3u8');
    expect(protocols, ['2', '4']);

    // 只断一次 (<2) 就仍优先 FLV —— 证明上面的成功把计数清零了。
    cache.invalidate('S1');
    protocols.clear();
    expect(await cache.fetch('S1'), 'https://gw/p4.m3u8');
    expect(protocols, ['4']);
  });

  test('fetchOrThrow shares the single-flight with fetch', () async {
    var calls = 0;
    final cache = EzvizStreamCache(
      session: sessionWith((uri, fields) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return {
          'code': '200',
          'data': [
            {'url': 'https://gw/shared.flv'},
          ],
        };
      }),
    );
    final results = await Future.wait([
      cache.fetchOrThrow('S1'),
      cache.fetch('S1'),
      cache.fetchOrThrow('S1')
    ]);
    expect(results, everyElement('https://gw/shared.flv'));
    expect(calls, 1);
  });
}
