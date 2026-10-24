/// 摄像头声音开关的广播点。
///
/// 静音本来就是全局设置（[AppSettings.cameraMuted]），但已经在播的 RTSP
/// 画面不会因为设置变了自动改音量 —— App 里是静音按钮自己顺手调了
/// `player.setVolume`。网页端也有同一个按钮（手机在另一个房间时不用回
/// 电脑前），所以这里把「应用静音」这个动作广播给当前所有正在播的摄像头。
class CameraAudioBus {
  final _sinks = <void Function(bool muted)>{};

  /// Called by a live camera player once it is open.
  void attach(void Function(bool muted) apply) => _sinks.add(apply);

  void detach(void Function(bool muted) apply) => _sinks.remove(apply);

  void apply(bool muted) {
    for (final sink in _sinks.toList()) {
      sink(muted);
    }
  }

  /// Tests / hot restart: forget every listener.
  void clear() => _sinks.clear();
}

final cameraAudioBus = CameraAudioBus();
