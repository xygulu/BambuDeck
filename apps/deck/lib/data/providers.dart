import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_api.dart';
import 'hub_server.dart';
import 'log_buffer.dart';
import 'print_events.dart';
import 'printer_profile.dart';
import 'vision_guard.dart';

/// Composition root bindings - overridden in main.dart (secure storage) and
/// tests (in-memory stores, fake links).
final storeProvider = Provider<PrinterStore>(
    (ref) => throw UnimplementedError('override storeProvider in main()'));

final cloudApiProvider = Provider<CloudApi>((ref) => HttpCloudApi());

/// Connection factory seam: the app binds MQTT; tests bind fakes.
typedef PrinterLinkFactory = PrinterLink Function(PrinterProfile profile);

/// MQTT 命令签名私钥(打印类命令必须签名,见 bambu_signing.dart)。仓库外
/// 文件 ~/.bambudeck/signing_key.pem,由 main() 启动时装载;缺失 = 未签名
/// 路径(新固件拒收 84033543)。
String? bambuSigningKeyPem;

final printerLinkFactoryProvider = Provider<PrinterLinkFactory>((ref) =>
    (profile) => MqttPrinterLink(profile, signingKeyPem: bambuSigningKeyPem));

/// One live printer connection, abstracted so the hub relay / a test fake
/// can substitute for the MQTT transport later (PRD FR-9).
abstract class PrinterLink {
  Stream<BambuState> get states;
  Stream<BambuConnStatus> get status;
  Future<void> connect();
  void dispose();

  Future<bool> pause();
  Future<bool> resume();
  Future<bool> stop();
  Future<bool> setSpeed(int level);
  Future<bool> setLight(bool on);
  Future<bool> refresh();

  /// Prints a 3mf already on the printer (一键换盘 uploads it first).
  /// [ams] routes the print through a live AMS slot (换盘 PLA 匹配).
  Future<bool> printProjectFile({
    required String url,
    String param,
    String md5,
    String name,
    ({int amsId, int slot})? ams,
  });
}

class MqttPrinterLink implements PrinterLink {
  MqttPrinterLink(this.profile, {String? signingKeyPem}) {
    _client = BambuMqttClient(config: profile.toMqttConfig(),
        log: LogBuffer.instance.add, signingKeyPem: signingKeyPem);
  }

  final PrinterProfile profile;
  late final BambuMqttClient _client;

  @override
  Stream<BambuState> get states => _client.states;

  @override
  Stream<BambuConnStatus> get status => _client.status;

  @override
  Future<void> connect() => _client.connect();

  @override
  void dispose() => _client.dispose();

  @override
  Future<bool> pause() => _client.pausePrint();

  @override
  Future<bool> resume() => _client.resumePrint();

  @override
  Future<bool> stop() => _client.stopPrint();

  @override
  Future<bool> setSpeed(int level) => _client.setSpeedLevel(level);

  @override
  Future<bool> setLight(bool on) => _client.setChamberLight(on);

  @override
  Future<bool> refresh() => _client.requestPushall(reason: 'manual');

  @override
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
    ({int amsId, int slot})? ams,
  }) =>
      _client.printProjectFile(
          url: url,
          param: param,
          md5: md5,
          name: name,
          amsSlot: ams?.slot,
          amsId: ams?.amsId ?? 0);
}

/// The configured printer list (profiles only - live state lives in
/// [connectionProvider]).
class PrintersNotifier extends AsyncNotifier<List<PrinterProfile>> {
  @override
  Future<List<PrinterProfile>> build() async {
    final store = ref.watch(storeProvider);
    return store.load();
  }

  Future<void> add(PrinterProfile profile) async {
    final store = ref.read(storeProvider);
    state = AsyncData([...state.valueOrNull ?? [], profile]);
    await store.save(state.valueOrNull ?? []);
  }

  Future<void> remove(String id) async {
    final store = ref.read(storeProvider);
    state = AsyncData(
        (state.valueOrNull ?? []).where((p) => p.id != id).toList());
    await store.save(state.valueOrNull ?? []);
  }

  /// Config import (FR-10 backup): swaps the whole list, dropping live
  /// connections via the per-id watch in ConnectionNotifier.build.
  Future<void> replaceAll(List<PrinterProfile> printers) async {
    final store = ref.read(storeProvider);
    state = AsyncData(List.of(printers));
    await store.save(state.valueOrNull ?? []);
  }

  PrinterProfile? byId(String id) {
    final list = state.valueOrNull ?? const [];
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }
}

final printersProvider =
    AsyncNotifierProvider<PrintersNotifier, List<PrinterProfile>>(
        PrintersNotifier.new);

/// Reactive single-printer lookup: watches the list and returns the profile
/// with [id], or null while the list is loading / once it is removed. Widgets
/// must use this (via `printersProvider.select`) instead of
/// `printersProvider.notifier.byId(id)` - the notifier listenable does not
/// rebuild on list changes, so a cosmetic edit (机内画面 toggle) would leave
/// the switch and camera tiles stale.
PrinterProfile? printerByIdOf(List<PrinterProfile>? list, String id) {
  if (list == null) return null;
  for (final p in list) {
    if (p.id == id) return p;
  }
  return null;
}

