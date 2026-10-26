import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/camera_profile.dart';
import '../../data/camera_providers.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/settings_providers.dart';
import '../../ui/camera_tile.dart';
import '../../ui/visible_tile.dart';
import '../cameras/cameras_page.dart';

/// Single source of truth for the built-in camera default-load choice of
/// one printer: the persisted per-printer tri-state. The card switch, the
/// 打开机内摄像头 button and the binding dialog all read/write this, so
/// they can never drift apart (反馈 2026-10-20).
Future<void> setBuiltinCam(
    WidgetRef ref, PrinterProfile profile, bool on) async {
  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  await ref.read(printersProvider.notifier).replaceAll([
    for (final p in printers)
      p.id == profile.id
          ? p.copyWith(
              builtinCam: on ? BuiltinCamSetting.on : BuiltinCamSetting.off)
          : p,
  ]);
}

/// Stream URL of a printer's built-in camera ('' when not derivable, e.g.
/// cloud-mode printers).
String builtinCameraUrl(PrinterProfile profile) {
  final camera = CameraProfile(
    id: 'builtin',
    name: '机内摄像头',
    sourceType: CameraSourceType.bambu,
    printerIds: [profile.id],
  );
  return camera.resolveUrl(profile) ?? '';
}

/// One tile in a printer's camera wall: enough to render a [CameraTile].
class CameraTileSpec {
  const CameraTileSpec({
    required this.id,
    required this.label,
    required this.url,
    this.onToggleQuality,
    this.flipH = false,
    this.rotationDeg = 0,
    this.ptzInvertPan = false,
    this.ptzInvertTilt = false,
    this.onToggleFlip,
    this.onSetRotation,
  });

  final String id;
  final String label;
  final String url;

  /// Main/sub quality chip closure; null hides the chip.
  final VoidCallback? onToggleQuality;

  /// Horizontal mirror / clockwise rotation for the picture (画面翻转和旋转
  /// 2026-10-20). Built-in synthesized tiles leave these at defaults.
  final bool flipH;
  final int rotationDeg;

  /// PTZ axis calibration carried to [CameraTile] (云台方向校准).
  final bool ptzInvertPan;
  final bool ptzInvertTilt;
  final VoidCallback? onToggleFlip;
  final ValueChanged<int>? onSetRotation;
}

/// The camera tiles for one printer, in display order: built-in camera
/// first (when the persisted policy turns it on), then every enabled RTSP
/// camera bound to this printer. Shared by the vertical section and the
/// camera wall.
List<CameraTileSpec> buildCameraSpecs(WidgetRef ref, PrinterProfile profile) {
  final settings =
      ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
  final cameras = ref.watch(camerasProvider).valueOrNull ?? const [];
  final specs = <CameraTileSpec>[];
  if (profile.builtinCamDefaultOn(settings.builtinCamDefault) &&
      profile.mode == PrinterMode.lan) {
    specs.add(CameraTileSpec(
      id: '${profile.id}-builtin',
      label: '机内摄像头',
      url: builtinCameraUrl(profile),
    ));
  }
  for (final c in cameras) {
    if (c.sourceType != CameraSourceType.rtsp ||
        !c.enabled ||
        !c.printerIds.contains(profile.id)) {
      continue;
    }
    specs.add(CameraTileSpec(
      id: c.id,
      label: c.name,
      url: c.resolveUrl(null) ?? '',
      onToggleQuality: qualityToggler(ref, c),
      flipH: c.flipH,
      rotationDeg: c.rotationDeg,
      ptzInvertPan: c.ptzInvertPan,
      ptzInvertTilt: c.ptzInvertTilt,
      onToggleFlip: flipToggler(ref, c),
      onSetRotation: rotationSetter(ref, c),
    ));
  }
  return specs;
}

