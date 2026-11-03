import 'ezviz_session.dart';
import 'ptz_client.dart';

/// PTZ over the EZVIZ cloud (萤石开放平台 云台控制 2026-11-03).
///
/// The platform takes a *direction*, not a speed vector: start(direction)
/// keeps the camera moving until stop(direction) with the same direction.
/// [PtzPad] re-issues move() every 250 ms while a key is held, so this client
/// sends start only when the direction changes and ignores the repeats.
class EzvizCloudPtz implements PtzClient {
  EzvizCloudPtz({
    required this.session,
    required this.serial,
    this.channelNo = 1,
    this.speed = 1,
    this.log,
  });

  final EzvizSession session;
  final String serial;
  final int channelNo;

  /// 1..2 for HIK-backed cameras; 0 is rejected by the platform.
  final int speed;
  final void Function(String line)? log;

  int? _direction;
  bool _probed = false;
  bool _available = false;

  @override
  bool get available => _available;

  @override
  Future<bool> probe() async {
    if (_probed) return _available;
    _probed = true;
    if (serial.isEmpty || !session.configured) return _available = false;
    try {
      final info =
          await session.run((t) => session.client.fetchDeviceInfo(t, serial));
      _available = info.online;
      if (!_available) log?.call('[ezviz] 云台: 设备 $serial 不在线');
    } catch (e) {
      log?.call('[ezviz] 云台探测失败: $e');
      _available = false;
    }
    return _available;
  }

  /// Maps a pad vector to the platform direction code. The pad sends
  /// tilt > 0 for 上 and pan < 0 for 左 (see [ptzMove]).
  static int? directionFor({
    double pan = 0,
    double tilt = 0,
    double zoom = 0,
  }) {
    if (zoom > 0) return 8; // 放大
    if (zoom < 0) return 9; // 缩小
    final up = tilt > 0, down = tilt < 0;
    final left = pan < 0, right = pan > 0;
    if (up && left) return 4;
    if (down && left) return 5;
    if (up && right) return 6;
    if (down && right) return 7;
    if (up) return 0;
    if (down) return 1;
    if (left) return 2;
    if (right) return 3;
    return null;
  }

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    final direction = directionFor(pan: pan, tilt: tilt, zoom: zoom);
    if (direction == null) {
      await stop();
      return;
    }
    if (_direction == direction) return; // 250 ms repeat - already moving
    final previous = _direction;
    _direction = direction;
    if (previous != null) await _sendStop(previous);
    await _sendStart(direction);
  }

  @override
  Future<void> stop() async {
    final direction = _direction;
    _direction = null;
    if (direction != null) await _sendStop(direction);
  }

  Future<void> _sendStart(int direction) async {
    try {
      await session.run((t) => session.client
          .ptzStart(t, serial, direction, channelNo: channelNo, speed: speed));
    } catch (e) {
      log?.call('[ezviz] 云台启动失败($direction): $e');
    }
  }

  Future<void> _sendStop(int direction) async {
    try {
      await session.run((t) =>
          session.client.ptzStop(t, serial, direction, channelNo: channelNo));
    } catch (e) {
      log?.call('[ezviz] 云台停止失败($direction): $e');
    }
  }

  @override
  void dispose() {
    // Fire and forget: stopping is best-effort, the pad's release already
    // sent a stop.
    stop();
  }
}
