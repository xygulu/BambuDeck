import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/plate_swap.dart';
import '../../data/log_buffer.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';
import '../printers/edit_printer_dialog.dart';
import 'printer_camera_section.dart';

/// Full monitoring dashboard for one printer: progress ring, temperatures,
/// fans, AMS strip, HMS errors and control bar (PRD FR-1 / FR-2 / FR-4).
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key, required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(printersProvider
        .select((l) => printerByIdOf(l.valueOrNull, profileId)));
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
          // 网络信息跟在名称行的右侧 (反馈 2026-10-20: 不再单独占设备卡).
          if (state != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: NetworkInfoText(s: state)),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: '编辑打印机',
            onPressed: () => showEditPrinterDialog(context, ref, profile),
          ),
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
/// - `compact: true` (monitoring screen's right pane, 反馈 2026-10-20): a
///   slim side-by-side info row at the top (status/AMS/device, plus HMS
///   while erroring) and the auto-fit camera wall taking the rest.
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
      // 反馈 2026-10-20: status/AMS/HMS/device side by side in one slim
      // top row, the camera wall taking all remaining space (auto-fit to
      // camera count, tap to zoom).
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            // Fixed height, not IntrinsicHeight: SegmentedButton's render
            // object cannot answer the dry-layout pass intrinsics need
            // (crashed on first frame). Adaptive instead: wide enough for
            // one control line keeps the row slim; below ~1080 the status
            // card's controls wrap and need the taller box.
            child: LayoutBuilder(builder: (context, box) {
              // Errors no longer take a row slot - they surface as a chip
              // in the status card opening a dialog (反馈 2026-10-20), so
              // the height only depends on the control line wrapping.
              // Network facts moved to the printer-name row and the speed/
              // light text dropped (duplicated the controls) - the row is
              // just status + AMS now, AMS the wider of the two.
              final h = box.maxWidth >= 1080 ? 150.0 : 196.0;
              return SizedBox(
                height: h,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _StatusCard(
                          profileId: profileId,
                          s: s,
                          accent: accent,
                          live: conn.live),
                    ),
                    const SizedBox(width: 8),
                    // AMS gets the widest slot: several units must line up
                    // horizontally, plus the active-feed channel readout.
                    // Extra share when the pane is wide - the status card's
                    // single control line still fits (反馈 2026-10-20).
                    Expanded(
                      flex: box.maxWidth >= 1200 ? 7 : 6,
                      child: AmsCard(s: s),
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Expanded(child: CameraWallSection(profileId: profileId)),
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
              if (s.doorOpen == true) const _DoorChip(),
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
          label: '热床',
          value: fmtTemp(s.bedTemp, s.bedTarget),
          color: DeckColors.bed),
      if (s.chamberTemp > 0)
        StatChip(
            label: '腔体',
            value: fmtTemp(s.chamberTemp),
            color: DeckColors.chamber),
      StatChip(
          label: '散热风扇',
          value: '${s.fans.cooling}%',
          color: DeckColors.running),
      StatChip(
          label: '辅助风扇', value: '${s.fans.aux}%', color: DeckColors.prepare),
      StatChip(
          label: '腔体风扇',
          value: '${s.fans.chamber}%',
          color: DeckColors.chamber),
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
            Row(children: [
              const Text('AMS 耗材',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              // 当前进料通道状态 (反馈 2026-10-20).
              if (s.ams != null) _FeedChip(ams: s.ams!),
            ]),
            const SizedBox(height: 10),
            // Scroll instead of overflowing when the compact top row's
            // fixed height is shorter than the strip needs (narrow panes
            // wrap the tray swatches); loose flex keeps natural height in
            // the full dashboard.
            Flexible(
              child: SingleChildScrollView(
                child: s.ams != null
                    ? AmsStrip(ams: s.ams!)
                    : const Text('未检测到 AMS',
                        style: TextStyle(
                            fontSize: 13, color: DeckColors.textSecondary)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The feeding channel right in the AMS header: color swatch of the
/// active tray + which unit/slot it feeds from (反馈 2026-10-20).
class _FeedChip extends StatelessWidget {
  const _FeedChip({required this.ams});

  final AmsState ams;

  @override
  Widget build(BuildContext context) {
    final tray = ams.activeTray;
    if (tray == null) {
      return const Text('进料 -',
          style: TextStyle(fontSize: 12, color: DeckColors.textSecondary));
    }
    // Mirror AmsStrip's unit naming (widgets.dart).
    String source;
    if (ams.activeTrayId == 254) {
      source = '虚拟通道';
    } else {
      AmsUnit? unit;
      for (final u in ams.units) {
        if (u.id == ams.activeTrayId) unit = u;
      }
      source = unit == null
          ? '通道 ${(ams.activeTrayIndex ?? 0) + 1}'
          : '${unit.id >= 128 ? 'AMS HT ${unit.id - 127}' : 'AMS ${unit.id + 1}'}'
              ' · 通道 ${(ams.activeTrayIndex ?? 0) + 1}';
    }
    final color = tray.colorRrggbb == null
        ? const Color(0xFF9E9E9E)
        : Color(0xFF000000 | tray.colorRrggbb!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: DeckColors.textSecondary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: DeckColors.textPrimary.withValues(alpha: 0.25)),
          ),
        ),
        const SizedBox(width: 6),
        Text('进料 $source${tray.type.isEmpty ? '' : ' · ${tray.type}'}',
            style: const TextStyle(
                fontSize: 12, color: DeckColors.textPrimary)),
      ]),
    );
  }
}

/// Network facts (WiFi signal + IP) for the printer-name row, right
/// aligned (反馈 2026-10-20: 网络信息不再单独占设备卡). Hides itself when
/// the state has neither.
class NetworkInfoText extends StatelessWidget {
  const NetworkInfoText({super.key, required this.s});

  final BambuState s;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (s.wifiSignal != null) 'WiFi ${s.wifiSignal} dBm',
      if (s.localIp.isNotEmpty) s.localIp,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' · '),
        style: const TextStyle(
            fontSize: 12, color: DeckColors.textSecondary));
  }
}

