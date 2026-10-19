import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/app_settings.dart';
import 'package:deck/data/print_events.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements SettingsStore {
  _MemoryStore();
  String? _raw;

  @override
  Future<AppSettings> load() async {
    final r = _raw;
    if (r == null || r.isEmpty) return const AppSettings();
    return AppSettings.fromJson(jsonDecode(r) as Map<String, dynamic>);
  }

  @override
  Future<void> save(AppSettings s) async =>
      _raw = const JsonEncoder().convert(s.toJson());
}

class _RecordingNotifier implements DeckNotifier {
  final calls = <({String title, String body})>[];

  @override
  Future<void> show({required String title, required String body}) async {
    calls.add((title: title, body: body));
  }
}

PrinterProfile _profile(String id) => PrinterProfile(
      id: id,
      name: '测试机 $id',
      mode: PrinterMode.lan,
      serial: 'SN$id',
      ip: '192.168.1.$id',
      accessCode: 'code',
    );

BambuState _state(GcodeState g, {List<HmsEntry> hms = const []}) =>
    parseReport({
      'print': {
        'gcode_state': g.label,
        'mc_percent': 88,
        if (hms.isNotEmpty)
          'hms': [
            for (final e in hms) {'attr': e.attr, 'code': e.code},
          ],
      },
    })!;

void main() {
  group('AppSettings store', () {
    test('absent blob loads defaults (notifications on)', () async {
      final s = await _MemoryStore().load();
      expect(s.notifyOnFinish, isTrue);
      expect(s.notifyOnError, isTrue);
    });

    test('roundtrip preserves toggles', () async {
      final store = _MemoryStore();
      await store.save(const AppSettings(
          notifyOnFinish: false, notifyOnError: true));
      final s = await store.load();
      expect(s.notifyOnFinish, isFalse);
      expect(s.notifyOnError, isTrue);
    });
  });

  group('PrintEventWatcher', () {
    test('FINISH transition notifies once', () async {
      final rec = _RecordingNotifier();
      final w = PrintEventWatcher(notifier: rec)
        ..settings = const AppSettings();
      final p = _profile('a');
      final idle = _state(GcodeState.idle);
      final done = _state(GcodeState.finish);

      expect(await w.observe(p, null, idle), isNull); // first frame
      expect(await w.observe(p, idle, _state(GcodeState.running)), isNull);
      expect(await w.observe(p, _state(GcodeState.running), done),
          '✅ 打印完成');
      expect(await w.observe(p, done, _state(GcodeState.idle)), isNull);
      expect(rec.calls.single.body, contains('测试机 a · 88%'));
    });

    test('finish notification respects the settings switch', () async {
      final rec = _RecordingNotifier();
      final w = PrintEventWatcher(notifier: rec)
        ..settings = const AppSettings(notifyOnFinish: false);
      final p = _profile('a');
      await w.observe(p, _state(GcodeState.running), _state(GcodeState.finish));
      expect(rec.calls, isEmpty);
    });

    test('error onset carries the sentence-table text', () async {
      final rec = _RecordingNotifier();
      final w = PrintEventWatcher(notifier: rec)
        ..settings = const AppSettings();
      final p = _profile('b');
      const heatbed = HmsEntry(attr: 0x03000100, code: 0x00010001);
      await w.observe(p, _state(GcodeState.running),
          _state(GcodeState.running, hms: const [heatbed]));
      expect(rec.calls.single.title, '⚠ 测试机 b 打印机报错');
      expect(rec.calls.single.body, contains('heatbed'));
      // Persisting error: no repeat.
      await w.observe(p, null, _state(GcodeState.running));
      expect(rec.calls.length, 1);
    });

    test('print_error onset falls back to the err table', () async {
      final rec = _RecordingNotifier();
      final w = PrintEventWatcher(notifier: rec)
        ..settings = const AppSettings();
      final p = _profile('c');
      final err = parseReport({
        'print': {
          'gcode_state': 'RUNNING',
          'print_error': 0x03004000, // Z axis homing failed
        },
      })!;
      await w.observe(p, _state(GcodeState.running), err);
      expect(rec.calls.single.body, contains('Z axis homing failed'));
    });
  });
}
