import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/camera_profile.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../ui/camera_tile.dart';
import '../cameras/cameras_page.dart';

/// Session-scoped manual override of the built-in camera picture: null
/// follows the per-printer tri-state + global default; true/false is what
/// the card switch or the 打开机内摄像头 button last chose (not persisted -
/// the persisted preference is the tri-state in the binding dialog).
final builtinCamManualProvider =
    StateProvider.family<bool?, String>((ref, id) => null);

/// Camera area for one printer (FR-4 组合画面 + 机内摄像头默认开关):
/// the built-in camera per the effective policy, then every RTSP camera
/// bound to this printer, plus the binding/add-camera entry points.
/// Lives at the top of the dashboard body and inside the monitoring
/// screen's right pane - both are this section's host.
class PrinterCameraSection extends ConsumerWidget {
  const PrinterCameraSection({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(printersProvider.notifier).byId(profileId);
    if (profile == null) return const SizedBox.shrink();
    final settings = ref.watch(appSettingsProvider).valueOrNull ??
        const AppSettings();
    final cameras = ref.watch(camerasProvider).valueOrNull ?? const [];
    final manual = ref.watch(builtinCamManualProvider(profileId));
    final builtinOn =
        manual ?? profile.builtinCamDefaultOn(settings.builtinCamDefault);
    final bound = cameras
        .where((c) =>
            c.sourceType == CameraSourceType.rtsp &&
            c.enabled &&
            c.printerIds.contains(profileId))
        .toList();

    final hasAny = builtinOn || bound.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const Text('监控画面',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.tune, size: 20),
              tooltip: '绑定与默认设置',
              onPressed: () =>
                  _editBindings(context, ref, profile, settings.builtinCamDefault),
            ),
            IconButton(
              icon: const Icon(Icons.video_call, size: 20),
              tooltip: '添加摄像头',
              onPressed: () => showAddCameraDialog(context, ref),
            ),
          ]),
        ),
        if (!hasAny)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              '暂无画面 - 点右上角添加摄像头,或在绑定设置里开启机内摄像头',
              style: TextStyle(
                  fontSize: 12,
                  color: DeckColors.textSecondary.withValues(alpha: 0.9)),
            ),
          )
        else ...[
          if (builtinOn && profile.mode == PrinterMode.lan)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _LiveTile(
                cameraId: '$profileId-builtin',
                child: CameraTile(
                  streamUrl: _builtinUrl(profile),
                  label: '机内摄像头',
                ),
              ),
            )
          else if (profile.mode == PrinterMode.lan)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _OpenBuiltinTile(
                onOpen: () => ref
                    .read(builtinCamManualProvider(profileId).notifier)
                    .state = true,
              ),
            ),
          for (final c in bound)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _LiveTile(
                cameraId: c.id,
                child: CameraTile(
                  streamUrl: c.resolveUrl(null) ?? '',
                  label: c.name,
                  onToggleQuality: qualityToggler(ref, c),
                ),
              ),
            ),
        ],
      ],
    );
  }

  String _builtinUrl(PrinterProfile profile) {
    final camera = CameraProfile(
      id: 'builtin',
      name: '机内摄像头',
      sourceType: CameraSourceType.bambu,
      printerIds: [profile.id],
    );
    return camera.resolveUrl(profile) ?? '';
  }

  /// Binding management: per-printer built-in camera tri-state (跟随全局 /
  /// 开启 / 关闭) plus multi-select binding of RTSP cameras (FR-4 多对多).
  Future<void> _editBindings(
    BuildContext context,
    WidgetRef ref,
    PrinterProfile profile,
    bool globalDefault,
  ) async {
    final cameras = ref.read(camerasProvider).valueOrNull ?? const [];
    final selected = {
      for (final c in cameras)
        if (c.printerIds.contains(profile.id)) c.id,
    };
    var tri = profile.builtinCam;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: DeckColors.surface,
          title: Text('摄像头 · ${profile.name}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('机内摄像头默认',
                      style: TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
                ),
                const SizedBox(height: 6),
                SegmentedButton<BuiltinCamSetting>(
                  segments: const [
                    ButtonSegment(
                        value: BuiltinCamSetting.follow, label: Text('全局')),
                    ButtonSegment(
                        value: BuiltinCamSetting.on, label: Text('开启')),
                    ButtonSegment(
                        value: BuiltinCamSetting.off, label: Text('关闭')),
                  ],
                  selected: {tri},
                  onSelectionChanged: (s) => setState(() => tri = s.first),
                ),
                Text(
                  '当前全局默认: ${globalDefault ? '开启' : '关闭'};「全局」即跟随此开关',
                  style: TextStyle(
                      fontSize: 11,
                      color: DeckColors.textSecondary.withValues(alpha: 0.9)),
                ),
                const SizedBox(height: 14),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('绑定的 RTSP 摄像头(可多选)',
                      style: TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
                ),
                if (cameras
                    .where((c) => c.sourceType == CameraSourceType.rtsp)
                    .isEmpty) ...[
                  const SizedBox(height: 8),
                  Text('还没有 RTSP 摄像头 - 关闭此对话框后点右上角添加',
                      style: TextStyle(
                          fontSize: 12,
                          color: DeckColors.textSecondary.withValues(alpha: 0.9))),
                ] else
                  for (final c in cameras)
                    if (c.sourceType == CameraSourceType.rtsp)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(c.id),
                        title: Text(c.name,
                            style: const TextStyle(fontSize: 13)),
                        onChanged: (v) => setState(() {
                          v == true
                              ? selected.add(c.id)
                              : selected.remove(c.id);
                        }),
                      ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    // Persist the tri-state and the RTSP bindings.
    final printers = ref.read(printersProvider).valueOrNull ?? const [];
    await ref.read(printersProvider.notifier).replaceAll([
      for (final p in printers)
        p.id == profile.id ? p.copyWith(builtinCam: tri) : p,
    ]);
    for (final c in cameras.where((c) => c.sourceType ==
        CameraSourceType.rtsp)) {
      final bound = c.printerIds.contains(profile.id);
      final want = selected.contains(c.id);
      if (bound == want) continue;
      await ref.read(camerasProvider.notifier).replace(c.copyWith(
            printerIds: want
                ? [...c.printerIds, profile.id]
                : c.printerIds.where((id) => id != profile.id).toList(),
          ));
    }
    // A saved tri-state supersedes the session toggle.
    ref.invalidate(builtinCamManualProvider(profileId));
  }
}

