import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Anti-aliased progress ring, the visual anchor of the dashboard
/// (gauge semantics from BambuHelper's arc gauges).
class ProgressRing extends StatelessWidget {
  const ProgressRing({
    super.key,
    required this.progress,
    required this.color,
    this.size = 180,
    this.stroke = 14,
    this.label,
    this.sublabel,
  });

  final int progress; // 0-100
  final Color color;
  final double size;
  final double stroke;
  final String? label;
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress / 100,
          color: color,
          stroke: stroke,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label ?? '$progress%',
                style: TextStyle(
                  fontSize: size * 0.21,
                  fontWeight: FontWeight.w700,
                  color: DeckColors.textPrimary,
                  height: 1.0,
                ),
              ),
              if (sublabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  sublabel!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DeckColors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.stroke,
  });

  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = size.shortestSide;
    final radius = (shortest - stroke) / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Full circle: a 270° gauge left the bottom quarter open even at
    // 100%, which read as "the ring never closes" (反馈 2026-10-20).
    final startAngle = -90 * _deg;
    final sweep = 360 * _deg;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = DeckColors.border;
    canvas.drawArc(rect, startAngle, sweep, false, track);

    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) canvas.drawArc(rect, startAngle, sweep * p, false, fg);
  }

  static const _deg = 3.1415926535897932 / 180;

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// Status badge (IDLE/RUNNING/...) with state color.
class StateBadge extends StatelessWidget {
  const StateBadge({super.key, required this.state, this.zh = true});
  final GcodeState state;
  final bool zh;

  @override
  Widget build(BuildContext context) {
    final color = stateColor(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        gcodeStateLabel(state, zh: zh),
        style: TextStyle(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// Compact temperature chip: label, current(/target), colored dot.
class StatChip extends StatelessWidget {
  const StatChip({
    super.key,
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DeckColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DeckColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: DeckColors.textSecondary)),
          ]),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: DeckColors.textPrimary)),
        ],
      ),
    );
  }
}

/// Filament flow direction on the active tray (进料/退料), derived from
/// `print.stg_cur` (22 退料 / 24 进料).
enum AmsFlow { none, load, unload }

/// AMS row: one card per unit (humidity + drying), four tray swatches each,
/// plus the external spool when present.
class AmsStrip extends StatelessWidget {
  const AmsStrip({super.key, required this.ams, this.flow = AmsFlow.none});
  final AmsState ams;
  final AmsFlow flow;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final unit in ams.units) _UnitCard(unit: unit, ams: ams, flow: flow),
      if (ams.vtTray != null)
        _VtCard(
            tray: ams.vtTray!, active: ams.activeTrayId == 254, flow: flow),
    ];
    if (children.isEmpty) {
      return const Text('AMS 未连接',
          style: TextStyle(color: DeckColors.textSecondary, fontSize: 13));
    }
    // 单行并排 (反馈 2026-10-20: 多个 AMS 不换行、不下拉): 整条按自然
    // 尺寸排成一行, 放不下时等比整体缩小, 单元永远并排可见。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child:
          Row(spacing: 10, mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit, required this.ams, required this.flow});
  final AmsUnit unit;
  final AmsState ams;
  final AmsFlow flow;

  @override
  Widget build(BuildContext context) {
    final unitLabel = unit.id >= 128 ? 'AMS HT ${unit.id - 127}' : 'AMS ${unit.id + 1}';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DeckColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DeckColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(unitLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DeckColors.textPrimary)),
            const SizedBox(width: 8),
            if (unit.drying)
              const _DryBadge()
            else
              _HumidityDot(level: unit.humidity, raw: unit.humidityRaw),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            for (var i = 0; i < unit.trays.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              _TraySwatch(
                tray: unit.trays[i],
                active: ams.activeTrayId == unit.id && ams.activeTrayIndex == i,
                flow: flow,
              ),
            ],
          ]),
        ],
      ),
    );
  }
}

class _VtCard extends StatelessWidget {
  const _VtCard({required this.tray, required this.active, required this.flow});
  final AmsTray tray;
  final bool active;
  final AmsFlow flow;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DeckColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DeckColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('外部料卷',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: DeckColors.textPrimary)),
          const SizedBox(height: 8),
          _TraySwatch(tray: tray, active: active, flow: flow),
        ],
      ),
    );
  }
}

class _DryBadge extends StatelessWidget {
  const _DryBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: DeckColors.warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('烘干中',
          style: TextStyle(fontSize: 10, color: DeckColors.warning)),
    );
  }
}

class _HumidityDot extends StatelessWidget {
  const _HumidityDot({required this.level, required this.raw});
  final int level;
  final int raw;

  @override
  Widget build(BuildContext context) {
    // Low raw RH is good; map to green -> amber -> red.
    final color = raw > 0
        ? (raw <= 40
            ? DeckColors.running
            : raw <= 60
                ? DeckColors.warning
                : DeckColors.error)
        : (level >= 4 ? DeckColors.running : level <= 1 ? DeckColors.error : DeckColors.warning);
    return Row(children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(raw > 0 ? 'RH $raw%' : '湿度 $level',
          style: const TextStyle(
              fontSize: 10, color: DeckColors.textSecondary)),
    ]);
  }
}

class _TraySwatch extends StatelessWidget {
  const _TraySwatch(
      {required this.tray, required this.active, this.flow = AmsFlow.none});
  final AmsTray tray;
  final bool active;
  final AmsFlow flow;

