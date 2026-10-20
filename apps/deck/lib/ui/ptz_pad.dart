import 'dart:async';

import 'package:flutter/material.dart';

import '../data/onvif_ptz.dart';

/// Press-and-hold PTZ pad for ONVIF cameras. Probes lazily on first
/// build; hides itself when the camera has no reachable ONVIF service.
/// Movement re-issues ContinuousMove every 250 ms while held and sends
/// Stop on release, so a dropped packet never leaves the camera spinning.
class PtzPad extends StatefulWidget {
  const PtzPad({super.key, required this.client});

  final OnvifPtz client;

  @override
  State<PtzPad> createState() => _PtzPadState();
}

class _PtzPadState extends State<PtzPad> {
  bool _probing = true;
  bool _available = false;
  Timer? _repeat;

  static const _speed = 0.5;
  static const _moveInterval = Duration(milliseconds: 250);

  @override
  void initState() {
    super.initState();
    widget.client.probe().then((ok) {
      if (mounted) {
        setState(() {
          _available = ok;
          _probing = false;
        });
      }
    });
  }

  @override
  void didUpdateWidget(PtzPad old) {
    super.didUpdateWidget(old);
    if (old.client != widget.client) {
      widget.client.probe().then((ok) {
        if (mounted) {
          setState(() {
            _available = ok;
            _probing = false;
          });
        }
      });
    }
  }

  void _start(double pan, double tilt) {
    _issue(pan, tilt);
    _repeat?.cancel();
    _repeat = Timer.periodic(_moveInterval, (_) => _issue(pan, tilt));
  }

  void _issue(double pan, double tilt) {
    widget.client.move(pan: pan, tilt: tilt).catchError((Object _) {});
  }

  void _end() {
    _repeat?.cancel();
    _repeat = null;
    widget.client.stop().catchError((Object _) {});
  }

  @override
  void dispose() {
    // The client is owned by the enclosing CameraTile - do not close it.
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_probing) return const SizedBox.shrink();
    if (!_available) return const SizedBox.shrink();
    Widget btn(IconData icon, double pan, double tilt, String tip) =>
        Listener(
          onPointerDown: (_) => _start(pan, tilt),
          onPointerUp: (_) => _end(),
          onPointerCancel: (_) => _end(),
          child: IconButton.filledTonal(
            icon: Icon(icon, size: 18, color: Colors.white),
            tooltip: tip,
            onPressed: () {}, // press-and-hold handled by the Listener
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.45),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        btn(Icons.keyboard_arrow_up_rounded, 0, _speed, '上转'),
        Row(mainAxisSize: MainAxisSize.min, children: [
          btn(Icons.keyboard_arrow_left_rounded, -_speed, 0, '左转'),
          const SizedBox(width: 2),
          btn(Icons.keyboard_arrow_right_rounded, _speed, 0, '右转'),
        ]),
        btn(Icons.keyboard_arrow_down_rounded, 0, -_speed, '下转'),
      ]),
    );
  }
}

/// Small chip-style quality switch shown on RTSP tiles whose URL encodes
/// a recognizable main/sub stream. persistence lives with the caller.
class QualityToggle extends StatelessWidget {
  const QualityToggle({
    super.key,
    required this.isSub,
    required this.onToggle,
  });

  final bool isSub;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isSub ? Icons.high_quality : Icons.hd_outlined,
                size: 13, color: Colors.white),
            const SizedBox(width: 4),
            Text(isSub ? '子码流' : '主码流',
                style: const TextStyle(fontSize: 11, color: Colors.white)),
          ]),
        ),
      );
}