/// HMS 报错弹窗 (反馈 2026-10-20): 报错不再常驻信息行, 由状态卡的报错
/// 芯片打开, 完整列出条目。
void showHmsDialog(BuildContext context, BambuState s) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: Text(s.hms.length > 1 ? '打印机报错 · ${s.hms.length} 条' : '打印机报错'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: HmsCard(
              state: s, maxEntries: s.hms.isEmpty ? 1 : s.hms.length),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
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
    final profile = ref.watch(printersProvider
        .select((l) => printerByIdOf(l.valueOrNull, profileId)));
    final canSwap = enabled &&
        profile != null &&
        profile.autoPlateSwap &&
        profile.mode == PrinterMode.lan;

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
                  style:
                      FilledButton.styleFrom(backgroundColor: DeckColors.error),
                  onPressed: enabled
                      ? () => confirmStopPrint(context, notifier)
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ),
            ]),
            if (canSwap) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () =>
                    confirmPlateSwap(context, ref, profile, notifier),
                icon: const Icon(Icons.auto_awesome_motion_outlined),
                label: const Text('一键换盘'),
              ),
            ],
            const SizedBox(height: 10),
            Row(children: [
              const Text('速度',
                  style:
                      TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
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
                  onSelectionChanged:
                      enabled ? (sel) => notifier.setSpeed(sel.first) : null,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Text('腔灯',
                  style:
                      TextStyle(fontSize: 12, color: DeckColors.textSecondary)),
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

/// 一键换盘 confirmation + execution (换盘 2026-10-20): uploads the bundled
/// swap model over FTPS and prints it; the model's tail gcode shakes the
/// finished print off and ejects the plate. Result lands in a snackbar and
/// the run log either way.
Future<void> confirmPlateSwap(BuildContext context, WidgetRef ref,
    PrinterProfile profile, ConnectionNotifier notifier) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('一键换盘?'),
      content: Text(
          '将向「${profile.name}」上传内置换盘模型并开始打印(约 5 分钟)。\n\n'
          '热床会快速震动甩下成品并把打印板送到最前端,请确保打印机前方留空。\n'
          '不会暂停正在进行的任务 - 请在打印机空闲时执行。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('开始换盘')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    // The card's `live` gate counts connecting/reconnecting too, so the
    // button is clickable while the MQTT link is mid-reconnect - the FTPS
    // step would still succeed and the publish would abort with a baffling
    // "未连接". Wait out a reconnect blip first (换盘 2026-10-21).
    if (!await _waitForConnected(() {
      // The widget may be gone mid-poll; a dead ref must not crash the
      // wait - treat it as "still not connected".
      try {
        return ref.read(connectionProvider(profile.id)).status ==
            BambuConnStatus.connected;
      } catch (_) {
        return false;
      }
    })) {
      throw Exception('打印机当前未连接(可能在重连),请确认打印机在线后重试');
    }
    // 换盘模型按 PLA 切片 - 每次点击都实时读当前 AMS 状态选 PLA 槽位
    // (颜色不限,用户 2026-10-21);AMS 没有 PLA 就退回外置料并记录。
    final amsChoice = _pickSwapAmsSafely(ref, profile.id);
    await startPlateSwap(profile,
        sendPrint: notifier.printProjectFile, ams: amsChoice);
    messenger.showSnackBar(
        const SnackBar(content: Text('已发送,正在等待打印机响应…')));
    // The MQTT layer accepts the publish even when firmware refuses the
    // command - post-2025-01 firmware silently drops unsigned project_file
    // (print_error 84033543) unless 开发者模式 is on. Watch the report
    // stream so the user learns what ACTUALLY happened (2026-10-21).
    final container = ProviderScope.containerOf(context);
    final (started, err) = await _watchSwapOutcome(container, profile.id);
    // The outcome snackbar is transient - the run log keeps the verdict.
    LogBuffer.instance.add('[换盘] 观察结果: '
        '${started ? "已开始执行" : err == 0 ? "无响应" : "报错 $err"}');
    if (started) {
      messenger.showSnackBar(
          const SnackBar(content: Text('换盘已开始执行(先调平,热床会移动甩盘)')));
    } else if (err == 84033543) {
      messenger.showSnackBar(const SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('打印机拒收了换盘命令(84033543 = 签名校验未通过)。'
              '请确认 ~/.bambudeck/signing_key.pem 在位并重启 app;'
              '若固件不信任该签名证书,只能在打印机上开「开发者模式」绕过')));
    } else if (err != 0) {
      final text = printErrorDescription(err);
      messenger.showSnackBar(SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('打印机报错 $err${text == null ? '' : ': $text'}')));
    } else {
      messenger.showSnackBar(const SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('打印机没有响应换盘命令——'
              '请确认打印机空闲、屏幕没有弹窗,然后重试')));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        backgroundColor: DeckColors.error,
        content: Text('换盘失败: $e')));
  }
}