  @override
  Widget build(BuildContext context) {
    final color = tray.colorRrggbb == null
        ? DeckColors.border
        : Color(0xFF000000 | tray.colorRrggbb!);
    return Column(children: [
      // 只有正在进料的通道带状态 (反馈 2026-10-20 / 2026-10-23): 绿环 +
      // 圆圈中央的「进/退」字; 其余通道就是素色圆 + 类型。
      SizedBox(
        width: 40,
        height: 38,
        child: Stack(clipBehavior: Clip.none, children: [
          Center(
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                // 深色耗材(尤其黑色)在深色背景下糊成一团: 常驻一圈半透明
                // 白色细线描边 (反馈 2026-10-20); 进料中换更粗的绿环, 让
                // 进料状态更明显 (反馈 2026-10-23)。
                border: Border.all(
                  color: active
                      ? DeckColors.running
                      : Colors.white.withValues(alpha: 0.7),
                  width: active ? 3.5 : 1.5,
                ),
              ),
            ),
          ),
          // 进料/退料方向 (反馈 2026-10-23): 退料标「OUT」、进料标「IN」,
          // 换料时带料流动动画; 平时活动通道常驻「IN」。标签浮在圆圈之上,
          // 半透明浅色徽章垫底 + 深色英文小字, 在任意耗材颜色上都清晰又不把料色盖死。
          if (active)
            Center(
              child: flow == AmsFlow.unload
                  ? const _FlowLabel(loading: false, animated: true)
                  : _FlowLabel(
                      loading: true, animated: flow == AmsFlow.load),
            ),
          // 进料状态角标 (反馈 2026-10-23 恢复): 右下角绿色播放角标, 标记
          // 「正在进料」的通道, 与中央的「进/退」方向字互补。
          if (active)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 14,
                height: 14,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                    color: DeckColors.running, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow,
                    size: 11, color: Colors.white),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 3),
      SizedBox(
        width: 46,
        child: Text(
          tray.present && tray.type.isNotEmpty ? tray.type : '-',
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: DeckColors.textPrimary),
        ),
      ),
      SizedBox(
        width: 46,
        child: Text(
          tray.present
              ? '${tray.remain >= 0 ? tray.remain : '?'}%'
              : '',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 10, color: DeckColors.textSecondary),
        ),
      ),
    ]);
  }
}

/// 「进」/「退」标签, 进料/退料时带竖直流动动画 (反馈 2026-10-23): 标签沿
/// 流动方向滑动并淡入淡出, 传达「料在动」的方向感。
class _FlowLabel extends StatefulWidget {
  const _FlowLabel({required this.loading, this.animated = false});
  final bool loading; // true = 进 (向下流入喷嘴), false = 退 (向上退回 AMS)
  final bool animated;

  @override
  State<_FlowLabel> createState() => _FlowLabelState();
}

class _FlowLabelState extends State<_FlowLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 800));

  // 半透明浅色徽章 + 深色英文小字 (反馈 2026-10-23): 阴影/笔画描边都有锯齿、
  // 改用浅色半透明徽章垫底 + 深色字; 方向字用英文 IN/OUT 更简洁, 字号再调小。
  Widget _label() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        widget.loading ? 'IN' : 'OUT',
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.0,
          color: Colors.black87,
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.animated) _c.repeat();
  }

  @override
  void didUpdateWidget(_FlowLabel old) {
    super.didUpdateWidget(old);
    if (widget.animated && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.animated && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animated) return _label();
    final dir = widget.loading ? 1.0 : -1.0;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        final slide = dir * (t * 16.0 - 8.0);
        final opacity = 1.0 - (t * 2.0 - 1.0).abs();
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
              offset: Offset(0, slide), child: _label()),
        );
      },
    );
  }
}

/// HMS error card: worst-first list with severity color coding
/// (fatal red / serious orange / common yellow).
class HmsCard extends StatelessWidget {
  const HmsCard({super.key, required this.state, this.maxEntries = 4});
  final BambuState state;

  /// Cap on listed HMS entries - the compact top row passes 2 so the
  /// whole info row stays slim even when the printer is chatty.
  final int maxEntries;

  @override
  Widget build(BuildContext context) {
    if (!state.hasError) return const SizedBox.shrink();
    final worst = switch (state.hmsWorstRank) {
      0 => DeckColors.error,
      1 => DeckColors.warning,
      _ => DeckColors.pause,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: worst.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: worst.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.error_outline, size: 16, color: worst),
            const SizedBox(width: 6),
            Text(
              state.printError != 0
                  ? '打印错误 (print_error ${state.printError})'
                  : 'HMS 错误 (${state.hms.length})',
              style: TextStyle(
                  color: worst, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ]),
          const SizedBox(height: 6),
          if (state.hms.isNotEmpty)
            for (final e in state.hms.take(maxEntries))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${e.ecode} · ${severityLabel(e.severity)}',
                      style: TextStyle(
                          fontSize: 12,
                          color: worst.withValues(alpha: 0.85),
                          fontWeight: FontWeight.w600),
                    ),
                    // Sentence from the generated feed; raw ecode alone
                    // when the table doesn't know the code.
                    if (hmsDescription(e) != null)
                      Text(hmsDescription(e)!,
                          style: const TextStyle(
                              fontSize: 12,
                              color: DeckColors.textSecondary)),
                  ],
                ),
              ),
          if (state.printError != 0 && state.hms.isEmpty)
            Text(
              printErrorDescription(state.printError) ??
                  '打印机上报了错误码,等待详情推送…',
              style: const TextStyle(
                  fontSize: 12, color: DeckColors.textSecondary),
            ),
        ],
      ),
    );
  }

  String severityLabel(HmsSeverity s) => switch (s) {
        HmsSeverity.fatal => '致命',
        HmsSeverity.serious => '严重',
        HmsSeverity.common => '一般',
        HmsSeverity.unknown => '未知',
      };
}
