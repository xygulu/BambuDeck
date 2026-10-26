import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_api.dart';
import 'hub_server.dart';
import 'print_events.dart';
import 'printer_link.dart';
import 'printer_profile.dart';
import 'vision_guard.dart';

export 'printer_link.dart';

/// Composition root bindings - overridden in main.dart (secure storage) and
/// tests (in-memory stores, fake links).
final storeProvider = Provider<PrinterStore>(
    (ref) => throw UnimplementedError('override storeProvider in main()'));

final cloudApiProvider = Provider<CloudApi>((ref) => HttpCloudApi());

/// Connection factory seam: the app binds MQTT; tests bind fakes.
typedef PrinterLinkFactory = PrinterLink Function(PrinterProfile profile);

/// MQTT 命令签名私钥(见 bambu_signing.dart)。App 走未签名直发(依赖打印机
/// 开发者模式,签名补不了 url_enc 加密 + app_cert_install,换盘 2026-10-21),
/// 故保持 null;仅将来实现完整加密签名链路时才需要装载。
String? bambuSigningKeyPem;

final printerLinkFactoryProvider = Provider<PrinterLinkFactory>((ref) =>
    (profile) => MqttPrinterLink(profile, signingKeyPem: bambuSigningKeyPem));

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
  Future<bool> setSpeed(int level) => setSpeedConfirmed(level)
      .then((r) => r.sent, onError: (_) => false);

  /// 调速 + 等打印机确认（纯逻辑见 printer_link.dart 的 [confirmSpeedLevel]）。
  Future<({bool sent, bool confirmed, String? note})> setSpeedConfirmed(
      int level) async {
    final link = _link;
    if (link == null) return (sent: false, confirmed: false, note: null);
    return confirmSpeedLevel(link, level, state: () => _current.state);
  }

  /// 等打印机状态帧里的 spd_lvl 变成 level。
  ///
  /// 走 Bambu Connect 调速时用它做权威确认: Connect 界面上那个百分比是
  /// 云端绕一圈回来的(实测 2~20 秒)，局域网状态帧是打印机直报的(秒级)。
  Future<bool> awaitSpeed(int level,
          {Duration within = const Duration(seconds: 10)}) =>
      awaitSpeedLevel(level, () => _current.state, within: within);
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
