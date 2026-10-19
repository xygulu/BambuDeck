import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/camera_profile.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../ui/camera_tile.dart';

/// Cameras tab body (PRD FR-3): live tile per camera, add via dialog.
class CamerasPage extends ConsumerWidget {
  const CamerasPage({super.key, required this.onAdd});

  /// Opens the add-camera dialog; owned by the shell so the FAB can
  /// trigger it too.
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cameras = ref.watch(camerasProvider);
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];

    return cameras.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Text('读取摄像头配置失败: $e',
              style: const TextStyle(color: DeckColors.error))),
      data: (list) {
        if (list.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.videocam_off_outlined,
                  size: 56,
                  color: DeckColors.textSecondary.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              const Text('还没有摄像头',
                  style: TextStyle(
                      fontSize: 16, color: DeckColors.textSecondary)),
              const SizedBox(height: 6),
              const Text('RTSP/ONVIF 网络摄像头,或打印机自带摄像头(X1/P1 系)',
                  style: TextStyle(
                      fontSize: 13, color: DeckColors.textSecondary)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('添加摄像头'),
              ),
            ]),
          );
        }
        return LayoutBuilder(builder: (context, constraints) {
          final columns = (constraints.maxWidth ~/ 420).clamp(1, 3);
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 16 / 12,
            children: [
              for (final c in list)
                _CameraCard(
                    camera: c,
                    printers: printers,
                    onDelete: () =>
                        ref.read(camerasProvider.notifier).remove(c.id)),
            ],
          );
        });
      },
    );
  }
}

class _CameraCard extends ConsumerWidget {
  const _CameraCard({
    required this.camera,
    required this.printers,
    required this.onDelete,
  });

  final CameraProfile camera;
  final List<PrinterProfile> printers;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    PrinterProfile? linked;
    for (final p in printers) {
      if (p.id == camera.printerId) linked = p;
    }
    final url = camera.resolveUrl(linked);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: url != null && camera.enabled
              ? CameraTile(streamUrl: url, label: camera.name)
              : Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: Text(
                    camera.enabled ? '未配置视频源' : '已停用',
                    style: const TextStyle(
                        fontSize: 13, color: DeckColors.textSecondary),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(camera.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(
                      '${camera.sourceType.label}'
                      '${linked == null ? '' : ' · ${linked.name}'}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: DeckColors.textSecondary),
                    ),
                  ]),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除摄像头',
              onPressed: onDelete,
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Add-camera dialog: RTSP/ONVIF URL, or the printer's own camera
/// (X1/P1 family; A1 系没有摄像头硬件).
Future<void> showAddCameraDialog(BuildContext context, WidgetRef ref) async {
  final nameCtrl = TextEditingController();
  final urlCtrl = TextEditingController();
  var type = CameraSourceType.rtsp;
  PrinterProfile? linked;

  final printers = ref.read(printersProvider).valueOrNull ?? const [];
  final lanPrinters =
      printers.where((p) => p.mode == PrinterMode.lan).toList();

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: const Text('添加摄像头'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: '名称', hintText: '例如 打印房门口'),
            ),
            const SizedBox(height: 12),
            SegmentedButton<CameraSourceType>(
              segments: const [
                ButtonSegment(
                    value: CameraSourceType.rtsp,
                    label: Text('RTSP/ONVIF')),
                ButtonSegment(
                    value: CameraSourceType.bambu,
                    label: Text('打印机自带')),
              ],
              selected: {type},
              onSelectionChanged: (s) => setState(() => type = s.first),
            ),
            const SizedBox(height: 12),
            if (type == CameraSourceType.rtsp) ...[
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'RTSP 地址',
                  hintText: 'rtsp://user:pass@192.168.1.10:554/stream1',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<PrinterProfile>(
                initialValue: linked,
                decoration: const InputDecoration(
                    labelText: '关联打印机(可选,显示在其仪表盘)'),
                items: [
                  for (final p in printers)
                    DropdownMenuItem(value: p, child: Text(p.name)),
                ],
                onChanged: (p) => setState(() => linked = p),
              ),
            ] else ...[
              DropdownButtonFormField<PrinterProfile>(
                initialValue: linked,
                decoration: const InputDecoration(
                    labelText: '选择打印机(局域网直连)'),
                items: [
                  for (final p in lanPrinters)
                    DropdownMenuItem(value: p, child: Text(p.name)),
                ],
                onChanged: (p) => setState(() => linked = p),
              ),
              const SizedBox(height: 10),
              Text(
                '打印机自带摄像头走 RTSP(bblp 账号 + 访问码自动填入)。'
                '注意:X1 / P1 系才有摄像头,A1 / A1 mini 没有摄像头硬件。',
                style: TextStyle(
                    fontSize: 12,
                    color: DeckColors.textSecondary.withValues(alpha: 0.9)),
              ),
            ],
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加')),
        ],
      ),
    ),
  );
  if (ok != true) return;

  final name = nameCtrl.text.trim().isEmpty
      ? (type == CameraSourceType.bambu
          ? (linked?.name ?? '打印机摄像头')
          : '摄像头')
      : nameCtrl.text.trim();
  final camera = CameraProfile(
    id: 'c_${DateTime.now().millisecondsSinceEpoch}',
    name: name,
    sourceType: type,
    url: type == CameraSourceType.rtsp ? urlCtrl.text.trim() : '',
    printerId: linked?.id ?? '',
  );
  await ref.read(camerasProvider.notifier).add(camera);
}
