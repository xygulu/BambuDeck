import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/camera_providers.dart';
import 'package:deck/data/ezviz_cloud.dart';
import 'package:deck/data/ezviz_session.dart';
import 'package:deck/data/ezviz_streams.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/providers.dart';
import 'package:deck/data/settings_providers.dart';
import 'package:deck/features/dashboard/printer_camera_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打印机绑定摄像头 (2026-11-03): 云端摄像头要能出现在绑定清单里,
/// 绑定后要进入这台打印机的画面清单 (渲染由 [cameraSpecTile] 统一处理)。
class _Cameras implements CameraStore {
  _Cameras(this.items);
  List<CameraProfile> items;

  @override
  Future<List<CameraProfile>> load() async => items;

  @override
  Future<void> save(List<CameraProfile> cameras) async => items = cameras;
}

class _Printers implements PrinterStore {
  _Printers(this.items);
  List<PrinterProfile> items;

  @override
  Future<List<PrinterProfile>> load() async => items;

  @override
  Future<void> save(List<PrinterProfile> printers) async => items = printers;
}

class _Settings implements SettingsStore {
  // 机内摄像头默认关: 本测试只关心绑定进来的那台云端摄像头。
  AppSettings value = const AppSettings(builtinCamDefault: false);

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings s) async => value = s;
}

PrinterProfile _printer() => PrinterProfile(
      id: 'p1',
      name: '打印机',
      mode: PrinterMode.lan,
      serial: '03919D4A0803769',
      ip: '192.168.100.110',
      accessCode: '12345678',
    );

CameraProfile _cloud({bool bound = false}) => CameraProfile(
      id: 'c_cloud',
      name: '地下室',
      sourceType: CameraSourceType.ezviz,
      ezvizSerial: 'BA6764317',
      printerIds: bound ? ['p1'] : const [],
    );

CameraProfile _rtsp() => CameraProfile(
      id: 'c_rtsp',
      name: '老摄像头',
      sourceType: CameraSourceType.rtsp,
      url: 'rtsp://admin:pw@192.168.100.9:554/stream',
    );

/// 假会话: token 本地应答, 直播地址永不应答 - 测试里不建播放器, 不出网。
EzvizStreamCache _fakeCache() => EzvizStreamCache(
      session: EzvizSession(
        settings: () =>
            const AppSettings(ezvizAppKey: 'k', ezvizAppSecret: 's'),
        client: EzvizCloudClient(postOverride: (uri, fields) {
          if (uri.path.endsWith('/token/get')) {
            return Future.value({
              'code': '200',
              'data': {'accessToken': 'tok', 'expireTime': 604800},
            });
          }
          return Completer<Map<String, dynamic>>().future;
        }),
      ),
    );

List<Override> _overrides(_Cameras cameras) => [
      cameraStoreProvider.overrideWithValue(cameras),
      storeProvider.overrideWithValue(_Printers([_printer()])),
      settingsStoreProvider.overrideWithValue(_Settings()),
      ezvizStreamsProvider.overrideWithValue(_fakeCache()),
    ];

/// 只跑 [buildCameraSpecs], 不建播放器: widget test 里 media_kit 起不来,
/// 画面块的可见性定时器也会拖住收尾。
Future<List<CameraTileSpec>> _specsFor(
    WidgetTester tester, _Cameras cameras) async {
  var specs = <CameraTileSpec>[];
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(cameras),
    child: MaterialApp(
      home: Consumer(builder: (_, ref, __) {
        specs = buildCameraSpecs(ref, _printer());
        return const SizedBox();
      }),
    ),
  ));
  // 摄像头列表/设置是 AsyncNotifier: 多泵几轮让它落到 AsyncData。
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return specs;
}

void main() {
  testWidgets('绑定后云端摄像头进入这台打印机的画面清单', (tester) async {
    final specs = await _specsFor(tester, _Cameras([_cloud(bound: true)]));
    expect(specs, hasLength(1));
    expect(specs.single.id, 'c_cloud');
    expect(specs.single.cloudCamera, isNotNull);
    expect(specs.single.url, '');
    // 云端画面没有码流档位可切 (https FLV/HLS 只有一路)。
    expect(specs.single.onToggleQuality, isNull);
  });

  testWidgets('未绑定就不进清单', (tester) async {
    final specs = await _specsFor(tester, _Cameras([_cloud()]));
    expect(specs, isEmpty);
  });

  testWidgets('绑定对话框把云端摄像头列出来并可勾选', (tester) async {
    final cameras = _Cameras([_cloud(), _rtsp()]);
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(cameras),
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              // 预热: 打开对话框时 valueOrNull 必须已经有数据。
              ref.watch(camerasProvider);
              return TextButton(
                onPressed: () => PrinterCameraSection.editBindings(
                    context, ref, _printer(), false),
                child: const Text('绑定'),
              );
            },
          ),
        ),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();

    expect(find.text('地下室'), findsOneWidget);
    expect(find.text('云端'), findsOneWidget); // 云端来源标注
    expect(find.text('老摄像头'), findsOneWidget);

    await tester.tap(find.text('地下室'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(cameras.items.first.printerIds, ['p1']);
    expect(cameras.items.last.printerIds, isEmpty); // 未勾选的不动
  });
}
