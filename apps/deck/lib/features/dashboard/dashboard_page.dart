import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';
import 'printer_camera_section.dart';

/// Full monitoring dashboard for one printer: progress ring, temperatures,
/// fans, AMS strip, HMS errors and control bar (PRD FR-1 / FR-2 / FR-4).
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(printersProvider.notifier).byId(profileId);
    final conn = ref.watch(connectionProvider(profileId));
    final state = conn.state;

    if (profile == null) {
      return const Scaffold(body: Center(child: Text('打印机不存在')));
    }

    return Scaffold(
      backgroundColor: DeckColors.bg,
      appBar: AppBar(
        backgroundColor: DeckColors.bg,
        title: Text(profile.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除打印机',
            onPressed: () => _confirmRemove(context, ref, profile.name),
          ),
        ],
      ),
      body: DashboardBody(profileId: profileId, conn: conn, state: state),
    );
  }

  void _confirmRemove(BuildContext context, WidgetRef ref, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DeckColors.surface,
        title: const Text('删除打印机'),
        content: Text('确定删除「$name」吗?凭据将同时清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DeckColors.error),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(); // back to home
              ref.read(printersProvider.notifier).remove(profileId);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// One printer's dashboard content, without the Scaffold/route shell
/// (PRD FR-1 / FR-2 / FR-4). Two layouts:
///
/// - `compact: false` (default, narrow pushed route): big progress ring,
///   temperature card and control bar.
/// - `compact: true` (monitoring screen's right pane, 优化需求 3): a slim
///   status bar pinned at the top, the camera section taking the rest of
///   the space, AMS/HMS/device info collapsed into a bottom tile.
class DashboardBody extends ConsumerWidget {
  const DashboardBody({
    super.key,
    required this.profileId,
    required this.conn,
    required this.state,
    this.compact = false,
  });

  final String profileId;
  final PrinterConnection conn;
  final BambuState? state;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              switch (conn.status) {
                BambuConnStatus.connected => '已连接,等待状态推送…',
                BambuConnStatus.connecting => '正在连接打印机…',
                BambuConnStatus.reconnecting => '连接断开,正在重连…',
                _ => '未连接',
              },
              style: const TextStyle(color: DeckColors.textSecondary),
            ),
          ],
        ),
      );
    }

    final s = state!;
    final accent = stateColor(s.gcodeState);

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CompactStatusBar(
              profileId: profileId, s: s, accent: accent, live: conn.live),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                PrinterCameraSection(profileId: profileId),
                _ExtrasTile(s: s),
              ],
            ),
          ),
        ],
      );
    }

    final wide = MediaQuery.of(context).size.width >= 860;

    final left = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrinterCameraSection(profileId: profileId),
        _HeaderCard(s: s, accent: accent),
        const SizedBox(height: 14),
        _TempCard(s: s),
        const SizedBox(height: 14),
        _ControlBar(profileId: profileId, s: s, enabled: conn.live),
      ],
    );

    final right = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmsCard(s: s),
        const SizedBox(height: 14),
        HmsCard(state: s),
        const SizedBox(height: 14),
        DeviceCard(s: s),
      ],
    );

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(connectionProvider(profileId).notifier).refresh();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: left),
                const SizedBox(width: 14),
                Expanded(child: right),
              ],
            )
          else ...[
            left,
            const SizedBox(height: 14),
            right,
          ],
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.s, required this.accent});
  final BambuState s;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final stage = s.stageLabel(zh: true);
    final sublabel = switch (s.gcodeState) {
      GcodeState.running when stage != null => stage,
      GcodeState.running => '剩余 ${fmtRemaining(s.remainingMinutes)}',
      GcodeState.pause => '等待恢复',
      GcodeState.finish => '已完成',
      _ => null,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            Row(children: [
              StateBadge(state: s.gcodeState),
              const Spacer(),
              if (s.doorOpen == true)
                const _DoorChip(),
            ]),
            const SizedBox(height: 16),
            ProgressRing(
              progress: s.progress,
              color: accent,
              size: 190,
              stroke: 15,
              sublabel: sublabel,
            ),
            const SizedBox(height: 16),
            Text(
              s.subtaskName.isNotEmpty ? s.subtaskName : '无任务',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              s.printing
                  ? '层 ${s.layerNum}/${s.totalLayers} · 预计 ${fmtFinishTime(DateTime.now(), s.remainingMinutes)} 完成'
                  : '上次任务: ${s.subtaskName.isEmpty ? '-' : s.subtaskName}',
              style: const TextStyle(
                  fontSize: 13, color: DeckColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoorChip extends StatelessWidget {
  const _DoorChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: DeckColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DeckColors.warning.withValues(alpha: 0.5)),
      ),
      child: const Text('舱门已开',
          style: TextStyle(color: DeckColors.warning, fontSize: 12)),
    );
  }
}

