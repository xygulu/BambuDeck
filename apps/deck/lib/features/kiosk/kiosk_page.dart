import 'dart:async';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/format.dart';
import '../../data/app_settings.dart';
import '../../data/providers.dart';
import '../../ui/widgets.dart';

/// Kiosk rotation (PRD FR-6 自动轮换): one printer at a time, big text,
/// auto-advance. `cycle` walks every printer; `printingFirst` pins the
/// view to printing printers and only slow-passes the idle ones. Esc or
/// the corner button leaves.
class KioskPage extends ConsumerStatefulWidget {
  const KioskPage({super.key, required this.startId});

  final String startId;

  @override
  ConsumerState<KioskPage> createState() => _KioskPageState();
}

class _KioskPageState extends ConsumerState<KioskPage> {
  late String _current = widget.startId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    final sec = ref.read(appSettingsProvider).valueOrNull?.kioskRotateSec ?? 15;
    _timer = Timer.periodic(Duration(seconds: sec), (_) => _advance());
  }

  void _advance() {
    final printers = ref.read(printersProvider).valueOrNull ?? const [];
    if (printers.length < 2) return;
    final mode = ref.read(appSettingsProvider).valueOrNull?.kioskMode ??
        KioskMode.cycle;
    if (mode == KioskMode.off) return;

    // printingFirst: hold while the shown printer is working.
    if (mode == KioskMode.printingFirst) {
      final conn = ref.read(connectionProvider(_current));
      if (conn.state?.printing == true) return;
    }
    var i = printers.indexWhere((p) => p.id == _current);
    i = (i + 1) % printers.length;
    // printingFirst: skip ahead to the next busy printer if one exists.
    if (mode == KioskMode.printingFirst) {
      final n = printers.length;
      for (var k = 0; k < n; k++) {
        final candidate = printers[(i + k) % n];
        if (ref.read(connectionProvider(candidate.id)).state?.printing ==
            true) {
          i = (i + k) % n;
          break;
        }
      }
    }
    setState(() => _current = printers[i].id);
  }

  Future<void> _exit() async {
    _timer?.cancel();
    // Remember the user turned kiosk off, so the appbar icon stays in step.
    final s = ref.read(appSettingsProvider).valueOrNull;
    if (s != null && s.kioskMode != KioskMode.off) {
      await ref.read(appSettingsProvider.notifier).set(
          s.copyWith(kioskMode: KioskMode.off));
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printersProvider).valueOrNull ?? const [];
    final profile = printers.where((p) => p.id == _current).firstOrNull;

    return KeyboardListener(
      focusNode: FocusNode(),
      onKeyEvent: (e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.escape)) {
          _exit();
        }
      },
      child: Scaffold(
        backgroundColor: DeckColors.bg,
        body: Stack(children: [
          if (profile == null)
            const Center(
                child: Text('没有可轮播的打印机',
                    style: TextStyle(color: DeckColors.textSecondary)))
          else
            _KioskBody(profileId: profile.id),
          Positioned(
            top: 18,
            right: 18,
            child: IconButton.outlined(
              icon: const Icon(Icons.close, size: 22),
              tooltip: '退出轮播 (Esc)',
              onPressed: _exit,
            ),
          ),
        ]),
      ),
    );
  }
}

/// Big-format state panel for one printer, kiosk-distance readable.
class _KioskBody extends ConsumerWidget {
  const _KioskBody({required this.profileId});

  final String profileId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(connectionProvider(profileId));
    final profile = ref.watch(printersProvider).valueOrNull
        ?.where((p) => p.id == profileId)
        .firstOrNull;
    final s = conn.state;

    if (profile == null) return const SizedBox.shrink();

    final color = s == null ? DeckColors.idle : stateColor(s.gcodeState);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(profile.name,
              style: const TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            s == null
                ? '等待连接…'
                : '${gcodeStateLabel(s.gcodeState, zh: true)}'
                    '${s.subtaskName.isEmpty ? '' : ' · ${s.subtaskName}'}',
            style: TextStyle(
                fontSize: 18,
                color: s == null
                    ? DeckColors.textSecondary
                    : stateColor(s.gcodeState)),
          ),
          const SizedBox(height: 30),
          SizedBox(
            width: 230,
            height: 230,
            child: ProgressRing(
              progress: s?.progress ?? 0,
              color: color,
              size: 230,
              stroke: 16,
            ),
          ),
          const SizedBox(height: 30),
          if (s != null)
            Wrap(spacing: 34, runSpacing: 12, alignment: WrapAlignment.center,
                children: [
              _metric('喷嘴',
                  '${s.nozzleTemp.round()}°${_target(s.nozzleTarget)}',
                  DeckColors.nozzle),
              _metric('热床',
                  '${s.bedTemp.round()}°${_target(s.bedTarget)}',
                  DeckColors.bed),
              _metric('腔体', '${s.chamberTemp.round()}°', DeckColors.chamber),
              if (s.totalLayers > 0)
                _metric('层', '${s.layerNum}/${s.totalLayers}', color),
              if (s.remainingMinutes > 0)
                _metric('剩余', fmtRemaining(s.remainingMinutes), color),
            ]),
          if (s?.hasError == true) ...[
            const SizedBox(height: 22),
            Text(
              s!.hms.isNotEmpty
                  ? hmsDescription(s.hms.first) ?? s.hms.first.ecode
                  : printErrorDescription(s.printError) ?? '打印机报错',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 15, color: DeckColors.error),
            ),
          ],
        ]),
      ),
    );
  }

  String _target(double t) => t > 0 ? '/${t.round()}°' : '';

  Widget _metric(String label, String value, Color accent) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 24, fontWeight: FontWeight.w700, color: accent)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: DeckColors.textSecondary)),
        ],
      );
}
