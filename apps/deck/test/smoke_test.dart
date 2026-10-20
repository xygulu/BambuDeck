import 'dart:convert';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/core/theme.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/main.dart';
import 'package:deck/data/providers.dart';
import 'package:deck/features/home/home_page.dart';
import 'package:deck/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemStore implements PrinterStore {
  @override
  Future<List<PrinterProfile>> load() async => const [];

  @override
  Future<void> save(List<PrinterProfile> printers) async {}
}

class _LoadedStore implements PrinterStore {
  _LoadedStore(this.printers);
  final List<PrinterProfile> printers;

  @override
  Future<List<PrinterProfile>> load() async => printers;

  @override
  Future<void> save(List<PrinterProfile> printers) async {}
}

/// Never touches the network: emits `connected` plus an optional canned
/// state, so widget tests exercise the real provider graph without MQTT.
class _FakeLink implements PrinterLink {
  _FakeLink({this.initialState});

  final BambuState? initialState;

  @override
  Stream<BambuState> get states => initialState == null
      ? const Stream<BambuState>.empty()
      : Stream<BambuState>.value(initialState!);

  @override
  Stream<BambuConnStatus> get status =>
      Stream<BambuConnStatus>.value(BambuConnStatus.connected);

  @override
  Future<void> connect() async {}

  @override
  void dispose() {}

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> setSpeed(int level) async => true;

  @override
  Future<bool> setLight(bool on) async => true;

  @override
  Future<bool> refresh() async => true;
}

Widget _wrap({
  List<PrinterProfile> printers = const [],
  BambuState? linkState,
}) {
  return ProviderScope(
    overrides: [
      storeProvider.overrideWith((ref) =>
          printers.isEmpty ? _MemStore() : _LoadedStore(printers)),
      printerLinkFactoryProvider
          .overrideWith((ref) => (profile) => _FakeLink(initialState: linkState)),
    ],
    child: MaterialApp(theme: buildDeckTheme(), home: const HomePage()),
  );
}

void main() {
  testWidgets('DeckApp root builds (compiles main.dart)', (tester) async {
    // DeckApp itself is provider-clean; the scope carries the store override
    // the real main() would apply, without touching secure storage.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        storeProvider
            .overrideWith((ref) => _MemStore()),
      ],
      child: const DeckApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.text('BambuDeck'), findsOneWidget);
  });

  testWidgets('home shows empty state', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    expect(find.text('还没有打印机'), findsOneWidget);
    expect(find.text('添加第一台打印机'), findsOneWidget);
  });

  testWidgets('home renders one configured printer card', (tester) async {
    final running = parseReport(jsonDecode(_cardReport))!;
    await tester.pumpWidget(_wrap(printers: [
      PrinterProfile(
        id: 'p1',
        name: '打印房 P1S',
        mode: PrinterMode.lan,
        serial: '00M1234567890',
        ip: '192.168.1.42',
        accessCode: '12345678',
      ),
    ], linkState: running));
    await tester.pumpAndSettle();
    expect(find.text('打印房 P1S'), findsOneWidget);
    expect(find.text('局域网 · 已连接'), findsOneWidget);
    expect(find.text('打印中'), findsOneWidget); // state badge
    expect(find.text('benchy'), findsOneWidget); // slim card task line
  });

  testWidgets('progress ring paints and reports percent', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDeckTheme(),
      home: const Scaffold(
        body: Center(
            child:
                ProgressRing(progress: 42, color: DeckColors.running)),
      ),
    ));
    expect(find.text('42%'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('HMS card renders worst-first severities', (tester) async {
    final state = parseReport(jsonDecode(_errReport))!;
    await tester.pumpWidget(MaterialApp(
      theme: buildDeckTheme(),
      home: Scaffold(body: HmsCard(state: state)),
    ));
    expect(find.text('HMS 错误 (2)'), findsOneWidget);
    expect(find.textContaining('致命'), findsOneWidget); // fatal sorts first
    expect(find.textContaining('一般'), findsOneWidget);
    expect(find.textContaining('0300-0000'), findsNWidgets(2));
  });

  testWidgets('HMS card hidden when healthy', (tester) async {
    final state = parseReport(jsonDecode('{"print":{"gcode_state":"IDLE"}}'))!;
    await tester.pumpWidget(MaterialApp(
      theme: buildDeckTheme(),
      home: Scaffold(body: HmsCard(state: state)),
    ));
    expect(find.textContaining('HMS'), findsNothing);
  });

  testWidgets('HMS card shows the feed sentence for known codes',
      (tester) async {
    // 0x03000100/0x00010001 - heatbed short circuit, a real feed entry.
    final state = parseReport(jsonDecode(
        '{"print":{"gcode_state":"RUNNING",'
        '"hms":[{"attr": 50331904, "code": 65537}]}}'))!;
    await tester.pumpWidget(MaterialApp(
      theme: buildDeckTheme(),
      home: Scaffold(body: HmsCard(state: state)),
    ));
    expect(find.textContaining('HMS_0300-0100-0001-0001'), findsOneWidget);
    expect(find.textContaining('heatbed temperature is abnormal'),
        findsOneWidget);
  });

  testWidgets('print_error resolves to the feed sentence', (tester) async {
    // 0x03004000 - Z axis homing failed (first err entry).
    final state = parseReport(jsonDecode(
        '{"print":{"gcode_state":"RUNNING","print_error": 50348032}}'))!;
    await tester.pumpWidget(MaterialApp(
      theme: buildDeckTheme(),
      home: Scaffold(body: HmsCard(state: state)),
    ));
    expect(find.textContaining('Z axis homing failed'), findsOneWidget);
  });
}

const _cardReport = '''
{
  "print": {
    "gcode_state": "RUNNING",
    "mc_percent": 42,
    "subtask_name": "benchy",
    "nozzle_temper": 220,
    "bed_temper": 55,
    "layer_num": 12,
    "total_layer_num": 230
  }
}
''';

const _errReport = '''
{
  "print": {
    "gcode_state": "RUNNING",
    "hms": [
      {"attr": 50331648, "code": 196608},
      {"attr": 50331648, "code": 65536}
    ]
  }
}
''';
// attr 0x03000000 -> hexKey starts 03000000; codes 0x00010000 (fatal) and
// 0x00030000 (common) -> sorted fatal first: 0300-0001 then 0300-0003.
