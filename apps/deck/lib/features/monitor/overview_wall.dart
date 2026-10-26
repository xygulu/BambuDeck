import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/printer_profile.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';

/// 最佳网格列数: 让每个格子的宽高比最接近 16:9, n 个格子无论多少都铺满
/// 一屏 (缩放时自动排布)。摄像头页墙 / 监控页相机墙共用这一份算法。
int bestFitColumns(int n, double w, double h) {
  var bestCols = 1;
  var bestErr = double.infinity;
  for (var cols = 1; cols <= n; cols++) {
    final rows = (n / cols).ceil();
    final err = ((w / cols) / (h / rows) / (16 / 9) - 1).abs();
    if (err < bestErr) {
      bestErr = err;
      bestCols = cols;
    }
  }
  return bestCols;
}

/// 画面格左上角的绑定打印机状态角标 (状态徽章 + 名称 + 进度), 摄像头页墙
/// 与监控页相机墙共用。
class FeedStatusChip extends ConsumerWidget {
  const FeedStatusChip({super.key, required this.printer});

  final PrinterProfile printer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider(printer.id));
    final s = conn.state;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (s != null)
          StateBadge(state: s.gcodeState)
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: switch (conn.status) {
                BambuConnStatus.connected => DeckColors.running,
                BambuConnStatus.connecting ||
                BambuConnStatus.reconnecting =>
                  DeckColors.warning,
                _ => DeckColors.textSecondary,
              },
            ),
          ),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 120),
          child: Text(printer.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.white)),
        ),
        if (s != null && s.printing)
          Text(' ${s.progress}%',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: stateColor(s.gcodeState))),
      ]),
    );
  }
}