/// Live AMS slot pick for one swap attempt. The printer may be reconnecting
/// or the widget unmounted - any ref trouble means "no AMS info", not a
/// crash (换盘 2026-10-21).
({int amsId, int slot})? _pickSwapAmsSafely(WidgetRef ref, String profileId) {
  try {
    final choice = pickSwapAmsSlot(
        ref.read(connectionProvider(profileId)).state?.ams);
    LogBuffer.instance.add('[换盘] AMS 选料: '
        '${choice == null ? "未找到 PLA,改用外置料" : "单元${choice.amsId} 槽${choice.slot + 1}"}');
    return choice;
  } catch (_) {
    return null;
  }
}

/// Outcome of watching the printer after a swap command: did the job take
/// (prepare/running that was not running before) or did firmware report a
/// fresh print_error (rejection code).
Future<(bool, int)> _watchSwapOutcome(
    ProviderContainer container, String profileId,
    {Duration window = const Duration(seconds: 45)}) async {
  final initial = () {
    try {
      return container.read(connectionProvider(profileId)).state;
    } catch (_) {
      return null;
    }
  }();
  final initialError = initial?.printError ?? 0;
  final wasActive = initial?.gcodeState == GcodeState.prepare ||
      initial?.gcodeState == GcodeState.running;
  LogBuffer.instance.add('[换盘] 开始观察 45s '
      '(gcode=${initial?.gcodeState.label ?? "?"}, print_error=$initialError)');
  final watch = Stopwatch()..start();
  while (watch.elapsed < window) {
    await Future.delayed(const Duration(milliseconds: 600));
    final conn = () {
      try {
        return container.read(connectionProvider(profileId));
      } catch (_) {
        return null;
      }
    }();
    final s = conn?.state;
    if (s == null) continue;
    if (s.printError != 0 && s.printError != initialError) {
      LogBuffer.instance.add('[换盘] 打印机报告 print_error=${s.printError} '
          '(${printErrorDescription(s.printError) ?? "无描述"})');
      return (false, s.printError);
    }
    if (!wasActive &&
        (s.gcodeState == GcodeState.prepare ||
            s.gcodeState == GcodeState.running)) {
      return (true, 0);
    }
  }
  return (false, 0);
}

/// Polls the connection until it is truly `connected` (not just isLive) or
/// the timeout elapses - a reconnecting link usually lands within a couple
/// of seconds.
Future<bool> _waitForConnected(bool Function() isConnected,
    {Duration timeout = const Duration(seconds: 8)}) async {
  const step = Duration(milliseconds: 400);
  var waited = Duration.zero;
  while (!isConnected()) {
    if (waited >= timeout) return false;
    await Future.delayed(step);
    waited += step;
  }
  return true;
}

