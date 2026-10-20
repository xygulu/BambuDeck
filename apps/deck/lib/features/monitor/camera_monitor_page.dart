import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/rtsp_quality.dart';
import '../../ui/camera_tile.dart';
import '../../ui/visible_tile.dart';
import 'monitor_page.dart';

/// Selected camera on the camera perspective.
final monitorSelectedCameraProvider = StateProvider<String?>((_) => null);

/// Camera-primary monitoring (摄像头视角): camera list on the left, the
/// selected camera's live feed and its bound printers' status cards on
/// the right. Mirrors [MonitorPage]; the shell's perspective toggle flips
/// between the two, and this view also surfaces every configured camera -
/// bound or not - so none of them can go missing.
class CameraMonitorPage extends ConsumerStatefulWidget {
  const CameraMonitorPage({super.key, required this.onAddCamera});

  /// Opens the add-camera dialog; owned by the home shell.
  final VoidCallback onAddCamera;

  @override
  ConsumerState<CameraMonitorPage> createState() =>
      _CameraMonitorPageState();
}

class _CameraMonitorPageState extends ConsumerState<CameraMonitorPage> {
  static const _listWidth = 330.0;
  static const _paneMinWidth = 900.0;

  @override
  Widget build(BuildContext context) {
    final cameras = ref.watch(camerasProvider);

    return cameras.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Text('读取摄像头配置失败: $e',
              style: const TextStyle(color: DeckColors.error))),
      data: (list) {
        if (list.isEmpty) {
          return _EmptyState(onAdd: widget.onAddCamera);
        }
        final raw = ref.watch(monitorSelectedCameraProvider);
        final selectedId =
            raw != null && list.any((c) => c.id == raw) ? raw : list.first.id;
        return LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth >= _paneMinWidth) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _listWidth,
                  child: _CameraList(
                    cameras: list,
                    selectedId: selectedId,
                    onAdd: widget.onAddCamera,
                    onSelect: (id) => ref
                        .read(monitorSelectedCameraProvider.notifier)
                        .state = id,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _CameraPane(cameraId: selectedId)),
              ],
            );
          }
          // Narrow: live grid, binding per card.
          final columns = (constraints.maxWidth ~/ 420).clamp(1, 2);
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 16 / 11.5,
            children: [
              for (final c in list) _CameraGridCard(camera: c),
            ],
          );
        });
      },
    );
  }
}

/// Left rail: one card per configured camera - the full list, bound or
/// not, so previously added cameras are always findable here.
class _CameraList extends ConsumerWidget {
  const _CameraList({
    required this.cameras,
    required this.selectedId,
    required this.onAdd,
    required this.onSelect,
  });

