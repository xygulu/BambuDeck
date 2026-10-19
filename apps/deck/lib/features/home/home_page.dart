import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';
import '../dashboard/dashboard_page.dart';
import '../settings/settings_page.dart';
import 'add_printer_sheet.dart';

/// Home: printer grid. Tap a card for the full dashboard.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(printersProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: const Text('BambuDeck',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openAddSheet(context),
        icon: const Icon(Icons.add),
        label: const Text('添加打印机'),
      ),
      body: printers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
            child: Text('读取配置失败: $e',
                style: const TextStyle(color: DeckColors.error))),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(onAdd: () => _openAddSheet(context));
          }
          return LayoutBuilder(builder: (context, constraints) {
            final wide = constraints.maxWidth >= 760;
            final columns = wide
                ? (constraints.maxWidth ~/ 360).clamp(2, 4)
                : (constraints.maxWidth ~/ 340).clamp(1, 2);
            return GridView.count(
              padding: const EdgeInsets.all(16),
              crossAxisCount: columns,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              childAspectRatio: wide ? 1.7 : 1.55,
              children: [
                for (final p in list) _PrinterCard(profile: p),
              ],
            );
          });
        },
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.print_disabled, size: 56,
              color: DeckColors.textSecondary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          const Text('还没有打印机',
              style: TextStyle(
                  fontSize: 16, color: DeckColors.textSecondary)),
          const SizedBox(height: 6),
          const Text('局域网直连或 Bambu 云端均可添加',
              style: TextStyle(fontSize: 13, color: DeckColors.textSecondary)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('添加第一台打印机'),
          ),
        ],
      ),
    );
  }
}

class _PrinterCard extends ConsumerWidget {
  const _PrinterCard({required this.profile});
  final PrinterProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider(profile.id));
    final state = conn.state;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => DashboardPage(profileId: profile.id),
          ));
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        '${profile.modeLabel} · ${_connLabel(conn.status)}',
                        style: const TextStyle(
                            fontSize: 12, color: DeckColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (state != null)
                  StateBadge(state: state.gcodeState)
                else
                  _connDot(conn.status),
              ]),
              const Spacer(),
              Row(children: [
                SizedBox(
                  width: 64,
                  height: 64,
                  child: ProgressRing(
                    progress: state?.progress ?? 0,
                    color: state == null
                        ? DeckColors.idle
                        : stateColor(state.gcodeState),
                    size: 64,
                    stroke: 7,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        state?.subtaskName.isNotEmpty == true
                            ? state!.subtaskName
                            : '无任务',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: DeckColors.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state == null
                            ? '等待连接…'
                            : '喷嘴 ${state.nozzleTemp.round()}° · 热床 ${state.bedTemp.round()}° · 层 ${state.layerNum}/${state.totalLayers}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, color: DeckColors.textSecondary),
                      ),
                      if (state?.hasError == true) ...[
                        const SizedBox(height: 6),
                        const Text('⚠ 打印机错误',
                            style: TextStyle(
                                fontSize: 12, color: DeckColors.error)),
                      ],
                    ],
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  String _connLabel(BambuConnStatus s) => switch (s) {
        BambuConnStatus.connected => '已连接',
        BambuConnStatus.connecting => '连接中',
        BambuConnStatus.reconnecting => '重连中',
        BambuConnStatus.disconnected => '未连接',
        BambuConnStatus.error => '错误',
      };

  Widget _connDot(BambuConnStatus s) {
    final color = switch (s) {
      BambuConnStatus.connected => DeckColors.running,
      BambuConnStatus.connecting ||
      BambuConnStatus.reconnecting =>
        DeckColors.warning,
      _ => DeckColors.textSecondary,
    };
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