/// 监控画面 title row with the binding/add-camera entries, shared by the
/// vertical section and the camera wall.
Widget cameraSectionHeader(
    BuildContext context, WidgetRef ref, PrinterProfile profile) {
  final settings =
      ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
  final builtinOn = profile.builtinCamDefaultOn(settings.builtinCamDefault);
  final lan = profile.mode == PrinterMode.lan;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(children: [
      const Text('监控画面',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      const Spacer(),
      // 机内摄像头快速开关 (反馈 2026-10-20): the slim printer card dropped
      // its control row, so the switch lives on the camera section header,
      // shown by both the dashboard and the monitor right pane.
      Text('机内画面',
          style: TextStyle(
              fontSize: 12,
              color: lan
                  ? DeckColors.textSecondary
                  : DeckColors.textSecondary.withValues(alpha: 0.4))),
      Switch(
        value: builtinOn,
        activeThumbColor: DeckColors.running,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: lan ? (v) => setBuiltinCam(ref, profile, v) : null,
      ),
      const SizedBox(width: 4),
      TextButton.icon(
        onPressed: () => PrinterCameraSection.editBindings(
            context, ref, profile, settings.builtinCamDefault),
        icon: const Icon(Icons.tune, size: 16),
        label: const Text('绑定摄像头', style: TextStyle(fontSize: 12)),
      ),
      const SizedBox(width: 4),
      TextButton.icon(
        onPressed: () => showAddCameraDialog(context, ref),
        icon: const Icon(Icons.video_call, size: 16),
        label: const Text('添加摄像头', style: TextStyle(fontSize: 12)),
      ),
    ]),
  );
}

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
    final profile = ref.watch(printersProvider
        .select((l) => printerByIdOf(l.valueOrNull, profileId)));
    if (profile == null) return const SizedBox.shrink();
    final settings =
        ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
    final specs = buildCameraSpecs(ref, profile);
    final builtinOfferable = profile.mode == PrinterMode.lan &&
        !profile.builtinCamDefaultOn(settings.builtinCamDefault);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        cameraSectionHeader(context, ref, profile),
        if (specs.isEmpty && !builtinOfferable)
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
          if (builtinOfferable)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _OpenBuiltinTile(
                onOpen: () => setBuiltinCam(ref, profile, true),
              ),
            ),
          for (final spec in specs)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: VisibleOnlyTile(
                key: ValueKey(spec.id),
                streamId: spec.id,
                child: CameraTile(
                  streamUrl: spec.url,
                  label: spec.label,
                  cameraId: spec.id,
                  frameSlot: 'dash-wall',
                  onToggleQuality: spec.onToggleQuality,
                  flipH: spec.flipH,
                  rotationDeg: spec.rotationDeg,
                  ptzInvertPan: spec.ptzInvertPan,
                  ptzInvertTilt: spec.ptzInvertTilt,
                  onToggleFlip: spec.onToggleFlip,
                  onSetRotation: spec.onSetRotation,
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// Binding management: per-printer built-in camera tri-state (跟随全局 /
  /// 开启 / 关闭) plus multi-select binding of RTSP cameras (FR-4 多对多).
  /// Static - the camera wall's header uses it too.
  static Future<void> editBindings(
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
                          color:
                              DeckColors.textSecondary.withValues(alpha: 0.9))),
                ] else
                  for (final c in cameras)
                    if (c.sourceType == CameraSourceType.rtsp)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(c.id),
                        title:
                            Text(c.name, style: const TextStyle(fontSize: 13)),
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

    // Persist the tri-state and the RTSP bindings (the card switch reads
    // the same field, so both stay in sync).
    final printers = ref.read(printersProvider).valueOrNull ?? const [];
    await ref.read(printersProvider.notifier).replaceAll([
      for (final p in printers)
        p.id == profile.id ? p.copyWith(builtinCam: tri) : p,
    ]);
    for (final c
        in cameras.where((c) => c.sourceType == CameraSourceType.rtsp)) {
      final bound = c.printerIds.contains(profile.id);
      final want = selected.contains(c.id);
      if (bound == want) continue;
      await ref.read(camerasProvider.notifier).replace(c.copyWith(
            printerIds: want
                ? [...c.printerIds, profile.id]
                : c.printerIds.where((id) => id != profile.id).toList(),
          ));
    }
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

/// Camera wall for the compact monitoring pane (反馈 2026-10-20): the
/// printer's feeds arranged into the best-fitting grid for the available
/// space so everything fits one screen regardless of camera count.
/// Tapping a feed zooms it to fill the pane; the 缩小 button (or nothing
/// else - the wall is gone while zoomed) returns to the grid.
class CameraWallSection extends ConsumerStatefulWidget {
  const CameraWallSection({super.key, required this.profileId});

  final String profileId;

  @override
  ConsumerState<CameraWallSection> createState() => _CameraWallSectionState();
}

class _CameraWallSectionState extends ConsumerState<CameraWallSection> {
  /// Id of the zoomed feed; null shows the grid.
  String? _zoomedId;

