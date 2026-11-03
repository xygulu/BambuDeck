import 'dart:convert';
import 'dart:io';

import 'package:deck/data/app_settings.dart';
import 'package:deck/data/hub_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File f;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('deck_hubcfg_test');
    f = File('${dir.path}/hub.json');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('roundtrip 保存与读取', () async {
    await saveHubConfig(
        HubConfig(settings: const AppSettings().copyWith(hubPort: 9911)), f);
    final back = await loadHubConfig(f);
    expect(back.settings.hubPort, 9911);
  });

  test('第二次保存留下 .bak,主文件损坏时自动回退', () async {
    await saveHubConfig(
        HubConfig(settings: const AppSettings().copyWith(hubPort: 8788)), f);
    await saveHubConfig(
        HubConfig(settings: const AppSettings().copyWith(hubPort: 8789)), f);
    final bak = File('${f.path}.bak');
    expect(bak.existsSync(), isTrue);
    final bakCfg = HubConfig.fromJson(
        jsonDecode(bak.readAsStringSync()) as Map<String, dynamic>);
    expect(bakCfg.settings.hubPort, 8788);

    // 主文件写成半截 JSON(模拟写到一半被杀)
    f.writeAsStringSync('{"settings": {"hubPort":');
    final back = await loadHubConfig(f);
    expect(back.settings.hubPort, 8788,
        reason: '主文件坏了应回退到 .bak,而不是读成空');
  });

  test('主文件空 → 回退 .bak', () async {
    await saveHubConfig(
        HubConfig(settings: const AppSettings().copyWith(hubPort: 8788)), f);
    await saveHubConfig(
        HubConfig(settings: const AppSettings().copyWith(hubPort: 8789)), f);
    f.writeAsStringSync('');
    final back = await loadHubConfig(f);
    expect(back.settings.hubPort, 8788);
  });

  test('主文件与 .bak 都坏 → 返回空配置(不抛)', () async {
    f.writeAsStringSync('{broken');
    File('${f.path}.bak').writeAsStringSync('{also broken');
    final back = await loadHubConfig(f);
    expect(back.printers, isEmpty);
  });

  test('保存是原子的:不留 .tmp 残留', () async {
    await saveHubConfig(const HubConfig(), f);
    expect(File('${f.path}.tmp').existsSync(), isFalse);
  });
}
