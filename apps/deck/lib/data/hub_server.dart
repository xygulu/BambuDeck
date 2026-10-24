import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_settings.dart';
import 'bambu_mjpeg.dart';
import 'camera_profile.dart';
import 'hub_ptz.dart';
import 'log_buffer.dart';
import 'printer_profile.dart';
import 'rtsp_quality.dart';

/// Asset path of the bundled single-file web client served at `/`.
const kHubPageAsset = 'assets/web/hub_page.html';

/// Splits raw concatenated JPEGs (ffmpeg `-f mjpeg` stdout) into frames.
/// Scans for SOI/EOI markers; bytes before the first SOI and oversize
/// runaways are dropped - a web viewer must never get a torn frame.
class JpegSplitter {
  final _buf = <int>[];
  static const _maxBytes = 8 << 20;

  List<Uint8List> add(List<int> chunk) {
    _buf.addAll(chunk);
    if (_buf.length > _maxBytes) {
      _buf.clear(); // framing lost beyond recovery - start over
      return const [];
    }
    final frames = <Uint8List>[];
    while (true) {
      final soi = _find(const [0xFF, 0xD8], 0);
      if (soi < 0) {
        // No full marker - but a trailing 0xFF may be the first byte of
        // the next SOI, so keep it while flushing the rest.
        if (_buf.isNotEmpty && _buf.last == 0xFF) {
          final keep = _buf.removeLast();
          _buf
            ..clear()
            ..add(keep);
        } else {
          _buf.clear();
        }
        break;
      }
      if (soi > 0) _buf.removeRange(0, soi);
      final eoi = _find(const [0xFF, 0xD9], 2);
      if (eoi < 0) break; // wait for the rest of the frame
      frames.add(Uint8List.fromList(_buf.sublist(0, eoi + 2)));
      _buf.removeRange(0, eoi + 2);
    }
    return frames;
  }

  int _find(List<int> pat, int from) {
    final last = _buf.length - pat.length;
    for (var i = from; i <= last; i++) {
      var hit = true;
      for (var j = 0; j < pat.length; j++) {
        if (_buf[i + j] != pat[j]) {
          hit = false;
          break;
        }
      }
      if (hit) return i;
    }
    return -1;
  }
}

/// ffmpeg candidates, absolute paths first - a GUI-launched macOS app has
/// a minimal PATH, so the bare command would fail there.
String discoverFfmpeg() {
  const candidates = [
    '/opt/homebrew/bin/ffmpeg',
    '/usr/local/bin/ffmpeg',
  ];
  for (final p in candidates) {
    if (File(p).existsSync()) return p;
  }
  return Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
}

/// One live MJPEG source per camera, shared by every web viewer: the
void _noopLog(String message) {}

/// stream is opened when the first client attaches and torn down shortly
/// after the last one leaves (grace period, so a page refresh does not
/// restart ffmpeg).
class CameraRelay {
  CameraRelay({
    required this.camera,
    required this.resolveUrl,
    required this.ffmpegPath,
    void Function(String message)? log,
  }) : _log = log ?? _noopLog;

  final CameraProfile camera;

  /// Re-resolved on every (re)start so profile edits apply live.
  final String? Function() resolveUrl;
  final String ffmpegPath;
  final void Function(String message) _log;

  final _frames = StreamController<Uint8List>.broadcast();
  var clients = 0;
  Uint8List? latest;

  Timer? _stopDelay;
  Timer? _retry;
  BambuMjpegStream? _bambu;
  Process? _proc;
  var _retryDelay = const Duration(seconds: 1);
  bool _disposed = false;

  static const _maxClients = 4;

  bool get saturated => clients >= _maxClients;

  Stream<Uint8List> attach() {
    clients++;
    _stopDelay?.cancel();
    _stopDelay = null;
    _ensureSource();
    return _frames.stream;
  }

