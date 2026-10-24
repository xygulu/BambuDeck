import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/cloud_print_helper.dart';
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
      // 在本页打开时打印机被删(删除入口已收进编辑对话框): 弹回首页,
      // 别留一个没有 AppBar 的死端页 (2026-10-21)。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
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
            // 删除也收进编辑对话框 (2026-10-21: 显眼位置易误触)。
            onPressed: () => showEditPrinterDialog(context, ref, profile),
          ),
        ],
      ),
      body: DashboardBody(profileId: profileId, conn: conn, state: state),
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
      // 反馈 2026-10-21: 顶部行只剩 控制 + AMS —— 任务/进度/温度/层高/报错
      // 等状态详情全部迁到左侧打印机卡片列表, 相机墙占其余空间 (自动适配
      // 画面数, 点击放大)。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            // Fixed height, not IntrinsicHeight: SegmentedButton's render
            // object cannot answer the dry-layout pass intrinsics need
            // (crashed on first frame). 控制行在窄面板会折行, 给到两行高;
            // 顶部行还要容下 AMS 卡 (反馈 2026-10-23 高度不够会截断)。
            child: LayoutBuilder(builder: (context, box) {
              final h = box.maxWidth >= 1080 ? 132.0 : 156.0;
              return SizedBox(
                height: h,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 控制卡内容变少但仍要放下速度分段整行, 多给一点份额。
                    Expanded(
                      flex: 6,
                      child: _ControlCard(
                          profileId: profileId, s: s, live: conn.live),
                    ),
                    const SizedBox(width: 8),
                    // AMS 仍需横向排开料仓, 面板更宽时多让一点。
                    Expanded(
                      flex: box.maxWidth >= 1200 ? 6 : 5,
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
    final ams = s.ams;
    // 进料/退料方向来自打印子阶段 stg_cur (22 退料 / 24 进料)。
    final flow = switch (s.stgCur) {
      24 => AmsFlow.load,
      22 => AmsFlow.unload,
      _ => AmsFlow.none,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: ams == null
            ? const Text('未检测到 AMS',
                style: TextStyle(
                    fontSize: 13, color: DeckColors.textSecondary))
            // 进料状态不再用文字条, 直接在正在进料的通道圆圈里标「进/退」字
            // (反馈 2026-10-23); 标题行也已去掉, 高度让给料仓。
            : AmsStrip(ams: ams, flow: flow),
      ),
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
    final canControl = enabled && profile != null;
    final canPause = canControl && s.gcodeState == GcodeState.running;
    final canResume = canControl && s.gcodeState == GcodeState.pause;
    final canSwap = enabled &&
        profile != null &&
        profile.autoPlateSwap &&
        (profile.mode == PrinterMode.lan || profile.mode == PrinterMode.cloud);

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
                  onPressed: canPause
                      ? () => runControl(context, profile, s, notifier, 'pause')
                      : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canResume
                      ? () => runControl(context, profile, s, notifier, 'resume')
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
                  onPressed: canControl && s.printing
                      ? () => confirmStopPrint(context, profile, s, notifier)
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ),
            ]),
            if (canSwap) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => confirmPlateSwap(context, profile),
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

/// 控制分发：dev-ON 局域网(开发者模式确认为开)走 MQTT 直发,否则走 Connect
/// 自动化服务。MQTT 直发秒回、状态随报告流更新,不弹 snackbar;Connect 走
/// [runCloudControl](带 snackbar 反馈)。
Future<void> runControl(BuildContext context, PrinterProfile profile,
    BambuState s, ConnectionNotifier notifier, String command) async {
  if (useLanControl(profile, s)) {
    final ok = switch (command) {
      'pause' => await notifier.pause(),
      'resume' => await notifier.resume(),
      'stop' => await notifier.stop(),
      _ => false,
    };
    LogBuffer.instance.add('[控制] $command ${profile.name}: '
        '局域网直发${ok ? "已发送" : "失败"}');
    return;
  }
  await runCloudControl(context, profile, command);
}

/// 通过本机 helper 服务(Bambu Connect 自动化)发送控制命令并落到 snackbar。
/// dev-OFF/云模式打印机 LAN MQTT 控制会被固件 84033543 拦,故走 Connect(实测
/// 全链路 ~8s)。
Future<void> runCloudControl(
    BuildContext context, PrinterProfile profile, String command) async {
  final messenger = ScaffoldMessenger.of(context);
  final label = switch (command) {
    'pause' => '暂停',
    'resume' => '恢复',
    'stop' => '停止',
    _ => command,
  };
  if (!await CloudPrintHelper.instance.health()) {
    messenger.showSnackBar(const SnackBar(
        backgroundColor: DeckColors.error,
        content: Text('本机打印 helper 未运行。请先执行 python bconnect_service.py '
            '并在 系统设置→隐私与安全性→辅助功能 允许 python')));
    return;
  }
  // 服务端靠 serial 正则定位打印机,空 serial 只会得到一句「缺字段 serial」,
  // 这里提前拦下并指路 (2026-10-21 实测:某台档案没存序列号)。
  if (profile.serial.trim().isEmpty) {
    LogBuffer.instance.add('[控制] $label ${profile.name}: 失败 未配置序列号');
    messenger.showSnackBar(SnackBar(
        backgroundColor: DeckColors.error,
        content: Text('「${profile.name}」未配置序列号,Connect 自动化无法定位'
            '打印机。请在该打印机卡片 → 编辑打印机 里补上序列号')));
    return;
  }
  final r = await CloudPrintHelper.instance.control(profile.serial, command);
  LogBuffer.instance.add('[控制] ${r.command ?? command} ${profile.name}: '
      'ok=${r.ok}${r.error == null ? '' : ' err=${r.error}'}'
      '${r.elapsed == null ? '' : ' ${r.elapsed!.round()}s'}');
  if (r.ok) {
    messenger.showSnackBar(SnackBar(
        content: Text('已向「${r.printer ?? profile.name}」发送$label'
            '${r.elapsed == null ? '' : '(${r.elapsed!.round()}s)'}')));
  } else {
    messenger.showSnackBar(SnackBar(
        backgroundColor: DeckColors.error,
        content: Text('$label失败: ${r.error ?? '未知错误'}')));
  }
}

/// Shared stop confirmation (control bar + compact status bar).
void confirmStopPrint(BuildContext context, PrinterProfile profile,
    BambuState s, ConnectionNotifier notifier) {
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
            runControl(context, profile, s, notifier, 'stop');
          },
          child: const Text('确认停止'),
        ),
      ],
    ),
  );
}