  @override
  Widget build(BuildContext context) {
    final printers =
        ref.watch(printersProvider).valueOrNull ?? const <PrinterProfile>[];
    final matches = [
      for (final p in printers)
        if (p.id == widget.profileId) p,
    ];
    if (matches.isEmpty) return const SizedBox.shrink();
    // Final local so the promoted non-null type survives into the
    // closures below (LayoutBuilder builder, button callbacks).
    final profile = matches.first;
    final settings =
        ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
    final specs = buildCameraSpecs(ref, profile);
    final builtinOfferable = profile.mode == PrinterMode.lan &&
        !profile.builtinCamDefaultOn(settings.builtinCamDefault);

    CameraTileSpec? zoomed;
    if (_zoomedId != null) {
      for (final s in specs) {
        if (s.id == _zoomedId) zoomed = s;
      }
      if (zoomed == null) {
        // Zoom target vanished (unbound/disabled) - fall back to the wall.
        _zoomedId = null;
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (zoomed == null)
            cameraSectionHeader(context, ref, profile)
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Text(zoomed.label,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ]),
            ),
          Expanded(
            child: zoomed != null
                ? _zoomedView(zoomed)
                : LayoutBuilder(
                    builder: (context, box) =>
                        _wall(context, box, profile, specs, builtinOfferable)),
          ),
        ],
      ),
    );
  }

  /// Grid with the column count whose cell aspect lands closest to 16:9,
  /// so the wall always uses the whole pane however many cameras there
  /// are (反馈 2026-10-20 自动缩放).
  Widget _wall(BuildContext context, BoxConstraints box, PrinterProfile profile,
      List<CameraTileSpec> specs, bool builtinOfferable) {
    final cells = <Widget>[
      if (builtinOfferable)
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Container(
            color: Colors.black,
            alignment: Alignment.center,
            child: FilledButton.tonalIcon(
              onPressed: () => setBuiltinCam(ref, profile, true),
              icon: const Icon(Icons.videocam_outlined, size: 18),
              label: const Text('打开机内摄像头'),
            ),
          ),
        ),
      for (final spec in specs) _cell(spec),
    ];
    if (cells.isEmpty) {
      return Center(
        child: Text(
          '暂无画面 - 点右上角添加摄像头,或在绑定设置里开启机内摄像头',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12,
              color: DeckColors.textSecondary.withValues(alpha: 0.9)),
        ),
      );
    }

    final n = cells.length;
    final w = box.maxWidth > 0 ? box.maxWidth : 1.0;
    final h = box.maxHeight > 0 ? box.maxHeight : 1.0;
    var bestCols = 1;
    var bestErr = double.infinity;
    for (var cols = 1; cols <= n; cols++) {
      final r = (n / cols).ceil();
      final err = ((w / cols) / (h / r) / (16 / 9) - 1).abs();
      if (err < bestErr) {
        bestErr = err;
        bestCols = cols;
      }
    }
    final rows = (n / bestCols).ceil();

    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Expanded(
            child: Row(
              children: [
                for (var i = r * bestCols; i < (r + 1) * bestCols && i < n; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: cells[i],
                    ),
                  ),
                // Invisible spacers keep the last (partial) row's cells the
                // same width as the rows above.
                for (var i = n; i < (r + 1) * bestCols; i++)
                  const Expanded(child: SizedBox()),
              ],
            ),
          ),
      ],
    );
  }

  /// One wall cell: the feed filling the cell, tap to zoom.
  Widget _cell(CameraTileSpec spec) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _zoomedId = spec.id),
        child: Stack(fit: StackFit.expand, children: [
          VisibleOnlyTile(
            key: ValueKey(spec.id),
            streamId: spec.id,
            child: CameraTile(
              streamUrl: spec.url,
              label: spec.label,
              expand: true,
              cameraId: spec.id,
              frameSlot: 'dash-zoom',
              onToggleQuality: spec.onToggleQuality,
              flipH: spec.flipH,
              rotationDeg: spec.rotationDeg,
              ptzInvertPan: spec.ptzInvertPan,
              ptzInvertTilt: spec.ptzInvertTilt,
              onToggleFlip: spec.onToggleFlip,
              onSetRotation: spec.onSetRotation,
            ),
          ),
          Positioned(
            // Bottom-left: bottom-right is the PTZ pad's spot.
            left: 8,
            bottom: 8,
            child: Icon(Icons.open_in_full,
                size: 13, color: Colors.white.withValues(alpha: 0.75)),
          ),
        ]),
      ),
    );
  }

  /// Zoomed feed filling the pane, with a shrink button back to the wall.
  Widget _zoomedView(CameraTileSpec spec) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(fit: StackFit.expand, children: [
        VisibleOnlyTile(
          key: ValueKey(spec.id),
          streamId: spec.id,
          child: CameraTile(
            streamUrl: spec.url,
            label: spec.label,
            expand: true,
            cameraId: spec.id,
            frameSlot: 'dash-zoom2',
            onToggleQuality: spec.onToggleQuality,
            flipH: spec.flipH,
            rotationDeg: spec.rotationDeg,
            ptzInvertPan: spec.ptzInvertPan,
            ptzInvertTilt: spec.ptzInvertTilt,
            onToggleFlip: spec.onToggleFlip,
            onSetRotation: spec.onSetRotation,
          ),
        ),
        Positioned(
          // Bottom-left: top-right is the quality chip, bottom-right the
          // PTZ pad.
          left: 10,
          bottom: 10,
          child: IconButton.filledTonal(
            icon: const Icon(Icons.close_fullscreen, size: 18),
            tooltip: '缩小',
            onPressed: () => setState(() => _zoomedId = null),
          ),
        ),
      ]),
    );
  }
}