/// Live connection state for one printer (keyed by profile id).
class PrinterConnection {
  const PrinterConnection({
    this.status = BambuConnStatus.disconnected,
    this.state,
    this.lastError,
  });

  final BambuConnStatus status;
  final BambuState? state;
  final String? lastError;

  PrinterConnection copyWith({
    BambuConnStatus? status,
    BambuState? state,
    String? lastError,
  }) =>
      PrinterConnection(
        status: status ?? this.status,
        state: state ?? this.state,
        lastError: lastError ?? this.lastError,
      );

  bool get live =>
      status == BambuConnStatus.connected ||
      status == BambuConnStatus.connecting ||
      status == BambuConnStatus.reconnecting;
}

class ConnectionNotifier extends FamilyNotifier<PrinterConnection, String> {
  PrinterLink? _link;
  StreamSubscription<BambuState>? _stateSub;
  StreamSubscription<BambuConnStatus>? _statusSub;

  /// Last connection key we wired up; cosmetic edits (name / builtinCam /
  /// model) change the profile object identity and re-run [build], but only
  /// a key change tears down the live link and reconnects.
  (String, String, String, String, CloudRegion, String, String)? _lastConnKey;

  /// Latest connection state, mirrored in a field so [build] can return it
  /// on a no-op rebuild. Riverpod forbids reading `state` inside [build]
  /// (it is uninitialized there), so the cosmetic-edit path must not
  /// `return state` - that threw "Tried to read the state of an
  /// uninitialized provider" and red-screened the app (机内画面 2026-10-20).
  PrinterConnection _current =
      const PrinterConnection(status: BambuConnStatus.disconnected);

  @override
  PrinterConnection build(String arg) {
    final profile = ref.watch(printersProvider
        .select((list) => list.valueOrNull?.firstWhere((p) => p.id == arg)));

    // Profile gone (removed / still loading): idle.
    if (profile == null) {
      _teardown();
      _lastConnKey = null;
      _current = const PrinterConnection(status: BambuConnStatus.disconnected);
      return _current;
    }

    ref.onDispose(_teardown);

    // Only connection-relevant fields reconnect. A cosmetic edit must NOT
    // rebuild the page (toggling 机内画面 was reconnecting the whole MQTT
    // link and refreshing the monitor - 反馈 2026-10-20).
    if (profile.connectionKey == _lastConnKey) {
      return _current;
    }
    _lastConnKey = profile.connectionKey;
    _teardown();
    _connect(profile);
    _current = const PrinterConnection(status: BambuConnStatus.connecting);
    return _current;
  }

  Future<void> _connect(PrinterProfile profile) async {
    final link = ref.read(printerLinkFactoryProvider)(profile);
    _link = link;
    _statusSub = link.status.listen((s) {
      _current = _current.copyWith(status: s);
      state = _current;
    });
    _stateSub = link.states.listen((s) {
      final prev = _current.state;
      _current = _current.copyWith(state: s, lastError: null);
      state = _current;
      printEvents.observe(profile, prev, s);
      visionGuard.observeState(profile, s);
      hubServer.observeState(profile, s);
    });
    await link.connect();
  }

  void _teardown() {
    _stateSub?.cancel();
    _statusSub?.cancel();
    _stateSub = null;
    _statusSub = null;
    _link?.dispose();
    _link = null;
  }

  // -- commands (no-ops when disconnected) ----------------------------------

  Future<bool> pause() => _link?.pause() ?? Future.value(false);
  Future<bool> resume() => _link?.resume() ?? Future.value(false);
  Future<bool> stop() => _link?.stop() ?? Future.value(false);
  Future<bool> setSpeed(int level) =>
      _link?.setSpeed(level) ?? Future.value(false);
  Future<bool> setLight(bool on) =>
      _link?.setLight(on) ?? Future.value(false);
  Future<bool> refresh() => _link?.refresh() ?? Future.value(false);
  Future<bool> printProjectFile({
    required String url,
    String param = 'Metadata/plate_1.gcode',
    String md5 = '',
    String name = 'BambuDeck',
    ({int amsId, int slot})? ams,
  }) =>
      _link?.printProjectFile(
          url: url,
          param: param,
          md5: md5,
          name: name,
          ams: ams) ??
      Future.value(false);
}

final connectionProvider = NotifierProvider.family<ConnectionNotifier,
    PrinterConnection, String>(ConnectionNotifier.new);

/// Cover (plate preview) URL of a printer's latest cloud task - the same
/// picture Bambu Handy shows (反馈 2026-10-20). Keyed by (profile, task):
/// a new job name refetches. Null for LAN-only profiles (no token) or
/// when the account has no covered task; failures degrade to null, the
/// preview is best-effort decoration, never an error surface.
final taskCoverProvider =
    FutureProvider.family<String?, (String, String)>((ref, key) async {
  final (profileId, _) = key;
  final printers = ref.watch(printersProvider).valueOrNull ?? const [];
  PrinterProfile? profile;
  for (final p in printers) {
    if (p.id == profileId) profile = p;
  }
  if (profile == null || profile.token.isEmpty || profile.serial.isEmpty) {
    return null;
  }
  try {
    return await fetchCloudTaskCover(
        profile.token, profile.region, profile.serial);
  } catch (_) {
    return null;
  }
});
