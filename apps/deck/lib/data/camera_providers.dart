import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'camera_profile.dart';
import 'log_buffer.dart';

/// Riverpod wiring for the camera list (kept out of [CameraProfile]'s file so
/// the data class / store stay pure Dart for the standalone web service).
class CamerasNotifier extends AsyncNotifier<List<CameraProfile>> {
  @override
  Future<List<CameraProfile>> build() async {
    final cameras = await ref.watch(cameraStoreProvider).load();
    // Startup diagnostic (names only, never URLs): proves what the secure
    // store actually returned when someone reports missing cameras.
    LogBuffer.instance.add(cameras.isEmpty
        ? '已加载 0 个摄像头配置'
        : '已加载 ${cameras.length} 个摄像头: '
            '${cameras.map((c) => '${c.name}(${c.sourceType.name},'
                '绑${c.printerIds.length}台)').join('、')}');
    return cameras;
  }

  Future<void> add(CameraProfile camera) async {
    final store = ref.read(cameraStoreProvider);
    state = AsyncData([...state.valueOrNull ?? [], camera]);
    await store.save(state.valueOrNull ?? []);
  }

  Future<void> remove(String id) async {
    final store = ref.read(cameraStoreProvider);
    state =
        AsyncData((state.valueOrNull ?? []).where((c) => c.id != id).toList());
    await store.save(state.valueOrNull ?? []);
  }

  /// Replaces one camera (matched by id) and persists.
  Future<void> replace(CameraProfile camera) async {
    final store = ref.read(cameraStoreProvider);
    state = AsyncData([
      for (final c in state.valueOrNull ?? [])
        if (c.id == camera.id) camera else c,
    ]);
    await store.save(state.valueOrNull ?? []);
  }
}

final cameraStoreProvider = Provider<CameraStore>(
    (ref) => throw UnimplementedError('override cameraStoreProvider'));

final camerasProvider =
    AsyncNotifierProvider<CamerasNotifier, List<CameraProfile>>(
        CamerasNotifier.new);