  void detach() {
    clients = (clients - 1).clamp(0, 1 << 30);
    if (clients == 0) {
      _stopDelay ??= Timer(const Duration(seconds: 10), _stopSource);
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _stopSource();
    _frames.close();
  }

  void _ensureSource() {
    if (_disposed || _bambu != null || _proc != null || _retry != null) return;
    final url = resolveUrl();
    if (url == null || url.isEmpty) {
      _log('[网页] ${camera.name}: 未配置视频源');
      return;
    }
    if (url.startsWith('bmjpeg://')) {
      final p = parseBambuMjpegUrl(url);
      if (p == null) {
        _log('[网页] ${camera.name}: bmjpeg 地址无法解析');
        return;
      }
      final s = BambuMjpegStream(
        host: p.host,
        port: p.port,
        username: p.username,
        password: p.password,
        onFrame: (f) {
          latest = f;
          _frames.add(f);
        },
        onError: _log,
      );
      _bambu = s;
      s.start(); // reconnects internally, never completes
    } else if (url.startsWith('rtsp')) {
      _log('[网页] ${camera.name}: 网页端开始转码拉流 (${_mask(url)}, '
          'ffmpeg=$ffmpegPath)');
      _runFfmpeg(url);
    } else {
      _log('[网页] ${camera.name}: 不支持的源 ${_mask(url)}');
    }
  }

  /// URLs carry the access code - never write them to the log verbatim.
  static String _mask(String url) => url.replaceFirstMapped(
      RegExp(r'://([^:@/]*):([^@/]*)@'), (m) => '://${m[1]}:***@');

  Future<void> _runFfmpeg(String url) async {
    try {
      final proc = await Process.start(ffmpegPath, [
        '-loglevel', 'error',
        '-rtsp_transport', 'tcp',
        '-i', url,
        '-f', 'mjpeg',
        '-q:v', '5',
        '-',
      ]);
      _proc = proc;
      final splitter = JpegSplitter();
      proc.stdout.listen(
        (chunk) {
          for (final f in splitter.add(chunk)) {
            latest = f;
            _frames.add(f);
          }
        },
        onDone: _sourceDied,
        onError: (_) => _sourceDied(),
        cancelOnError: true,
      );
      // Surface why a source died: keep the first stderr lines and log
      // them when ffmpeg exits (black screen needs a visible reason).
      final stderrTail = <String>[];
      proc.stderr.transform(utf8.decoder).listen((chunk) {
        for (final line in chunk.split('\n')) {
          final l = line.trim();
          if (l.isEmpty) continue;
          if (stderrTail.length < 3) stderrTail.add(l);
        }
      }, onDone: () {
        if (stderrTail.isNotEmpty) {
          _log('[网页] ${camera.name}: ffmpeg 退出 - '
              '${stderrTail.join(' | ')}');
        }
      });
      proc.exitCode.then((code) {
        if (code != 0) {
          _log('[网页] ${camera.name}: ffmpeg 进程退出码 $code');
        }
      });
    } catch (e) {
      _log('[网页] ${camera.name}: ffmpeg 启动失败 $e (检查安装与路径)');
      _sourceDied();
    }
  }

  /// A ffmpeg process exited - retry with backoff while viewers remain.
  void _sourceDied() {
    _proc = null;
    if (_disposed || clients == 0) return;
    _retry ??= Timer(_retryDelay, () {
      _retry = null;
      _retryDelay = _retryDelay * 2 > const Duration(seconds: 10)
          ? const Duration(seconds: 10)
          : _retryDelay * 2;
      _ensureSource();
    });
  }

  void _stopSource() {
    _retry?.cancel();
    _retry = null;
    _bambu?.dispose();
    _bambu = null;
    try {
      _proc?.kill();
    } on ProcessException {
      // already gone
    }
    _proc = null;
    _retryDelay = const Duration(seconds: 1);
  }
}

/// The BambuDeck web hub (服务端和网页端 2026-10-20): an HTTP server inside
/// the app that exposes the already-connected printers' live state and the
/// cameras as a browser-friendly monitoring page. Zero extra dependencies -
/// dart:io's HttpServer/WebSocketTransformer cover everything.
///
/// Auth: every route except the HTML page itself requires `?token=` to
/// match [AppSettings.hubToken] (MJPEG <img> tags cannot set headers, so a
/// query param is the only workable channel).
///
/// Routes: `GET /` page · `GET /api/state` snapshot · `GET /ws` live push ·
/// `GET /stream/{cameraId}` MJPEG (bambu source relayed directly, RTSP via
/// ffmpeg) · `POST /api/control` pause/resume/stop · `POST /api/plate-swap` ·
/// `POST /api/set` speed/light · `POST /api/camera` 画面翻转/旋转/码流/静音 ·
/// `POST /api/ptz` 云台.
///
/// 网页不是 Flutter Web: 它只是本机 app 里这个服务端的另一个前端。真正碰
/// socket / MQTT / Bambu Connect UI 自动化的代码全部留在 app 进程里, 浏览器
/// 只发 HTTP, 所以手机 / 平板 / 另一台电脑都能用。
class HubServer {
  HubServer({
    this.pageHtml,
    Future<HttpServer> Function(InternetAddress, int)? bind,
    String? ffmpegPath,
    void Function(String message)? log,
  })  : _bind = bind ?? HttpServer.bind,
        ffmpegPath = ffmpegPath ?? discoverFfmpeg(),
        _log = log ?? LogBuffer.instance.add;

