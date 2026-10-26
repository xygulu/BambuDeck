import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_settings.dart';
import '../../data/list_sort.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../data/settings_providers.dart';
import '../../ui/widgets.dart';
import '../dashboard/dashboard_page.dart';
import '../printers/edit_printer_dialog.dart';

/// Which primary view the monitoring shell shows.
enum MonitorPerspective { printers, cameras }

/// Shell-level perspective switch (打印机视角 / 摄像头视角).
final monitorPerspectiveProvider =
    StateProvider<MonitorPerspective>((_) => MonitorPerspective.printers);

/// Selected printer on the printer perspective. Shared so the camera
/// perspective's bound-printer cards can jump straight here.
final monitorSelectedPrinterProvider = StateProvider<String?>((_) => null);

/// Single monitoring screen (FR-1, 优化需求 1): printer cards down the
/// left, the selected printer's cameras + dashboard + controls on the
/// right. Narrow windows fall back to the card grid with a pushed
/// [DashboardPage], where the same content fits one column.
class MonitorPage extends ConsumerStatefulWidget {
  const MonitorPage({super.key, required this.onAddPrinter});

  /// Opens the add-printer sheet; owned by the home shell.
  final VoidCallback onAddPrinter;

  @override
  ConsumerState<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends ConsumerState<MonitorPage> {
  static const _listWidth = 330.0;
  static const _paneMinWidth = 900.0;

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printersProvider);
    final rawSelected = ref.watch(monitorSelectedPrinterProvider);

    return printers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Text('读取配置失败: $e',
              style: const TextStyle(color: DeckColors.error))),
      data: (list) {
        if (list.isEmpty) {
          return _EmptyState(onAdd: widget.onAddPrinter);
        }
        // 列表排序 (2026-10-27): manual = 存储顺序 (可拖动), 其余是排序视图。
        final settings =
            ref.watch(appSettingsProvider).valueOrNull ?? const AppSettings();
        final sorted = sortPrinters(list, settings.printerSortMode);
        // Selection heals itself: a deleted printer falls back to the
        // first one so the right pane never goes blank on purpose.
        final selectedId =
            rawSelected != null && list.any((p) => p.id == rawSelected)
                ? rawSelected
                : sorted.first.id;
        return LayoutBuilder(builder: (context, constraints) {
          final wide = constraints.maxWidth >= _paneMinWidth;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: _listWidth,
                  child: _PrinterList(
                    printers: sorted,
                    sortMode: settings.printerSortMode,
                    selectedId: selectedId,
                    onAdd: widget.onAddPrinter,
                    onSelect: (id) => ref
                        .read(monitorSelectedPrinterProvider.notifier)
                        .state = id,
                  ),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: _PrinterPane(profileId: selectedId),
                ),
              ],
            );
          }
          // Narrow: grid + push route, like before the merge.
          final columns = (constraints.maxWidth ~/ 340).clamp(1, 2);
          return GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: columns,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            // 卡片现在带完整状态详情 (2026-10-21), 放宽到更高的瓦片。
            childAspectRatio: 1.15,
            children: [
              for (final p in sorted)
                MonitorPrinterCard(
                  profile: p,
                  selected: p.id == selectedId,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DashboardPage(profileId: p.id),
                  )),
                ),
            ],
          );
        });
      },
    );
  }
}

/// Left rail: slim glance card per printer (name + badge + task line +
/// progress). Controls live in the right pane: 暂停/恢复/停止 in the status
/// card, 机内画面开关 on the camera section header.
class _PrinterList extends ConsumerWidget {
  const _PrinterList({
    required this.printers,
    required this.sortMode,
    required this.selectedId,
    required this.onAdd,
    required this.onSelect,
  });