/// 一键换盘 (2026-10-21 起统一走 Bambu Connect 打印服务): 把内置换盘模型交给
/// Bambu Connect 经本机 helper 云端派单, 无需开发者模式 / 局域网。dev-OFF 的 LAN
/// MQTT project_file 会被固件 84033543 拦, Connect 有合法客户端身份。结果落到
/// snackbar 和运行日志。
Future<void> confirmPlateSwap(
    BuildContext context, PrinterProfile profile) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DeckColors.surface,
      title: const Text('一键换盘?'),
      content: Text(
          '将通过 Bambu Connect 向「${profile.name}」派单并开始打印(约 5 分钟)。\n\n'
          '热床会快速震动甩下成品并把打印板送到最前端,请确保打印机前方留空。\n'
          '需要本机已运行打印 helper (python bconnect_service.py) 并在 '
          '系统设置→隐私与安全性→辅助功能 允许 python。'),
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
    if (profile.serial.trim().isEmpty) {
      messenger.showSnackBar(SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('「${profile.name}」未配置序列号,Connect 自动化无法定位'
              '打印机。请在该打印机卡片 → 编辑打印机 里补上序列号')));
      return;
    }
    if (!await CloudPrintHelper.instance.health()) {
      messenger.showSnackBar(const SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('本机打印 helper 未运行。请先执行 python bconnect_service.py '
              '并在 系统设置→隐私与安全性→辅助功能 允许 python')));
      return;
    }
    final r = await startCloudPlateSwap(profile);
    LogBuffer.instance.add('[换盘] 派单: ok=${r.ok} task=${r.taskId} '
        'status=${r.taskStatus}'
        '${r.error == null ? '' : ' err=${r.error}'}'
        '${r.elapsedTotal == null ? '' : ' 总耗时 ${r.elapsedTotal!.toStringAsFixed(1)}s'}');
    for (final s in r.steps) {
      LogBuffer.instance.add('[换盘] $s');
    }
    // 成功判定 =「已发送」（离开发送页），不再等任务落库/打印执行。
    if (r.ok) {
      messenger.showSnackBar(SnackBar(
          content: Text('已通过 Bambu Connect 派单'
              '${r.taskId == null ? '' : '(任务 ${r.taskId})'},打印机将开始换盘')));
    } else {
      messenger.showSnackBar(SnackBar(
          backgroundColor: DeckColors.error,
          content: Text('换盘未发送: ${r.error ?? 'Bambu Connect 发送页未离开'}')));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(
        backgroundColor: DeckColors.error,
        content: Text('换盘失败: $e')));
  }
}

/// 控制卡 —— 紧凑面板顶行的控制按钮 (暂停/恢复/停止 + 速度 + 腔灯 + 换盘)。
/// 任务/进度/温度等状态详情在左侧打印机卡片列表 (反馈 2026-10-21 迁移),
/// 本卡只留操作, 垂直居中。
class _ControlCard extends ConsumerWidget {
  const _ControlCard({
    required this.profileId,
    required this.s,
    required this.live,
  });

  final String profileId;
  final BambuState s;
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
        (profile.mode == PrinterMode.lan || profile.mode == PrinterMode.cloud);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
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
                    if ((canPause || canResume) && profile != null)
                      FilledButton.tonalIcon(
                        onPressed: () => runControl(context, profile, s,
                            notifier, canPause ? 'pause' : 'resume'),
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
                      onPressed: live && profile != null && s.printing
                          ? () => confirmStopPrint(context, profile, s, notifier)
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
                        onPressed: () => confirmPlateSwap(context, profile),
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
}