class _TempCard extends StatelessWidget {
  const _TempCard({required this.s});
  final BambuState s;

  @override
  Widget build(BuildContext context) {
    final chips = <StatChip>[
      StatChip(
        label: s.nozzles.isNotEmpty ? '喷嘴 R' : '喷嘴',
        value: fmtTemp(s.nozzleTemp, s.nozzleTarget),
        color: DeckColors.nozzle,
      ),
      if (s.nozzles.length > 1)
        StatChip(
          label: '喷嘴 L',
          value: fmtTemp(s.nozzles[1].tempC, s.nozzles[1].targetC),
          color: DeckColors.nozzle,
        ),
      StatChip(
          label: '热床', value: fmtTemp(s.bedTemp, s.bedTarget), color: DeckColors.bed),
      if (s.chamberTemp > 0)
        StatChip(
            label: '腔体', value: fmtTemp(s.chamberTemp), color: DeckColors.chamber),
      StatChip(
          label: '散热风扇', value: '${s.fans.cooling}%', color: DeckColors.running),
      StatChip(
          label: '辅助风扇', value: '${s.fans.aux}%', color: DeckColors.prepare),
      StatChip(
          label: '腔体风扇', value: '${s.fans.chamber}%', color: DeckColors.chamber),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: chips,
        ),
      ),
    );
  }
}

/// AMS filament strip (also embedded in the compact pane's details tile).
class AmsCard extends StatelessWidget {
  const AmsCard({super.key, required this.s});
  final BambuState s;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AMS 耗材',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            if (s.ams != null)
              AmsStrip(ams: s.ams!)
            else
              const Text('未检测到 AMS',
                  style: TextStyle(
                      fontSize: 13, color: DeckColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// Device facts strip (WiFi / IP / speed / chamber light).
class DeviceCard extends StatelessWidget {
  const DeviceCard({super.key, required this.s});
  final BambuState s;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Wrap(
          spacing: 18,
          runSpacing: 8,
          children: [
            _kv('WiFi', s.wifiSignal != null ? '${s.wifiSignal} dBm' : '-'),
            _kv('IP', s.localIp.isEmpty ? '-' : s.localIp),
            _kv('速度',
                s.speedLevel > 0 ? _speedLabel(s.speedLevel) : '-'),
            _kv('腔灯',
                s.lightState < 0 ? '-' : (s.lightState == 1 ? '开' : '关')),
          ],
        ),
      ),
    );
  }

  String _speedLabel(int l) => switch (l) {
        1 => '静音',
        2 => '标准',
        3 => '运动',
        4 => '疯狂',
        _ => '$l',
      };

  Widget _kv(String k, String v) => RichText(
        text: TextSpan(children: [
          TextSpan(
              text: '$k  ',
              style: const TextStyle(
                  fontSize: 12, color: DeckColors.textSecondary)),
          TextSpan(
              text: v,
              style: const TextStyle(
                  fontSize: 13,
                  color: DeckColors.textPrimary,
                  fontWeight: FontWeight.w500)),
        ]),
      );
}

class _ControlBar extends ConsumerWidget {
  const _ControlBar({
    required this.profileId,
    required this.s,
    required this.enabled,
  });
  final String profileId;
  final BambuState s;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(connectionProvider(profileId).notifier);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('控制',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: enabled
                      ? () async {
                          await notifier.pause();
                        }
                      : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: enabled
                      ? () async {
                          await notifier.resume();
                        }
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('恢复'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: DeckColors.error),
                  onPressed: enabled
                      ? () => confirmStopPrint(context, notifier)
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('速度', style: TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('静音')),
                    ButtonSegment(value: 2, label: Text('标准')),
                    ButtonSegment(value: 3, label: Text('运动')),
                    ButtonSegment(value: 4, label: Text('疯狂')),
                  ],
                  selected: {s.speedLevel > 0 ? s.speedLevel : 2},
                  onSelectionChanged: enabled
                      ? (sel) => notifier.setSpeed(sel.first)
                      : null,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('腔灯', style: TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
              const Spacer(),
              Switch(
                value: s.lightState == 1,
                onChanged: enabled ? (v) => notifier.setLight(v) : null,
              ),
            ]),
          ],
        ),
      ),
    );
  }

}