  final List<PrinterProfile> printers;
  final ListSortMode sortMode;
  final String selectedId;
  final VoidCallback onAdd;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
          child: Row(children: [
            Text('打印机 (${printers.length})',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            const Spacer(),
            // 排序方式 (列表排序 2026-10-27): 手动模式下卡片带拖动手柄。
            PopupMenuButton<ListSortMode>(
              tooltip: '排序方式',
              icon: const Icon(Icons.sort, size: 20),
              onSelected: (m) {
                final cur = ref.read(appSettingsProvider).valueOrNull ??
                    const AppSettings();
                ref.read(appSettingsProvider.notifier).set(
                      cur.copyWith(printerSortMode: m),
                    );
              },
              itemBuilder: (_) => [
                for (final m in ListSortMode.values)
                  CheckedPopupMenuItem(
                    value: m,
                    checked: m == sortMode,
                    child: Text(m.label),
                  ),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 20),
              tooltip: '添加打印机',
              onPressed: onAdd,
            ),
          ]),
        ),
        Expanded(
          child: sortMode == ListSortMode.manual
              ? ReorderableListView(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  buildDefaultDragHandles: false,
                  onReorderItem: (oldI, newI) => _reorder(ref, oldI, newI),
                  children: [
                    for (var i = 0; i < printers.length; i++)
                      _dragRow(context, i, printers[i],
                          key: ValueKey(printers[i].id)),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                  children: [
                    for (final p in printers)
                      MonitorPrinterCard(
                        profile: p,
                        selected: p.id == selectedId,
                        onTap: () => onSelect(p.id),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 手动模式的一行: 拖动手柄 + 状态卡 (拖动手柄排序, 点卡片选择)。
  Widget _dragRow(BuildContext context, int i, PrinterProfile p,
          {required Key key}) =>
      Row(key: key, children: [
        ReorderableDragStartListener(
          index: i,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 14),
            child: Icon(Icons.drag_indicator,
                size: 16, color: DeckColors.textSecondary),
          ),
        ),
        Expanded(
          child: MonitorPrinterCard(
            profile: p,
            selected: p.id == selectedId,
            onTap: () => onSelect(p.id),
          ),
        ),
      ]);

  /// 拖动落点写入存储顺序并持久化 (顺序即手动排序结果;
  /// onReorderItem 已修正移除元素后的落点下标, 直接插入即可)。
  void _reorder(WidgetRef ref, int oldI, int newI) {
    final items = [...printers];
    final moved = items.removeAt(oldI);
    items.insert(newI, moved);
    ref.read(printersProvider.notifier).replaceAll(items);
  }
}

/// Right pane: selected printer's name + delete, then the compact
/// dashboard body - slim status bar up top, cameras get the space below
/// (优化需求 3).
class _PrinterPane extends ConsumerWidget {
  const _PrinterPane({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(printersProvider
        .select((l) => printerByIdOf(l.valueOrNull, profileId)));
    if (profile == null) {
      return const Center(child: Text('打印机不存在'));
    }
    final conn = ref.watch(connectionProvider(profileId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
          child: Row(children: [
            Text(profile.name,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const Spacer(),
            // 网络信息右对齐跟在名称行, 不再单独占监控信息区 (反馈 2026-10-20).
            if (conn.state != null) ...[
              NetworkInfoText(s: conn.state!),
              const SizedBox(width: 10),
            ],
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 19),
              tooltip: '编辑打印机',
              // 删除入口收进编辑对话框 (2026-10-21: 显眼位置易误触)。
              onPressed: () => showEditPrinterDialog(context, ref, profile),
            ),
          ]),
        ),
        Expanded(
          child: DashboardBody(
            profileId: profileId,
            conn: conn,
            state: conn.state,
            compact: true,
          ),
        ),
      ],
    );
  }
}

/// The printer card shared by the left rail and the narrow-window grid.
/// 完整状态卡 (反馈 2026-10-21: 状态信息从右侧监控区迁到这里): 名称 +
/// 状态徽章 + 任务/进度 + 温度/层高/剩余 + 舱门/报错; 控制按钮仍在右侧。
class MonitorPrinterCard extends ConsumerWidget {
  const MonitorPrinterCard({
    super.key,
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final PrinterProfile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider(profile.id));
    final state = conn.state;

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
              if (state != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text(
                      state.subtaskName.isNotEmpty
                          ? state.subtaskName
                          : '无任务',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${state.progress}%',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: stateColor(state.gcodeState))),
                ]),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: state.progress / 100,
                    minHeight: 3,
                    color: stateColor(state.gcodeState),
                    backgroundColor: DeckColors.border.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 6),
                Text(_tempsLine(state),
                    style: const TextStyle(
                        fontSize: 11, color: DeckColors.textSecondary)),
                if (state.stageLabel(zh: true) != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      const Icon(Icons.timelapse,
                          size: 11, color: DeckColors.running),
                      const SizedBox(width: 4),
                      Text('步骤 ${state.stageLabel(zh: true)}',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: DeckColors.running)),
                    ]),
                  ),
                if (state.printing)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                        '层 ${state.layerNum}/${state.totalLayers} · '
                        '剩 ${fmtRemaining(state.remainingMinutes)}',
                        style: const TextStyle(
                            fontSize: 11, color: DeckColors.textSecondary)),
                  ),
                if (state.doorOpen == true)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('舱门已开',
                        style: TextStyle(
                            fontSize: 11, color: DeckColors.warning)),
                  ),
                if (state.hasError)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    // 报错芯片 = 弹窗入口, 与原状态卡一致 (2026-10-21 迁移)。
                    child: InkWell(
                      onTap: () => showHmsDialog(context, state),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: DeckColors.error.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color:
                                  DeckColors.error.withValues(alpha: 0.5)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.error_outline,
                              size: 12, color: DeckColors.error),
                          const SizedBox(width: 4),
                          Text(
                              state.hms.length > 1
                                  ? '报错 ${state.hms.length}'
                                  : '报错',
                              style: const TextStyle(
                                  color: DeckColors.error, fontSize: 11)),
                        ]),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 喷嘴/热床(带目标温度)/腔体 一行串起来。
  String _tempsLine(BambuState s) {
    String t(double v, double? target) => target != null && target > 0
        ? '${v.round()}°/${target.round()}°'
        : '${v.round()}°';
    return [
      '喷嘴 ${t(s.nozzleTemp, s.nozzleTarget)}',
      '热床 ${t(s.bedTemp, s.bedTarget)}',
      if (s.chamberTemp > 0) '腔体 ${s.chamberTemp.round()}°',
    ].join(' · ');
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
