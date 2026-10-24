import 'dart:async';

import 'package:flutter/material.dart';

import '../data/ptz_client.dart';

/// Measures the pad's real behaviour: the user presses each key, watches which
/// way the picture actually moves, and says so. Returns the resulting key map
/// (see [applyPtzCalibration]) or null when cancelled.
///
/// Guessing the mapping from mount, firmware and picture rotation was wrong
/// twice on real hardware (云台方向 2026-10-24); asking for the observation is
/// the only description that is true by definition.
Future<String?> showPtzCalibrateDialog(
  BuildContext context, {
  required PtzClient client,
  required String current,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PtzCalibrateDialog(client: client, current: current),
  );
}

class _PtzCalibrateDialog extends StatefulWidget {
  const _PtzCalibrateDialog({required this.client, required this.current});

  final PtzClient client;
  final String current;

  @override
  State<_PtzCalibrateDialog> createState() => _PtzCalibrateDialogState();
}

class _PtzCalibrateDialogState extends State<_PtzCalibrateDialog> {
  /// key letter -> direction the picture was seen to move.
  final _observed = <String, String>{};
  Timer? _repeat;
  String? _error;

  static const _speed = 0.5;
  static const _labels = {'U': '上', 'D': '下', 'L': '左', 'R': '右'};
  static const _arrows = {'U': '↑', 'D': '↓', 'L': '←', 'R': '→'};

  @override
  void initState() {
    super.initState();
    final start =
        isValidPtzCalibration(widget.current) ? widget.current : ptzKeys;
    for (var i = 0; i < 4; i++) {
      _observed[ptzKeys[i]] = start[i];
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    widget.client.stop().catchError((Object _) {});
    super.dispose();
  }

  void _start(String key) {
    _issue(key);
    _repeat?.cancel();
    _repeat =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _issue(key));
  }

  void _issue(String key) {
    final (pan, tilt) = switch (key) {
      'U' => (0.0, _speed),
      'D' => (0.0, -_speed),
      'L' => (-_speed, 0.0),
      _ => (_speed, 0.0),
    };
    widget.client.move(pan: pan, tilt: tilt).catchError((Object _) {});
  }

  void _end() {
    _repeat?.cancel();
    _repeat = null;
    widget.client.stop().catchError((Object _) {});
  }

  String get _result =>
      [for (final k in ptzKeys.split('')) _observed[k] ?? k].join();

  void _save() {
    final r = _result;
    if (!isValidPtzCalibration(r)) {
      setState(() => _error = '四个键被指到了同一个方向，请再确认一下');
      return;
    }
    Navigator.of(context).pop(r);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('云台方向校准'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '按住每个方向键，看画面实际往哪边走，然后选中那个方向。'
                '保存后方向键就按这里的记录纠正（网页控制台同样生效）。'
                '改变画面旋转或翻转后请重新校准。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 14),
              for (final key in ptzKeys.split(''))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _row(key),
                ),
              if (_error != null)
                Text(_error!,
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            for (final k in ptzKeys.split('')) {
              _observed[k] = k;
            }
            _error = null;
          }),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget _row(String key) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('按「${_labels[key]}」键', style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 10),
            GestureDetector(
              onTapDown: (_) => _start(key),
              onTapUp: (_) => _end(),
              onTapCancel: _end,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('按住测试', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(width: 10),
            const Flexible(
              child: Text('画面往哪边走？', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final d in ptzKeys.split(''))
              ChoiceChip(
                label: Text('${_arrows[d]} ${_labels[d]}'),
                selected: _observed[key] == d,
                onSelected: (_) => setState(() {
                  _observed[key] = d;
                  _error = null;
                }),
                visualDensity: VisualDensity.compact,
                labelStyle: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ],
    );
  }
}