  String? pageHtml;
  final Future<HttpServer> Function(InternetAddress, int) _bind;
  final String ffmpegPath;
  final void Function(String message) _log;

  /// Synced from the app shell (same pattern as [visionGuard]).
  AppSettings settings = const AppSettings();
  List<PrinterProfile> printers = const [];
  List<CameraProfile> cameras = const [];

  /// Test seam: when set, `/stream/{id}` subscribes here instead of the
  /// managed relays (the returned stream must be broadcast-capable or
  /// single-subscription used once).
  Stream<Uint8List> Function(CameraProfile camera)? relayOverride;

  /// 网页端控制（暂停/继续/停止）的注入点，由 app 外壳接到和 App 内控制按钮
  /// 同一条路由上：dev-ON → LAN MQTT，其余 → Bambu Connect helper。
  /// 返回 {@code {ok, error?, printer?, elapsed?, method?}}。
  Future<Map<String, dynamic>> Function(
      PrinterProfile profile, String command)? controlHandler;

  /// 网页端一键换盘：内嵌 3mf → helper → Connect 派单。
  Future<Map<String, dynamic>> Function(PrinterProfile profile)?
      plateSwapHandler;

  /// 网页端速度档位 / 腔灯：和 App 控制卡一样只走局域网 MQTT 直发。
  Future<Map<String, dynamic>> Function(PrinterProfile profile,
      {int? speed, bool? light})? setHandler;

  /// 打印机连接状态, 让网页卡片和 App 左栏一样能区分「连接中/重连中/错误」。
  /// 注入 [BambuConnStatus.name] 即可, 页面负责翻译。
  String Function(String printerId)? connStatusOf;

  /// 网页改摄像头的显示参数（翻转/旋转/码流）: 写回配置并持久化, 和 App 的
  /// 编辑框改的是同一份数据。
  Future<Map<String, dynamic>> Function(String cameraId,
      {bool? flipH, int? rotationDeg, RtspQuality? quality})? cameraHandler;

  /// 网页静音开关: 写 App 的全局「摄像头静音」(RTSP 音频由 Mac 端播放,
  /// 网页的 MJPEG 本身没有声音)。
  Future<void> Function(bool muted)? muteHandler;

  /// 云台: 网页方向键经这里驱动 ONVIF / HCNetSDK。可注入假客户端测试。
  HubPtz ptz = HubPtz();

  final _states = <String, (PrinterProfile, BambuState)>{};
  final _clients = <WebSocket>{};
  final _relays = <String, CameraRelay>{};
  HttpServer? _server;

  /// 控制串行化：Connect 是 UI 自动化，两个网页同时点会互相踩。
  var _busy = false;

  bool get running => _server != null;
  int get port => _server?.port ?? settings.hubPort;

  /// Called from the connection state listener (~1 Hz per printer).
  void observeState(PrinterProfile profile, BambuState s) {
    _states[profile.id] = (profile, s);
    if (_clients.isNotEmpty) _broadcast();
  }

  Future<void> start() async {
    if (_server != null) return;
    // `?token=` on the page URL is only a handoff - the page stores the
    // token in localStorage and strips it from the address bar.
    pageHtml ??= await rootBundle.loadString(kHubPageAsset);
    try {
      _server = await _bind(InternetAddress.anyIPv4, settings.hubPort);
    } on SocketException catch (e) {
      _log('[网页] 端口 ${settings.hubPort} 无法监听: $e');
      return;
    }
    final srv = _server!;
    _log('[网页] 网页访问已开启: http://0.0.0.0:${srv.port}'
        ' (token 见设置)');
    srv.listen(_handle, onError: (Object e) => _log('[网页] $e'));
  }

