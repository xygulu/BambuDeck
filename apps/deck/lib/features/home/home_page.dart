import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../cameras/cameras_page.dart';
import '../monitor/camera_monitor_page.dart';
import '../monitor/monitor_page.dart';
import '../settings/settings_page.dart';
import 'add_printer_sheet.dart';

/// Home shell: the monitoring deck with two freely switchable
/// perspectives - printer-primary and camera-primary (反馈 2026-10-20) -
/// plus the settings entry. IndexedStack keeps both alive; stream tiles
/// unmount when their page hides (VisibleOnlyTile).
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perspective = ref.watch(monitorPerspectiveProvider);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: const Text('BambuDeck',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          SegmentedButton<MonitorPerspective>(
            segments: const [
              ButtonSegment(
                value: MonitorPerspective.printers,
                icon: Icon(Icons.print, size: 15),
                label: Text('打印机', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: MonitorPerspective.cameras,
                icon: Icon(Icons.videocam, size: 15),
                label: Text('摄像头', style: TextStyle(fontSize: 12)),
              ),
            ],
            selected: {perspective},
            onSelectionChanged: (s) => ref
                .read(monitorPerspectiveProvider.notifier)
                .state = s.first,
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -2, vertical: -2),
              textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: IndexedStack(
        index: perspective.index,
        children: [
          MonitorPage(onAddPrinter: () => _openAddSheet(context)),
          CameraMonitorPage(
              onAddCamera: () => showAddCameraDialog(context, ref)),
        ],
      ),
    );
  }

  void _openAddSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: DeckColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => const AddPrinterSheet(),
    );
  }
}
