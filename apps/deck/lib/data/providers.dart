import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_api.dart';
import 'printer_profile.dart';

/// Composition root bindings - overridden in main.dart (secure storage) and
/// tests (in-memory stores, fake links).
final storeProvider = Provider<PrinterStore>(
    (ref) => throw UnimplementedError('override storeProvider in main()'));

final cloudApiProvider = Provider<CloudApi>((ref) => HttpCloudApi());

/// Connection factory seam: the app binds MQTT; tests bind fakes.
typedef PrinterLinkFactory = PrinterLink Function(PrinterProfile profile);

final printerLinkFactoryProvider =
    Provider<PrinterLinkFactory>((ref) => MqttPrinterLink.new);

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
}

class MqttPrinterLink implements PrinterLink {
  MqttPrinterLink(this.profile) {
    _client = BambuMqttClient(config: profile.toMqttConfig(), log: (line) {
      // MVP: connection diagnostics land in the log page (M5).
      assert(() {
        // ignore: avoid_print
        print(line);
        return true;
      }());
    });
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

  @override
  PrinterConnection build(String arg) {
    final profile = ref.watch(printersProvider
        .select((list) => list.valueOrNull?.firstWhere((p) => p.id == arg)));

    // Profile gone (removed / still loading): idle.
    if (profile == null) {
      _teardown();
      return const PrinterConnection(status: BambuConnStatus.disconnected);
    }

    // Rebuild fires whenever the profile changes -> fresh connection.
    _teardown();
    _connect(profile);

    ref.onDispose(_teardown);
    return const PrinterConnection(status: BambuConnStatus.connecting);
  }

  Future<void> _connect(PrinterProfile profile) async {
    final link = ref.read(printerLinkFactoryProvider)(profile);
    _link = link;
    _statusSub = link.status.listen((s) {
      state = state.copyWith(status: s);
    });
    _stateSub = link.states.listen((s) {
      state = state.copyWith(state: s, lastError: null);
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
}

final connectionProvider = NotifierProvider.family<ConnectionNotifier,
    PrinterConnection, String>(ConnectionNotifier.new);
