import 'dart:typed_data';

import 'package:deck/data/app_settings.dart';
import 'package:deck/data/vision_llm.dart';
import 'package:flutter_test/flutter_test.dart';

/// 视觉模型「主用 + 备用」(2026-10-29)。
///
/// 主用一次 429 / key 过期 / 网关超时，不该让整台打印机的视觉巡检停摆：
/// 换备用再问一遍，只有全挂才算这一帧不可用。
VisionLlmClient fake(String model, String? Function() reply,
    {void Function()? onCall}) {
  return VisionLlmClient(
    baseUrl: 'https://example.invalid/v1',
    apiKey: 'k',
    model: model,
    postOverride: (uri, body, headers) async {
      onCall?.call();
      final text = reply();
      if (text == null) {
        throw const FormatException('boom');
      }
      return {
        'choices': [
          {
            'message': {'content': text}
          }
        ]
      };
    },
  );
}

void main() {
  final png = Uint8List.fromList([1, 2, 3]);

  test('主用正常：备用一次都不调', () async {
    var backupCalls = 0;
    final chain = VisionChain([
      fake('primary', () => '{"abnormal":"none"}'),
      fake('backup', () => 'x', onCall: () => backupCalls++),
    ]);
    expect(await chain.analyzeFrame(png), contains('abnormal'));
    expect(backupCalls, 0);
  });

  test('主用请求失败：自动换备用', () async {
    final chain = VisionChain([
      fake('primary', () => null),
      fake('backup', () => '{"abnormal":"spaghetti"}'),
    ]);
    expect(await chain.analyzeFrame(png), contains('spaghetti'));
  });

  test('全部失败返回 null（调用方按不可判定处理）', () async {
    final chain = VisionChain([
      fake('primary', () => null),
      fake('backup', () => null),
    ]);
    expect(await chain.analyzeFrame(png), isNull);
  });

  test('备用未配 key 时不进链', () {
    const s = AppSettings();
    expect(VisionChain.fromSettings(s).clients.length, 1);
    final withBackup = s.copyWith(visionFallbackApiKey: 'sk-x');
    final chain = VisionChain.fromSettings(withBackup);
    expect(chain.clients.length, 2);
    expect(chain.clients.last.model, 'qwen3.8-flash');
  });

  test('备用和主用完全一样就去重（不重试同一个坏端点）', () {
    final s = const AppSettings(visionApiKey: 'k', visionModel: 'glm-4v-flash')
        .copyWith(
      visionFallbackBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      visionFallbackApiKey: 'k',
      visionFallbackModel: 'glm-4v-flash',
    );
    expect(VisionChain.fromSettings(s).clients.length, 1);
  });

  test('动态队列：失败的沉底，下次先问可用的那个（只问一次）', () async {
    VisionRotation.reset();
    var primaryCalls = 0;
    var backupCalls = 0;
    final chain = VisionChain([
      fake('primary', () => null, onCall: () => primaryCalls++),
      fake('backup', () => '{"abnormal":"none"}', onCall: () => backupCalls++),
    ]);
    expect(await chain.analyzeFrame(png), isNotNull);
    expect(primaryCalls, 1);
    expect(backupCalls, 1);

    // 第二次：backup 已在队首，primary 不再被白白试一次。
    expect(await chain.analyzeFrame(png), isNotNull);
    expect(primaryCalls, 1);
    expect(backupCalls, 2);
  });

  test('队首挂了轮到底部那个，它恢复后重新排到最前', () async {
    VisionRotation.reset();
    var aDown = true;
    var bDown = false;
    var aCalls = 0;
    final chain = VisionChain([
      fake('a', () => aDown ? null : '{"abnormal":"none"}',
          onCall: () => aCalls++),
      fake('b', () => bDown ? null : '{"abnormal":"spaghetti"}'),
    ]);
    // a 挂 -> 换 b，b 升到队首。
    expect(await chain.analyzeFrame(png), contains('spaghetti'));
    // b 也挂了 -> 沉到队尾，轮到恢复了的 a，a 回到最前。
    bDown = true;
    aDown = false;
    expect(await chain.analyzeFrame(png), contains('none'));
    // 下一次直接问 a，坏掉的 b 不再被白白试一次。
    final before = aCalls;
    expect(await chain.analyzeFrame(png), contains('none'));
    expect(aCalls, before + 1);
  });

  test('只配备用也算已配置（主用 key 空也跑）', () {
    final s = const AppSettings().copyWith(visionFallbackApiKey: 'sk-x');
    expect(VisionChain.fromSettings(s).isConfigured, isTrue);
    expect(VisionChain.fromSettings(const AppSettings()).isConfigured,
        isFalse);
  });
}