  final List<CameraProfile> cameras;
  final String selectedId;
  final VoidCallback onAdd;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Row(children: [
            Text('摄像头 (${cameras.length})',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: '添加摄像头',
              onPressed: onAdd,
            ),
          ]),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            children: [
              for (final c in cameras)
                _CameraListCard(
                  camera: c,
                  printers: printers,
                  selected: c.id == selectedId,
                  onTap: () => onSelect(c.id),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CameraListCard extends StatelessWidget {
  const _CameraListCard({
    required this.camera,
    required this.printers,
    required this.selected,
    required this.onTap,
  });

  final CameraProfile camera;
  final List<PrinterProfile> printers;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = camera;
    final boundNames = [
      for (final p in printers)
        if (c.printerIds.contains(p.id)) p.name,
    ];
    final subtitle = [
      c.sourceType.label,
      if (c.sourceType == CameraSourceType.rtsp &&
          rtspQualitySwappable(c.url))
        c.quality == RtspQuality.main ? '主码流' : '子码流',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: selected
            ? BorderSide(color: DeckColors.running.withValues(alpha: 0.7))
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Expanded(
                  child: Text(c.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Icon(
                  c.sourceType == CameraSourceType.bambu
                      ? Icons.print
                      : Icons.videocam,
                  size: 16,
                  color: c.enabled
                      ? DeckColors.textSecondary
                      : DeckColors.textSecondary.withValues(alpha: 0.5),
                ),
                if (!c.enabled) ...[
                  const SizedBox(width: 6),
                  const Text('已停用',
                      style: TextStyle(
                          fontSize: 11, color: DeckColors.textSecondary)),
                ],
              ]),
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: DeckColors.textSecondary)),
              const SizedBox(height: 4),
              Text(
                boundNames.isEmpty ? '未绑定打印机' : '绑定: ${boundNames.join('、')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11, color: DeckColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Right pane: selected camera's live feed first, bound printers' status
/// cards below; tapping a card jumps to the printer perspective.
class _CameraPane extends ConsumerWidget {
  const _CameraPane({required this.cameraId});

  final String cameraId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameras = ref.watch(camerasProvider).valueOrNull ?? const [];
    CameraProfile? camera;
    for (final c in cameras) {
      if (c.id == cameraId) camera = c;
    }
    if (camera == null) return const Center(child: Text('摄像头不存在'));
    final c = camera;
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];
    final bound = [
      for (final p in printers)
        if (c.printerIds.contains(p.id)) p,
    ];
    PrinterProfile? linked;
    if (c.sourceType == CameraSourceType.bambu) {
      // Built-in cameras bind exactly one printer.
      for (final p in printers) {
        if (c.printerIds.contains(p.id)) linked = p;
      }
    }
    final url = c.resolveUrl(linked);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
          child: Row(children: [
            Text(c.name,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => bindPrintersDialog(context, ref, c),
              icon: const Icon(Icons.tune, size: 16),
              label:
                  const Text('绑定打印机', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除摄像头',
              onPressed: () => _confirmRemove(context, ref, c),
            ),
          ]),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              c.enabled && url != null && url.isNotEmpty
                  ? VisibleOnlyTile(
                      key: ValueKey(c.id),
                      streamId: c.id,
                      child: CameraTile(
                        streamUrl: url,
                        showLabel: false,
                        onToggleQuality: qualityToggler(ref, c),
                      ),
                    )
                  : _unavailableBox(c, url),
              const Padding(
                padding: EdgeInsets.only(top: 14, bottom: 6),
                child: Text('绑定的打印机',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              for (final p in bound)
                MonitorPrinterCard(
                  profile: p,
                  selected: false,
                  onTap: () {
                    ref
                        .read(monitorSelectedPrinterProvider.notifier)
                        .state = p.id;
                    ref
                        .read(monitorPerspectiveProvider.notifier)
                        .state = MonitorPerspective.printers;
                  },
                ),
              if (bound.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '未绑定打印机 - 点右上「绑定打印机」选择要一起监控的打印机',
                    style: TextStyle(
                        fontSize: 12, color: DeckColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unavailableBox(CameraProfile c, String? url) => ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Container(
          color: Colors.black,
          height: 180,
          alignment: Alignment.center,
          child: Text(
            !c.enabled
                ? '已停用'
                : url == null
                    ? '未配置视频源(机内摄像头需要局域网直连打印机)'
                    : '视频源地址为空',
            style: const TextStyle(
                fontSize: 13, color: DeckColors.textSecondary),
          ),
        ),
      );

  void _confirmRemove(BuildContext context, WidgetRef ref, CameraProfile c) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: const Text('删除摄像头'),
        content: Text('确定删除「${c.name}」吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DeckColors.error),
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(camerasProvider.notifier).remove(c.id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// Multi-select binding of printers to one camera (many-to-many, FR-4).
Future<void> bindPrintersDialog(
    BuildContext context, WidgetRef ref, CameraProfile camera) async {
  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  final selected = {for (final id in camera.printerIds) id};

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: Text('绑定打印机 · ${camera.name}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (printers.isEmpty)
                const Text('还没有打印机',
                    style: TextStyle(
                        fontSize: 12, color: DeckColors.textSecondary))
              else
                for (final p in printers)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(p.id),
                    title: Text('${p.name}(${p.modeLabel})',
                        style: const TextStyle(fontSize: 13)),
                    onChanged: (v) => setState(() {
                      v == true
                          ? selected.add(p.id)
                          : selected.remove(p.id);
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
  // Printer-list order, stale ids dropped.
  await ref.read(camerasProvider.notifier).replace(camera.copyWith(
        printerIds: [
          for (final p in printers)
            if (selected.contains(p.id)) p.id,
        ],
      ));
}

/// Narrow-window grid card: live tile + name row with bind/delete.
class _CameraGridCard extends ConsumerWidget {
  const _CameraGridCard({required this.camera});

  final CameraProfile camera;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = camera;
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];
    PrinterProfile? linked;
    if (c.sourceType == CameraSourceType.bambu) {
      for (final p in printers) {
        if (c.printerIds.contains(p.id)) linked = p;
      }
    }
    final url = c.resolveUrl(linked);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: c.enabled && url != null && url.isNotEmpty
                ? VisibleOnlyTile(
                    key: ValueKey(c.id),
                    streamId: c.id,
                    child: CameraTile(
                      streamUrl: url,
                      showLabel: true,
                      onToggleQuality: qualityToggler(ref, c),
                    ),
                  )
                : Container(
                    color: Colors.black,
                    alignment: Alignment.center,
                    child: Text(
                      !c.enabled
                          ? '已停用'
                          : '未配置视频源',
                      style: const TextStyle(
                          fontSize: 13, color: DeckColors.textSecondary),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(
                        c.sourceType.label,
                        style: const TextStyle(
                            fontSize: 12,
                            color: DeckColors.textSecondary),
                      ),
                    ]),
              ),
              IconButton(
                icon: const Icon(Icons.tune, size: 18),
                tooltip: '绑定打印机',
                onPressed: () => bindPrintersDialog(context, ref, c),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: '删除摄像头',
                onPressed: () =>
                    ref.read(camerasProvider.notifier).remove(c.id),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_outlined,
              size: 56,
              color: DeckColors.textSecondary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          const Text('还没有摄像头',
              style: TextStyle(
                  fontSize: 16, color: DeckColors.textSecondary)),
          const SizedBox(height: 6),
          const Text('RTSP/ONVIF 网络摄像头,或打印机自带摄像头',
              style: TextStyle(fontSize: 13, color: DeckColors.textSecondary)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('添加摄像头'),
          ),
        ],
      ),
    );
  }
}
