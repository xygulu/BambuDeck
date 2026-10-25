import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Never touches the network: emits a canned status/state.
class _FakeLink implements PrinterLink {
  _FakeLink({this.onSetSpeed});

  /// 调速的假固件行为 (返回 sent/accepted/reason)。
  Future<({bool sent, bool? accepted, String? reason})> Function(int level)?
      onSetSpeed;

  final _states = StreamController<BambuState>.broadcast();

  void emit(BambuState s) => _states.add(s);

  @override
  Stream<BambuState> get states => _states.stream;

  @override
  Stream<BambuConnStatus> get status =>
      Stream<BambuConnStatus>.value(BambuConnStatus.connected);

  @override
  Future<void> connect() async {}

  @override
  void dispose() => _states.close();

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> stop() async => true;

  @override
  Future<bool> setSpeed(int level) async => true;

  @override
  Future<({bool sent, bool? accepted, String? reason})> setSpeedChecked(
          int level) async =>
      await onSetSpeed?.call(level) ??
      (sent: true, accepted: true, reason: null);

  @override
  Future<bool> setLight(bool on) async => true;

  @override
  Future<bool> refresh() async => true;

  @override
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
    ({int amsId, int slot})? ams,
  }) async =>
      true;
}

class _Store implements PrinterStore {
  _Store(this.printers);
  List<PrinterProfile> printers;

  @override
  Future<List<PrinterProfile>> load() async => printers;

  @override
  Future<void> save(List<PrinterProfile> printers) async {
    this.printers = printers;
  }
}

PrinterProfile _profile({BuiltinCamSetting builtinCam = BuiltinCamSetting.follow}) =>
    PrinterProfile(
      id: 'p1',
      name: '打印房 P1S',
      mode: PrinterMode.lan,
      serial: '00M1234567890',
      ip: '192.168.1.42',
      accessCode: '12345678',
      builtinCam: builtinCam,
    );

void main() {
  test('机内画面 toggle (builtinCam copyWith) must not throw uninitialized provider',
      () async {
    final store = _Store([_profile()]);
    final container = ProviderContainer(overrides: [
      storeProvider.overrideWithValue(store),
      printerLinkFactoryProvider.overrideWith((ref) => (p) => _FakeLink()),
    ]);
    addTearDown(container.dispose);

    // Warm the printer list and the live connection for p1.
    await container.read(printersProvider.future);
    final sub = container.listen(connectionProvider('p1'), (_, __) {});
    addTearDown(sub.close);
    // Let the connection settle (fake emits `connected`).
    await Future<void>.delayed(Duration.zero);

    // This is exactly what setBuiltinCam does on the 机内画面 switch.
    final printers = container.read(printersProvider).valueOrNull ?? const [];
    await container.read(printersProvider.notifier).replaceAll([
      for (final p in printers)
        p.id == 'p1'
            ? p.copyWith(builtinCam: BuiltinCamSetting.on)
            : p,
    ]);

    // Reaching here without throwing is the regression check.
    final conn = container.read(connectionProvider('p1'));
    expect(conn.status, BambuConnStatus.connected);
  });

  test('调速被固件拒收时如实返回未确认 (不再假装成功)', () async {
    final link = _FakeLink(
        onSetSpeed: (level) async => (
              sent: true,
              accepted: false,
              reason: 'print_speed 被拒(84033543)',
            ));
    final container = await _warm(link);
    final r = await container
        .read(connectionProvider('p1').notifier)
        .setSpeedConfirmed(3);
    expect(r.sent, isTrue);
    expect(r.confirmed, isFalse);
    expect(r.note, contains('拒收'));
    expect(r.note, contains('84033543'));
  });

  test('调速后打印机会回报新档位 = 已确认', () async {
    final link = _FakeLink();
    link.onSetSpeed = (level) async {
      // 固件执行完在下一次状态帧里带 spd_lvl。
      Timer(const Duration(milliseconds: 50),
          () => link.emit(BambuState(updatedAt: DateTime.now(), speedLevel: level)));
      return (sent: true, accepted: true, reason: 'print_speed 成功');
    };
    final container = await _warm(link);
    final r = await container
        .read(connectionProvider('p1').notifier)
        .setSpeedConfirmed(3);
    expect(r.sent, isTrue);
    expect(r.confirmed, isTrue);
    expect(r.note, isNull);
  });
}

/// Container with p1 warmed up (printer list loaded + connection built).
Future<ProviderContainer> _warm(PrinterLink link) async {
  final container = ProviderContainer(overrides: [
    storeProvider.overrideWithValue(_Store([_profile()])),
    printerLinkFactoryProvider.overrideWith((ref) => (p) => link),
  ]);
  addTearDown(container.dispose);
  await container.read(printersProvider.future);
  final sub = container.listen(connectionProvider('p1'), (_, __) {});
  addTearDown(sub.close);
  await Future<void>.delayed(Duration.zero);
  return container;
}