/// Mounts the tile only while visible (NFR-3): scrolled-out streams stop
/// pulling; a placeholder says why the picture went away.
class _LiveTile extends StatefulWidget {
  const _LiveTile({required this.cameraId, required this.child});

  final String cameraId;
  final Widget child;

  @override
  State<_LiveTile> createState() => _LiveTileState();
}

class _LiveTileState extends State<_LiveTile> {
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('sec-${widget.cameraId}'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction > 0.05;
        if (mounted && visible != _visible) {
          setState(() => _visible = visible);
        }
      },
      child: _visible
          ? widget.child
          : ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                color: Colors.black,
                height: 120,
                alignment: Alignment.center,
                child: const Text('画面已在后台暂停',
                    style: TextStyle(
                        fontSize: 13, color: DeckColors.textSecondary)),
              ),
            ),
    );
  }
}

/// Placeholder for a policy-off built-in camera: one tap opens it for this
/// session (需求 3 手动打开机内摄像头).
class _OpenBuiltinTile extends StatelessWidget {
  const _OpenBuiltinTile({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Container(
        color: Colors.black,
        height: 120,
        alignment: Alignment.center,
        child: FilledButton.tonalIcon(
          onPressed: onOpen,
          icon: const Icon(Icons.videocam_outlined, size: 18),
          label: const Text('打开机内摄像头'),
        ),
      ),
    );
  }
}
