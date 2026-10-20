import 'dart:async';

import 'package:flutter/material.dart';

import '../data/ptz_client.dart';

/// Press-and-hold PTZ pad. The concrete transport is a [PtzClient] (ONVIF or
/// HCNetSDK) chosen by the enclosing tile; this widget only drives the common
/// probe/move/stop surface. Movement re-issues the move every 250 ms while
/// held and sends Stop on release, so a dropped packet never leaves the
/// camera spinning.
class PtzPad extends StatefulWidget {
  const PtzPad({
    super.key,
    required this.client,
    this.flipH = false,
    this.rotationDeg = 0,
    this.invertPan = false,
    this.invertTilt = false,
  });

  final PtzClient client;

  /// Horizontal mirror / clockwise rotation applied to the picture; the pad
  /// re-maps its keys through the inverse so the arrow always moves the view
  /// the way the (flipped/rotated) image shows it.
  final bool flipH;
  final int rotationDeg;

  /// Per-camera axis calibration (云台方向校准 2026-10-21): flips applied
  /// after the orientation inverse for cameras whose physical pan/tilt runs
  /// opposite to the HIK/ONVIF command semantics (one pair of arrows wrong
  /// in every orientation is the tell).
  final bool invertPan;
  final bool invertTilt;

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
    var (p, t) = orientPanTilt(
        flipH: widget.flipH, rotationDeg: widget.rotationDeg, pan: pan, tilt: tilt);
    if (widget.invertPan) p = -p;
    if (widget.invertTilt) t = -t;
    widget.client.move(pan: p, tilt: t).catchError((Object _) {});
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
    // Always visible so the feature is discoverable; dimmed with an
    // explanatory tooltip only while the camera has no reachable PTZ service
    // (用户反馈 2026-10-20: 隐藏了就没人知道有云台). The direction keys carry
    // no tooltip - hovering an arrow must not pop a hint (用户反馈 2026-10-20).
    final pad = AnimatedOpacity(
      opacity: _available ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 150),
      child: Container(
        width: 104,
        height: 104,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          shape: BoxShape.circle,
        ),
        child: Stack(children: [
          if (_probing)
            const Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)))
          else
            const Center(
                child:
                    Icon(Icons.videocam_rounded, size: 20, color: Colors.white70)),
          _btn(Icons.keyboard_arrow_up_rounded, 0, _speed, Alignment.topCenter),
          _btn(Icons.keyboard_arrow_down_rounded, 0, -_speed,
              Alignment.bottomCenter),
          _btn(Icons.keyboard_arrow_left_rounded, -_speed, 0,
              Alignment.centerLeft),
          _btn(Icons.keyboard_arrow_right_rounded, _speed, 0,
              Alignment.centerRight),
        ]),
      ),
    );
    if (_available || _probing) return pad;
    return Tooltip(
      message: '云台不可用 - 请确认摄像头支持 ONVIF 或萤石本地服务',
      child: pad,
    );
  }

  /// One directional key pinned to an edge of the circular pad; press and
  /// hold is handled by the Listener (repeating ContinuousMove). Each key is
  /// centred on its edge via [Align]: a bare `Positioned(top: …)` pins only
  /// one axis and defaults the other to the start edge, which bunched the
  /// arrows into the corners (箭头位置错乱 2026-10-20).
  Widget _btn(IconData icon, double pan, double tilt, Alignment alignment) {
    final btn = Listener(
      onPointerDown: (_) => _start(pan, tilt),
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: IconButton(
        icon: Icon(icon, size: 18, color: Colors.white),
        onPressed: () {}, // press-and-hold handled by the Listener
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.35),
          minimumSize: const Size(32, 32),
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
    return Align(
      alignment: alignment,
      child: Padding(padding: const EdgeInsets.all(2), child: btn),
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

/// Speaker chip mirroring the global camera mute (persisted in settings,
/// so the last choice survives restarts - 反馈 2026-10-20).
class MuteToggle extends StatelessWidget {
  const MuteToggle({super.key, required this.muted, required this.onToggle});

  final bool muted;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: muted ? '开启声音' : '静音',
        child: InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
                muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                size: 14,
                color: Colors.white),
          ),
        ),
      );
}
