import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/camera_profile.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/vision_guard.dart';
import 'package:deck/data/vision_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseVisionVerdict', () {
    test('plain JSON', () {
      final v = parseVisionVerdict(
          '{"platform_has_object":true,"print_running":true,'
          '"abnormal":"none","notes":"正常"}');
      expect(v, isNotNull);
      expect(v!.platformHasObject, isTrue);
      expect(v.printRunning, isTrue);
      expect(v.abnormal, 'none');
      expect(v.isAbnormal, isFalse);
    });

    test('markdown-fenced JSON with prose', () {
      final v = parseVisionVerdict('好的,以下是判断结果:\n```json\n'
          '{"platform_has_object":false,"print_running":true,'
          '"abnormal":"spaghetti","notes":"悬空出料"}\n```\n以上。');
      expect(v, isNotNull);
      expect(v!.abnormal, 'spaghetti');
      expect(v.isAbnormal, isTrue);
      expect(v.notes, '悬空出料');
    });

    test('empty abnormal falls back to none', () {
      final v = parseVisionVerdict(
          '{"platform_has_object":true,"abnormal":"","notes":"x"}');
      expect(v!.abnormal, 'none');
    });

    test('garbage returns null', () {
      expect(parseVisionVerdict('这不是JSON'), isNull);
      expect(parseVisionVerdict('{"unclosed": true'), isNull);
      expect(parseVisionVerdict('[1,2,3]'), isNull);
    });
  });

  group('VisionLlmClient 接口协议', () {
    final png = Uint8List.fromList([1, 2, 3]);

    test('OpenAI 形状: {base}/chat/completions + Bearer', () async {
      late Uri uri;
      late Map<String, dynamic> body;
      late Map<String, String> headers;
      final c = VisionLlmClient(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4/',
        apiKey: 'k',
        model: 'glm-4v-flash',
        postOverride: (u, b, h) async {
          uri = u;
          body = b;
          headers = h;
          return {
            'choices': [
              {'message': {'content': 'ok'}}
            ]
          };
        },
      );
      expect(await c.analyzeFrame(png), 'ok');
      expect(uri.toString(),
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
      expect(headers['authorization'], 'Bearer k');
      final part = (body['messages'] as List).first['content'][1];
      expect(part['type'], 'image_url');
      expect(part['image_url']['url'], startsWith('data:image/png;base64,'));
    });

    test('Anthropic 形状 (MiniMax): {base}/v1/messages + x-api-key', () async {
      late Uri uri;
      late Map<String, dynamic> body;
      late Map<String, String> headers;
      final c = VisionLlmClient(
        baseUrl: 'https://api.minimaxi.com/anthropic',
        apiKey: 'k',
        model: 'MiniMax-M3',
        postOverride: (u, b, h) async {
          uri = u;
          body = b;
          headers = h;
          return {
            'content': [
              {'type': 'text', 'text': '{"abnormal":"none"}'}
            ]
          };
        },
      );
      expect(await c.analyzeFrame(png), '{"abnormal":"none"}');
      expect(uri.toString(), 'https://api.minimaxi.com/anthropic/v1/messages');
      expect(headers['x-api-key'], 'k');
      expect(headers['anthropic-version'], isNotNull);
      final part = (body['messages'] as List).first['content'][1];
      expect(part['type'], 'image');
      expect(part['source']['type'], 'base64');
      expect(part['source']['media_type'], 'image/png');
    });

    test('…/anthropic/v1 结尾不会拼成 /v1/v1/messages', () async {
      late Uri uri;
      final c = VisionLlmClient(
        baseUrl: 'https://api.minimaxi.com/anthropic/v1',
        apiKey: 'k',
        model: 'MiniMax-M3',
        postOverride: (u, b, h) async {
          uri = u;
          return {'content': <dynamic>[]};
        },
      );
      await c.analyzeFrame(png);
      expect(uri.toString(), 'https://api.minimaxi.com/anthropic/v1/messages');
    });
  });

  group('VisionGuard', () {
    VisionGuard newGuard({
      required Future<VisionVerdict?> Function() onFrame,
      List<int>? pauseLog,
    }) {
      return VisionGuard(
        grab: (_) async => Uint8List.fromList([0xff, 0xd8]),
        pauseCommand: (id) async {
          pauseLog?.add(1);
          return true;
        },
        analyze: (_, __) => onFrame(),
      );
    }

    PrinterProfile printer() => PrinterProfile(
          id: 'p1',
          name: 'A1',
          mode: PrinterMode.lan,
          serial: 'S',
          ip: '1.2.3.4',
        );

    BambuState stateOf(GcodeState g) =>
        BambuState(updatedAt: DateTime.now(), gcodeState: g);

    List<CameraProfile> cams() => [
          CameraProfile(
              id: 'c1',
              name: 'cam',
              sourceType: CameraSourceType.rtsp,
              url: 'rtsp://x',
              printerIds: ['p1']),
        ];

    test('skips work unless printing', () async {
      final guard = newGuard(onFrame: () {
        fail('should not analyze while idle');
      });
      guard.settings =
          const AppSettings(visionEnabled: true, visionApiKey: 'k');
      guard.cameras = cams();
      guard.observeState(printer(), stateOf(GcodeState.idle));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(guard.reports, isEmpty);
      guard.dispose();
    });

    test('skips work when disabled or key missing', () async {
      for (final s in const [
        AppSettings(visionEnabled: false, visionApiKey: 'k'),
        AppSettings(visionEnabled: true, visionApiKey: ''),
      ]) {
        final guard = newGuard(onFrame: () {
          fail('should not analyze when disabled');
        });
        guard.settings = s;
        guard.cameras = cams();
        guard.observeState(printer(), stateOf(GcodeState.running));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(guard.reports, isEmpty);
        guard.dispose();
      }
    });

    test('abnormal frame notifies once per episode and can auto-pause',
        () async {
      final pauseLog = <int>[];
      final guard = newGuard(
        pauseLog: pauseLog,
        onFrame: () async => const VisionVerdict(
            platformHasObject: true,
            printRunning: true,
            abnormal: 'spaghetti',
            notes: '乱丝'),
      );
      guard.settings = const AppSettings(
        visionEnabled: true,
        visionApiKey: 'k',
        visionAutoPause: true,
        visionIntervalSec: 1,
      );
      guard.cameras = cams();
      guard.observeState(printer(), stateOf(GcodeState.running));
      // First tick: run + notify + pause.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guard.reports['p1']?.verdict?.abnormal, 'spaghetti');
      expect(pauseLog.length, 1);
      // Same episode: further analyses (after the interval gate) must not
      // pause again. Wait past both the 1s interval and the 5s tick so a
      // second run is guaranteed to have happened.
      await Future<void>.delayed(const Duration(milliseconds: 5250));
      expect(pauseLog.length, 1,
          reason: 'same anomaly episode notifies/pauses once');
      guard.dispose();
    });

    test('inconclusive frames never pause', () async {
      final pauseLog = <int>[];
      final guard = newGuard(
        pauseLog: pauseLog,
        onFrame: () async => null,
      );
      guard.settings = const AppSettings(
        visionEnabled: true,
        visionApiKey: 'k',
        visionAutoPause: true,
        visionIntervalSec: 1,
      );
      guard.cameras = cams();
      guard.observeState(printer(), stateOf(GcodeState.running));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guard.reports['p1']?.inconclusive, isTrue);
      expect(pauseLog, isEmpty);
      guard.dispose();
    });
  });
}
