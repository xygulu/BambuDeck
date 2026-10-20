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
import 'log_buffer.dart';
import 'printer_profile.dart';

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
/// ffmpeg).
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

  final _states = <String, (PrinterProfile, BambuState)>{};
  final _clients = <WebSocket>{};
  final _relays = <String, CameraRelay>{};
  HttpServer? _server;

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

  // -- snapshots --------------------------------------------------------

  Map<String, dynamic> _snapshot() => {
        'now': DateTime.now().toIso8601String(),
        'printers': [for (final p in printers) _printerJson(p)],
        'cameras': [for (final c in cameras) _cameraJson(c)],
      };

  Map<String, dynamic> _printerJson(PrinterProfile p) {
    final s = _states[p.id]?.$2;
    return {
      'id': p.id,
      'name': p.name,
      'mode': p.modeLabel,
      if (s != null)
        'state': {
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
          'subtaskName': s.subtaskName,
          'printError': s.printError,
          'hasError': s.hasError,
          if (s.doorOpen != null) 'doorOpen': s.doorOpen,
        },
    };
  }

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
    return {
      'id': c.id,
      'name': c.name,
      'type': c.sourceType.label,
      'enabled': c.enabled,
      if (hasStream && settings.hubToken.isNotEmpty)
        'stream': '/stream/${c.id}?token=${settings.hubToken}',
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
          PrinterProfile? linked;
          if (c.sourceType == CameraSourceType.bambu) {
            for (final p in printers) {
              if (c.printerIds.contains(p.id)) linked = p;
            }
          }
          final url = c.enabled ? c.resolveUrl(linked) : null;
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