/// Status + control card for the compact pane's top info row: dense task,
/// progress, temps and controls so the row stays slim and the camera wall
/// below keeps the space (反馈 2026-10-20).
class _StatusCard extends ConsumerWidget {
  const _StatusCard({
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
    // Same gate as the wide layout's _ControlBar swap button - the compact
    // pane must offer it too (反馈 2026-10-21: 勾了配置却找不到按钮).
    final profile = ref.watch(
        printersProvider.select((l) => printerByIdOf(l.valueOrNull, profileId)));
    final canSwap = live &&
        profile != null &&
        profile.autoPlateSwap &&
        profile.mode == PrinterMode.lan;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              // 任务预览图 (反馈 2026-10-20): 云端任务封面上屏, 同 Bambu
              // Handy; 无云端凭据的打印机整个不占位。
              _TaskCover(profileId: profileId, taskName: s.subtaskName),
              const SizedBox(width: 8),
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
              if (s.hasError) ...[
                const SizedBox(width: 8),
                // Errors live in a dialog now, not a dedicated card
                // (反馈 2026-10-20) - the chip is the entry point.
                InkWell(
                  onTap: () => showHmsDialog(context, s),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: DeckColors.error.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                          color: DeckColors.error.withValues(alpha: 0.5)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.error_outline,
                          size: 13, color: DeckColors.error),
                      const SizedBox(width: 4),
                      Text(
                          s.hms.length > 1 ? '报错 ${s.hms.length}' : '报错',
                          style: const TextStyle(
                              color: DeckColors.error, fontSize: 12)),
                    ]),
                  ),
                ),
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
                  Text(
                      '层 ${s.layerNum}/${s.totalLayers} · 剩 ${fmtRemaining(s.remainingMinutes)}',
                      style: const TextStyle(
                          fontSize: 12, color: DeckColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 8),
            // Controls are the row's compressible part: in the compact top
            // row's fixed height a narrow card can't show every control
            // line - scroll instead of painting overflow stripes.
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
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
                        backgroundColor:
                            DeckColors.error.withValues(alpha: 0.15),
                        foregroundColor: DeckColors.error,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: live
                          ? () => confirmStopPrint(context, notifier)
                          : null,
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
                    // 腔灯图标随开关点亮 (反馈 2026-10-20): 亮 = 实心黄色
                    // 并稍大, 灭 = 常规描边灰。
                    Icon(
                      s.lightState == 1
                          ? Icons.lightbulb
                          : Icons.lightbulb_outline,
                      size: s.lightState == 1 ? 18 : 16,
                      color: s.lightState == 1
                          ? const Color(0xFFFFC107)
                          : DeckColors.textSecondary,
                    ),
                    Transform.scale(
                      scale: 0.8,
                      child: Switch(
                        value: s.lightState == 1,
                        onChanged: live ? (v) => notifier.setLight(v) : null,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    // 换盘放灯光控制之后 (用户要求 2026-10-21)。
                    if (canSwap) ...[
                      const SizedBox(width: 4),
                      // canSwap's profile!=null promotes the local - no
                      // re-check needed here.
                      OutlinedButton.icon(
                        onPressed: () =>
                            confirmPlateSwap(context, ref, profile, notifier),
                        icon: const Icon(Icons.auto_awesome_motion_outlined,
                            size: 16),
                        label: const Text('一键换盘',
                            style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
        style: const TextStyle(fontSize: 12, color: DeckColors.textSecondary),
      );
}

/// Plate preview of the current task (Bambu Handy 风格, 反馈 2026-10-20):
/// the cloud task cover, fetched per (printer, task). Hidden entirely for
/// printers without a cloud token; placeholder box while loading/missing.
class _TaskCover extends ConsumerWidget {
  const _TaskCover({required this.profileId, required this.taskName});

  final String profileId;
  final String taskName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(printersProvider
        .select((l) => printerByIdOf(l.valueOrNull, profileId)));
    if (profile == null || profile.token.isEmpty) {
      return const SizedBox.shrink();
    }
    final cover = ref
        .watch(taskCoverProvider((profileId, taskName)))
        .valueOrNull;
    final placeholder = Container(
      width: 46,
      height: 46,
      color: DeckColors.border.withValues(alpha: 0.35),
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined,
          size: 18, color: DeckColors.textSecondary),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: cover == null
          ? placeholder
          : Image.network(cover,
              width: 46,
              height: 46,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => placeholder),
    );
  }
}
