import 'dart:async';
import 'dart:typed_data';

import 'bambu_mjpeg.dart';

/// 机内摄像头只有 **一个** 会话。
///
/// A1/P1 的 :6000 是单客户端服务: 第二条连接进来, 打印机会把前一条踢掉
/// (或者两条都不出帧)。而 App 的画面块和网页端的转码器以前各开一条 ——
/// 于是同一时刻「有的画面黑、有的正常」, 过几分钟又反过来, 表现成随机黑屏,
/// 而且每台都黑得不一样 (反馈 2026-10-26: 123 自带黑、宇树自带正常,
/// 手机端又全都黑)。
///
/// 这里按 `host:port` 共享唯一一条连接: App 和网页都从同一个帧流读,
/// 打印机那边始终只有一条会话。
class BambuMjpegHub {
  BambuMjpegHub({this.factory});

  /// 全局单例。测试可替换 (用完还原)。
  static BambuMjpegHub instance = BambuMjpegHub();

  /// 测试注入: 用假连接代替 TLS :6000。
  final BambuMjpegStream Function({
    required String host,
    required int port,
    required String username,
    required String password,
    required void Function(Uint8List jpeg) onFrame,
    required void Function(String message) onError,
  })? factory;

  final _shared = <String, SharedBambuMjpeg>{};

  BambuMjpegStream _make(SharedBambuMjpeg owner) {
    final f = factory;
    if (f != null) {
      return f(
        host: owner.host,
        port: owner.port,
        username: owner.username,
        password: owner.password,
        onFrame: owner.publish,
        onError: owner.reportError,
      );
    }
    return BambuMjpegStream(
      host: owner.host,
      port: owner.port,
      username: owner.username,
      password: owner.password,
      onFrame: owner.publish,
      onError: owner.reportError,
    );
  }

  /// 取这台摄像头 (host:port) 的共享流。用完必须 [SharedBambuMjpeg.release]。
  SharedBambuMjpeg acquire(
      String host, int port, String username, String password) {
    final key = '$host:$port';
    var s = _shared[key];
    // 访问码改过 (换密码) 就得重建连接, 否则会一直用旧密码被打印机踢。
    if (s != null && s.password != password) {
      s.disposeNow();
      s = null;
    }
    if (s == null) {
      s = SharedBambuMjpeg._(this, key, host, port, username, password);
      _shared[key] = s;
    }
    s.refs++;
    s._ensureSource();
    return s;
  }

  void _drop(String key, SharedBambuMjpeg s) {
    if (identical(_shared[key], s)) _shared.remove(key);
  }
}

/// 一条打印机摄像头连接 + 若干订阅者。
class SharedBambuMjpeg {
  SharedBambuMjpeg._(
      this._hub, this._key, this.host, this.port, this.username, this.password);

  final BambuMjpegHub _hub;
  final String _key;
  final String host;
  final int port;
  final String username;
  final String password;

  final _frames = StreamController<Uint8List>.broadcast();
  final _errors = StreamController<String>.broadcast();

  BambuMjpegStream? _src;
  Timer? _idle;
  bool _dead = false;

  /// 订阅者数量 (App 画面块 + 网页转码器)。
  var refs = 0;

  /// 最近一帧: 新订阅者先画这一帧, 不必等下一帧。
  Uint8List? latest;

  /// 帧号, 诊断用。
  var seq = 0;

  /// 最近一次连接错误 (画面还没出来时的解释)。
  String? error;

  Stream<Uint8List> get frames => _frames.stream;
  Stream<String> get errors => _errors.stream;

  void _ensureSource() {
    _idle?.cancel();
    _idle = null;
    if (_dead || _src != null) return;
    _src = _hub._make(this)..start();
  }

  void publish(Uint8List frame) {
    seq++;
    latest = frame;
    error = null;
    if (!_frames.isClosed) _frames.add(frame);
  }

  void reportError(String message) {
    error = message;
    if (!_errors.isClosed) _errors.add(message);
  }

  void release() {
    refs = (refs - 1).clamp(0, 1 << 30);
    if (refs > 0) return;
    // 宽限几秒再拆: 组件重建/页面来回切时不要把打印机的单会话连接拆了重连。
    _idle ??= Timer(const Duration(seconds: 8), () {
      _idle = null;
      if (refs > 0) return;
      disposeNow();
    });
  }

  void disposeNow() {
    if (_dead) return;
    _dead = true;
    _idle?.cancel();
    _idle = null;
    _src?.dispose();
    _src = null;
    latest = null;
    _frames.close();
    _errors.close();
    _hub._drop(_key, this);
  }
}
