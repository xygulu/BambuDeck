import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:deck/data/printer_profile.dart';
import 'package:deck/data/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Never touches the network: emits a canned status/state.
class _FakeLink implements PrinterLink {
  _FakeLink();

  @override
  Stream<BambuState> get states => const Stream<BambuState>.empty();

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

  @override
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
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
}