  Future<void> stop() async {
    final srv = _server;
    _server = null;
    for (final r in _relays.values) {
      r.dispose();
    }
    _relays.clear();
    ptz.dispose();
    for (final ws in _clients) {
      await ws.close().catchError((_) {});
    }
    _clients.clear();
    await srv?.close(force: true).catchError((_) => srv);
  }

  // -- routing ----------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    try {
      if (path == '/' || path == '/index.html') {
        req.response.headers.contentType = ContentType.html;
        req.response.write(pageHtml ?? 'BambuDeck hub');
        await req.response.close();
        return;
      }
      if (!_checkToken(req)) {
        req.response.statusCode = HttpStatus.unauthorized;
        req.response.write('token 无效(见 app 设置中的访问令牌)');
        await req.response.close();
        return;
      }
      switch (path) {
        case '/api/state':
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(_snapshot()));
          await req.response.close();
        case '/ws':
          final ws = await WebSocketTransformer.upgrade(req);
          _clients.add(ws);
          ws.add(jsonEncode(_snapshot()));
          ws.listen((_) {},
              onDone: () => _clients.remove(ws),
              onError: (_) => _clients.remove(ws));
        case '/api/control':
          await _handleAction(req, plateSwap: false);
        case '/api/plate-swap':
          await _handleAction(req, plateSwap: true);
        case '/api/set':
          await _handleSet(req);
        case '/api/camera':
          await _handleCamera(req);
        case '/api/ptz':
          await _handlePtz(req);
        default:
          final m = RegExp(r'^/stream/([^/]+)$').firstMatch(path);
          if (m != null) {
            await _serveMjpeg(req, m.group(1)!);
          } else {
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          }
      }
    } catch (e) {
      _log('[网页] $path 处理异常: $e');
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  bool _checkToken(HttpRequest req) {
    final t = settings.hubToken;
    return t.isNotEmpty && req.uri.queryParameters['token'] == t;
  }

  // -- actions ----------------------------------------------------------

  /// `POST /api/control {printer, command}` · `POST /api/plate-swap {printer}`.
  ///
  /// 控制命令串行执行（Connect 是 UI 自动化），执行期间再来请求回 409，
  /// 页面据此显示「处理中」。响应体直接透传 handler 的结果。
  Future<void> _handleAction(HttpRequest req, {required bool plateSwap}) async {
    if (req.method != 'POST') {
      await _json(req, HttpStatus.methodNotAllowed, {'ok': false, 'error': '只支持 POST'});
      return;
    }
    Map<String, dynamic> body;
    try {
      final raw = await utf8.decoder.bind(req).join();
      body = raw.trim().isEmpty
          ? const {}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      await _json(req, HttpStatus.badRequest, {'ok': false, 'error': 'body 不是合法 JSON'});
      return;
    }
    final key = (body['printer'] ?? body['printerId'] ?? '').toString();
    final profile = _findPrinter(key);
    if (profile == null) {
      await _json(req, HttpStatus.notFound, {'ok': false, 'error': '没有打印机 $key'});
      return;
    }
    var command = '';
    if (!plateSwap) {
      command = (body['command'] ?? '').toString().toLowerCase();
      if (!const {'pause', 'resume', 'stop'}.contains(command)) {
        await _json(req, HttpStatus.badRequest, {'ok': false, 'error': '未知命令 $command'});
        return;
      }
    }
    if (_busy) {
      await _json(req, HttpStatus.conflict, {
        'ok': false,
        'error': '已有命令在执行，请稍后重试',
      });
      return;
    }
    _busy = true;
    try {
      Map<String, dynamic>? r;
      if (plateSwap) {
        final h = plateSwapHandler;
        if (h == null) {
          await _json(req, HttpStatus.serviceUnavailable,
              {'ok': false, 'error': '换盘功能未接入'});
          return;
        }
        r = await h(profile);
      } else {
        final h = controlHandler;
        if (h == null) {
          await _json(req, HttpStatus.serviceUnavailable,
              {'ok': false, 'error': '控制功能未接入'});
          return;
        }
        r = await h(profile, command);
      }
      await _json(req, HttpStatus.ok, r);
    } catch (e) {
      _log('[网页] ${plateSwap ? '换盘' : command} ${profile.name} 失败: $e');
      await _json(req, HttpStatus.internalServerError, {'ok': false, 'error': '$e'});
    } finally {
      _busy = false;
    }
  }

  /// `POST /api/set {printer, speed?, light?}` —— 速度 1-4 档 / 腔灯开关。
  /// 只走局域网 MQTT（App 里这两项也只接在本机连接上）。
  Future<void> _handleSet(HttpRequest req) async {
    if (req.method != 'POST') {
      await _json(req, HttpStatus.methodNotAllowed, {'ok': false, 'error': '只支持 POST'});
      return;
    }
    Map<String, dynamic> body;
    try {
      final raw = await utf8.decoder.bind(req).join();
      body = raw.trim().isEmpty
          ? const {}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': 'body 不是合法 JSON'});
      return;
    }
    final key = (body['printer'] ?? body['printerId'] ?? '').toString();
    final profile = _findPrinter(key);
    if (profile == null) {
      await _json(req, HttpStatus.notFound,
          {'ok': false, 'error': '没有打印机 $key'});
      return;
    }
    final speedRaw = body['speed'];
    final speed =
        speedRaw is int ? speedRaw : int.tryParse('${speedRaw ?? ''}');
    final lightRaw = body['light'];
    final light = lightRaw is bool
        ? lightRaw
        : lightRaw == 'on'
            ? true
            : lightRaw == 'off'
                ? false
                : null;
    if (speed == null && light == null) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': '缺少 speed(1-4) 或 light(true/false)'});
      return;
    }
    if (speed != null && (speed < 1 || speed > 4)) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': '速度档位只能是 1-4'});
      return;
    }
    final h = setHandler;
    if (h == null) {
      await _json(req, HttpStatus.serviceUnavailable,
          {'ok': false, 'error': '速度/腔灯控制未接入'});
      return;
    }
    try {
      final r = await h(profile, speed: speed, light: light);
      await _json(req, HttpStatus.ok, r);
    } catch (e) {
      _log('[网页] 设置 ${profile.name} 失败: $e');
      await _json(req, HttpStatus.internalServerError,
          {'ok': false, 'error': '$e'});
    }
  }

  /// `POST /api/camera {camera, flipH?, rotation?, quality?, muted?}`
  /// 画面翻转/旋转、主/子码流、全局静音。翻转和旋转只是网页端 CSS 变换,
  /// 但要写回配置让 App 和网页看到同一份朝向; 码流换了 URL, 必须丢掉这个
  /// 摄像头的转码进程, 下一次拉流才会用新地址。
  Future<void> _handleCamera(HttpRequest req) async {
    if (req.method != 'POST') {
      await _json(req, HttpStatus.methodNotAllowed,
          {'ok': false, 'error': '只支持 POST'});
      return;
    }
    final body = await _readBody(req);
    if (body == null) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': 'body 不是合法 JSON'});
      return;
    }
    final key = (body['camera'] ?? body['cameraId'] ?? '').toString();
    final cam = _findCamera(key);
    if (cam == null) {
      await _json(req, HttpStatus.notFound,
          {'ok': false, 'error': '没有摄像头 $key'});
      return;
    }
    final flipRaw = body['flipH'];
    final flipH = flipRaw is bool ? flipRaw : null;
    final rotRaw = body['rotation'];
    final rotation = rotRaw is int ? rotRaw : int.tryParse('${rotRaw ?? ''}');
    if (rotation != null && !const [0, 90, 180, 270].contains(rotation)) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': '旋转角度只能是 0/90/180/270'});
      return;
    }
    final qRaw = body['quality']?.toString();
    final quality = qRaw == null ? null : rtspQualityFromName(qRaw);
    final mutedRaw = body['muted'];
    final muted = mutedRaw is bool ? mutedRaw : null;
    if (flipH == null && rotation == null && quality == null && muted == null) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': '缺少 flipH / rotation / quality / muted'});
      return;
    }
    final result = <String, dynamic>{'ok': true};
    try {
      if (muted != null) {
        final h = muteHandler;
        if (h == null) {
          await _json(req, HttpStatus.serviceUnavailable,
              {'ok': false, 'error': '静音开关未接入'});
          return;
        }
        await h(muted);
        result['muted'] = muted;
      }
      if (flipH != null || rotation != null || quality != null) {
        final h = cameraHandler;
        if (h == null) {
          await _json(req, HttpStatus.serviceUnavailable,
              {'ok': false, 'error': '摄像头设置未接入'});
          return;
        }
        result.addAll(await h(cam.id,
            flipH: flipH, rotationDeg: rotation, quality: quality));
        if (quality != null && quality != cam.quality) {
          // Drop the ffmpeg/bmjpeg relay so the next attach re-resolves the
          // URL. Attached viewers see their stream end; the page reloads it.
          _relays.remove(cam.id)?.dispose();
          _log('[网页] ${cam.name}: 码流切到${quality == RtspQuality.sub ? '子' : '主'}码流');
        }
      }
      await _json(req, HttpStatus.ok, result);
    } catch (e) {
      _log('[网页] 摄像头 ${cam.name} 设置失败: $e');
      await _json(req, HttpStatus.internalServerError,
          {'ok': false, 'error': '$e'});
    }
  }

  /// `POST /api/ptz {camera, action, speed?}` —— 云台方向/停止/探测。
  /// 方向是画面坐标（right/up 为正）, [HubPtz] 负责按摄像头的翻转/旋转
  /// 和方向校准做逆变换, 和 App 的 PtzPad 完全一致。
  Future<void> _handlePtz(HttpRequest req) async {
    if (req.method != 'POST') {
      await _json(req, HttpStatus.methodNotAllowed,
          {'ok': false, 'error': '只支持 POST'});
      return;
    }
    final body = await _readBody(req);
    if (body == null) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': 'body 不是合法 JSON'});
      return;
    }
    final key = (body['camera'] ?? body['cameraId'] ?? '').toString();
    final cam = _findCamera(key);
    if (cam == null) {
      await _json(req, HttpStatus.notFound,
          {'ok': false, 'error': '没有摄像头 $key'});
      return;
    }
    if (!HubPtz.supported(cam)) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': '该摄像头不支持云台(需要 RTSP 地址带账号密码)'});
      return;
    }
    final action = (body['action'] ?? '').toString();
    final speedRaw = body['speed'];
    final speed = (speedRaw is num ? speedRaw.toDouble() : null) ?? HubPtz.speed;
    final step = speed.clamp(0.1, 1.0);
    try {
      final bool ok;
      switch (action) {
        case 'probe':
          ok = await ptz.probe(cam);
        case 'up':
          ok = await ptz.move(cam, pan: 0, tilt: step);
        case 'down':
          ok = await ptz.move(cam, pan: 0, tilt: -step);
        case 'left':
          ok = await ptz.move(cam, pan: -step, tilt: 0);
        case 'right':
          ok = await ptz.move(cam, pan: step, tilt: 0);
        case 'stop':
          await ptz.stop(cam);
          ok = true;
        default:
          await _json(req, HttpStatus.badRequest,
              {'ok': false, 'error': '未知云台动作 $action'});
          return;
      }
      await _json(req, HttpStatus.ok, {'ok': ok, 'available': ok});
    } catch (e) {
      _log('[网页] ${cam.name}: 云台 $action 失败: $e');
      await _json(req, HttpStatus.internalServerError,
          {'ok': false, 'available': false, 'error': '$e'});
    }
  }

  Future<Map<String, dynamic>?> _readBody(HttpRequest req) async {
    try {
      final raw = await utf8.decoder.bind(req).join();
      if (raw.trim().isEmpty) return const {};
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  CameraProfile? _findCamera(String key) {
    if (key.isEmpty) return null;
    for (final c in cameras) {
      if (c.id == key || c.name == key) return c;
    }
    return null;
  }

  PrinterProfile? _findPrinter(String key) {
    if (key.isEmpty) return null;
    for (final p in printers) {
      if (p.id == key || p.name == key || p.serial == key) return p;
    }
    return null;
  }

  Future<void> _json(HttpRequest req, int code, Object body) async {
    req.response.statusCode = code;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  // -- snapshots --------------------------------------------------------

  Map<String, dynamic> _snapshot() => {
        'now': DateTime.now().toIso8601String(),
        'cameraMuted': settings.cameraMuted,
        'printers': [for (final p in printers) _printerJson(p)],
        'cameras': [for (final c in cameras) _cameraJson(c)],
      };

  Map<String, dynamic> _printerJson(PrinterProfile p) {
    final s = _states[p.id]?.$2;
    return {
      'id': p.id,
      'name': p.name,
      'mode': p.modeLabel,
      // 连接状态和 App 左栏卡片同一份: connected/connecting/reconnecting/
      // disconnected/error, 页面翻成中文并决定小圆点颜色。
      'conn': connStatusOf?.call(p.id) ?? (s != null ? 'connected' : 'disconnected'),
      // 和 App 控制卡同一个判断 (profile.autoPlateSwap + lan/cloud): 没勾
      // 「自动换盘」的机器网页上也不能出现换盘按钮。
      'plateSwap': p.autoPlateSwap &&
          (p.mode == PrinterMode.lan || p.mode == PrinterMode.cloud),
      if (s != null) 'state': _stateJson(s),
    };
  }

  Map<String, dynamic> _stateJson(BambuState s) => {
        'gcode': s.gcodeState.label,
        'printing': s.printing,
        if (s.stageLabel(zh: true) != null) 'stage': s.stageLabel(zh: true),
        'progress': s.progress,
        'remainingMinutes': s.remainingMinutes,
        'layerNum': s.layerNum,
        'totalLayers': s.totalLayers,
        'nozzleTemp': s.nozzleTemp,
        'nozzleTarget': s.nozzleTarget,
        'bedTemp': s.bedTemp,
        'bedTarget': s.bedTarget,
        'chamberTemp': s.chamberTemp,
        'subtaskName': s.subtaskName,
        'printError': s.printError,
        // 报错弹窗在没有 HMS 明细时拿它当说明 (App 的 printErrorDescription)。
        if (s.printError != 0 && printErrorDescription(s.printError) != null)
          'printErrorDesc': printErrorDescription(s.printError),
        'hasError': s.hasError,
        'wifi': s.wifiSignal,
        'ip': s.localIp,
        'speedLevel': s.speedLevel,
        'light': s.lightState == 1,
        'stgCur': s.stgCur,
        'fans': {
          'cooling': s.fans.cooling,
          'aux': s.fans.aux,
          'chamber': s.fans.chamber,
        },
        'hms': [
          for (final e in s.hms)
            {
              'code': e.ecode,
              'severity': e.severity.name,
              // 和 App 的报错弹窗同一句说明 (bambu_protocol 的生成表)。
              if (hmsDescription(e) != null) 'desc': hmsDescription(e),
            },
        ],
        'hmsWorst': s.hmsWorstRank,
        if (s.doorOpen != null) 'doorOpen': s.doorOpen,
        if (s.ams != null) 'ams': _amsJson(s.ams!),
      };

  Map<String, dynamic> _amsJson(AmsState a) => {
        if (a.activeTrayId != null) 'activeId': a.activeTrayId,
        if (a.activeTrayIndex != null) 'activeIndex': a.activeTrayIndex,
        'units': [
          for (final u in a.units)
            {
              'id': u.id,
              'humidity': u.humidity,
              'humidityRaw': u.humidityRaw,
              'temp': u.tempC,
              'dry': u.drying,
              'trays': [for (final t in u.trays) _trayJson(t)],
            },
        ],
        if (a.vtTray != null) 'vt': _trayJson(a.vtTray!),
      };

  Map<String, dynamic> _trayJson(AmsTray t) => {
        'present': t.present,
        if (t.colorRrggbb != null)
          'color': '#${t.colorRrggbb!.toRadixString(16).padLeft(6, '0')}',
        'type': t.type,
        'remain': t.remain,
      };

  Map<String, dynamic> _cameraJson(CameraProfile c) {
    String? url;
    if (c.enabled) {
      PrinterProfile? linked;
      if (c.sourceType == CameraSourceType.bambu) {
        for (final p in printers) {
          if (c.printerIds.contains(p.id)) linked = p;
        }
      }
      url = c.resolveUrl(linked);
    }
    final hasStream = url != null && url.isNotEmpty;
    final isRtsp = c.sourceType == CameraSourceType.rtsp;
    return {
      'id': c.id,
      'name': c.name,
      'type': c.sourceType.label,
      'enabled': c.enabled,
      // 右侧详情只显示这台打印机绑定的画面 (和 App 的 CameraWallSection 一致)。
      'printers': c.printerIds,
      if (hasStream && settings.hubToken.isNotEmpty)
        'stream': '/stream/${c.id}?token=${settings.hubToken}',
      // 画面朝向 (App 的 CameraTile 用同一对字段做 Transform)。
      'flipH': c.flipH,
      'rotation': c.rotationDeg,
      // RTSP 摄像头才有 码流/云台/声音 这一套控制 (打印机自带 MJPEG 没有)。
      'rtsp': isRtsp,
      // 云台/码流/声音都只对 RTSP 摄像头成立 (打印机自带画面是 MJPEG 且无音频)。
      if (isRtsp) ...{
        'quality': c.quality.name,
        'canQuality': rtspQualitySwappable(c.url),
        'ptz': HubPtz.supported(c),
        'audio': true,
      },
    };
  }

  // -- mjpeg ------------------------------------------------------------

  Future<void> _serveMjpeg(HttpRequest req, String cameraId) async {
    CameraProfile? cam;
    for (final c in cameras) {
      if (c.id == cameraId) cam = c;
    }
    if (cam == null || !cam.enabled) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('摄像头不存在或已停用');
      await req.response.close();
      return;
    }
    final managed = relayOverride == null ? _relayFor(cam) : null;
    if (managed != null && managed.saturated) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.write('该画面网页端连接数已达上限');
      await req.response.close();
      return;
    }
    final Stream<Uint8List> frames;
    if (relayOverride != null) {
      frames = relayOverride!(cam);
    } else {
      frames = managed!.attach();
    }
    req.response.headers.set(
        'Content-Type', 'multipart/x-mixed-replace; boundary=bambudeck');
    req.response.headers.set('Cache-Control', 'no-cache');
    req.response.bufferOutput = false;
    // dart:io only writes the status line + headers with the first body
    // chunk, so nudge them out with a (legal multipart) preamble CRLF -
    // clients wait for headers before rendering anything.
    req.response.write('\r\n');
    await req.response.flush();

    var open = true;
    void close() {
      if (!open) return;
      open = false;
      managed?.detach();
      req.response.close().catchError((_) => req.response);
    }

    req.response.done.then((_) => close());
    final boundaryHead = ascii.encode('--bambudeck\r\n'
        'Content-Type: image/jpeg\r\nContent-Length: ');
    final blankLine = ascii.encode('\r\n\r\n');
    final tail = ascii.encode('\r\n');

    // First paint from the cached frame, then live ones.
    final first = managed?.latest;
    if (first != null) _emit(req.response, boundaryHead, first, blankLine, tail);
    final sub = frames.listen(
      (frame) {
        if (!open) return;
        _emit(req.response, boundaryHead, frame, blankLine, tail);
      },
      onDone: close,
      onError: (_) => close(),
    );
    await req.response.done.then((_) => sub.cancel());
  }

  void _emit(HttpResponse res, List<int> head, Uint8List frame,
      List<int> blankLine, List<int> tail) {
    try {
      res.add(head);
      res.add(ascii.encode('${frame.length}\r\n\r\n'));
      res.add(frame);
      res.add(tail);
    } catch (_) {
      // client gone - response.done triggers close
    }
  }

  CameraRelay _relayFor(CameraProfile c) {
    return _relays.putIfAbsent(
      c.id,
      () => CameraRelay(
        camera: c,
        resolveUrl: () {
          // Re-read the profile: a web-side 码流/朝向 edit replaces the
          // camera object, and this relay outlives it.
          final cur = _findCamera(c.id) ?? c;
          PrinterProfile? linked;
          if (cur.sourceType == CameraSourceType.bambu) {
            for (final p in printers) {
              if (cur.printerIds.contains(p.id)) linked = p;
            }
          }
          final url = cur.enabled ? cur.resolveUrl(linked) : null;
          return url != null && url.isNotEmpty ? url : null;
        },
        ffmpegPath: ffmpegPath,
        log: _log,
      ),
    );
  }

  // -- ws ---------------------------------------------------------------

  void _broadcast() {
    final text = jsonEncode(_snapshot());
    for (final ws in _clients.toList()) {
      try {
        ws.add(text);
      } catch (_) {
        _clients.remove(ws);
      }
    }
  }
}

/// App-wide hub, wired from the app shell like [visionGuard].
final hubServer = HubServer();

/// Random token for [AppSettings.hubToken] on first enable (16 hex chars).
String generateHubToken() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}