/// Shared stop confirmation (control bar + compact status bar).
void confirmStopPrint(BuildContext context, ConnectionNotifier notifier) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('停止打印?'),
      content: const Text('将终止当前打印任务,已打印部分无法恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: DeckColors.error),
          onPressed: () {
            Navigator.of(ctx).pop();
            notifier.stop();
          },
          child: const Text('确认停止'),
        ),
      ],
    ),
  );
}

/// Slim status + control bar for the compact pane (优化需求 3): two dense
/// rows pinned at the top of the right pane, leaving the pane's height
/// to the camera section below.
class _CompactStatusBar extends ConsumerWidget {
  const _CompactStatusBar({
    required this.profileId,
    required this.s,
    required this.accent,
    required this.live,
  });

  final String profileId;
  final BambuState s;
  final Color accent;
  final bool live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(connectionProvider(profileId).notifier);
    final canPause = live && s.gcodeState == GcodeState.running;
    final canResume = live && s.gcodeState == GcodeState.pause;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              StateBadge(state: s.gcodeState),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.subtaskName.isNotEmpty ? s.subtaskName : '无任务',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              if (s.doorOpen == true) ...[
                const SizedBox(width: 8),
                const _DoorChip(),
              ],
              const SizedBox(width: 8),
              Text('${s.progress}%',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: s.progress / 100,
                minHeight: 3,
                color: accent,
                backgroundColor: accent.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _temp('喷嘴', s.nozzleTemp, s.nozzleTarget),
                _temp('热床', s.bedTemp, s.bedTarget),
                if (s.chamberTemp > 0) _temp('腔体', s.chamberTemp, null),
                if (s.printing)
                  Text('层 ${s.layerNum}/${s.totalLayers} · 剩 ${fmtRemaining(s.remainingMinutes)}',
                      style: const TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (canPause || canResume)
                  FilledButton.tonalIcon(
                    onPressed: () async =>
                        canPause ? notifier.pause() : notifier.resume(),
                    icon: Icon(canPause ? Icons.pause : Icons.play_arrow,
                        size: 16),
                    label: Text(canPause ? '暂停' : '恢复',
                        style: const TextStyle(fontSize: 12)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                IconButton.filledTonal(
                  tooltip: '停止',
                  icon: const Icon(Icons.stop, size: 18),
                  style: IconButton.styleFrom(
                    backgroundColor: DeckColors.error.withValues(alpha: 0.15),
                    foregroundColor: DeckColors.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed:
                      live ? () => confirmStopPrint(context, notifier) : null,
                ),
                const Text('速度',
                    style: TextStyle(
                        fontSize: 12, color: DeckColors.textSecondary)),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('静音')),
                    ButtonSegment(value: 2, label: Text('标准')),
                    ButtonSegment(value: 3, label: Text('运动')),
                    ButtonSegment(value: 4, label: Text('疯狂')),
                  ],
                  selected: {s.speedLevel > 0 ? s.speedLevel : 2},
                  onSelectionChanged:
                      live ? (sel) => notifier.setSpeed(sel.first) : null,
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity:
                        VisualDensity(horizontal: -4, vertical: -2),
                    textStyle:
                        WidgetStatePropertyAll(TextStyle(fontSize: 11)),
                  ),
                ),
                const Icon(Icons.lightbulb_outline,
                    size: 14, color: DeckColors.textSecondary),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: s.lightState == 1,
                    onChanged: live ? (v) => notifier.setLight(v) : null,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _temp(String label, double t, double? target) => Text(
        target != null && target > 0
            ? '$label ${t.round()}°/${target.round()}°'
            : '$label ${t.round()}°',
        style: const TextStyle(
            fontSize: 12, color: DeckColors.textSecondary),
      );
}

/// Collapsible AMS / HMS / device details at the bottom of the compact
/// pane; auto-opens when the printer is reporting an error.
class _ExtrasTile extends StatelessWidget {
  const _ExtrasTile({required this.s});

  final BambuState s;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        initiallyExpanded: s.hasError,
        title: const Text('AMS / 报错 / 设备信息',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        children: [
          AmsCard(s: s),
          const SizedBox(height: 10),
          HmsCard(state: s),
          const SizedBox(height: 10),
          DeviceCard(s: s),
        ],
      ),
    );
  }
}
