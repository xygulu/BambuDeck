import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';

import '../core/version.dart';
import 'app_settings.dart';
import 'bambu_mjpeg.dart';
import 'bambu_mjpeg_hub.dart';
import 'camera_profile.dart';
import 'cloud_print_helper.dart';
import 'hub_config.dart';
import 'hub_ptz.dart';
import 'hub_update.dart';
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
/// a minimal PATH, so the bare command would fail there. Windows 部署包把
/// 静态 ffmpeg 放在可执行文件旁边 (GUI: 同目录; deck_hub: ffmpeg/ 子目录,
/// 反馈 2026-10-28:Windows 网页服务第三方摄像头无画面就是缺它), 所以
/// 先认 exe 目录再退回 PATH。
String discoverFfmpeg() {
  final exeDir = Platform.resolvedExecutable.isEmpty
      ? ''
      : File(Platform.resolvedExecutable).parent.path;
  final exeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final candidates = [
    if (exeDir.isNotEmpty) '$exeDir/ffmpeg/$exeName',
    if (exeDir.isNotEmpty) '$exeDir/$exeName',
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

  /// 递增帧号，网页端用它判断画面是不是停了 (见 hub_page.html 的看门狗)。
  var seq = 0;

  Timer? _stopDelay;
  Timer? _retry;
  Timer? _watchdog;
  DateTime? _lastFrameAt;
  /// 机内摄像头走共享连接 (App 画面块也读同一条, 打印机只认一个客户端)。
  SharedBambuMjpeg? _shared;
  StreamSubscription<Uint8List>? _sharedSub;
  StreamSubscription<String>? _sharedErr;
  Process? _proc;
  var _retryDelay = const Duration(seconds: 1);
  bool _disposed = false;

  /// 连续这么久没有一帧就认为拉流卡死。萤石偶发 TCP 半开，ffmpeg 会一直
  /// 等下去不再出帧，原来只有进程退出才重连，于是网页上一直停在最后一帧。
  static const _stallAfter = Duration(seconds: 10);

  var _loggedFirstFrame = false;

  void _publish(Uint8List frame) {
    // dispose() 之后 ffmpeg 的 stdout 还可能再推几块 (kill 是异步的), 往已
    // 关闭的 controller 里 add 会抛「Cannot add new events after calling
    // close」—— 那不是崩溃, 但会以未处理异常的身份冒到日志里 (测试里会
    // 直接判失败)。
    if (_disposed) return;
    seq++;
    _lastFrameAt = DateTime.now();
    latest = frame;
    if (!_loggedFirstFrame) {
      _loggedFirstFrame = true;
      // 画面黑屏时, 日志里有没有这一行就能分清「源没出帧」还是「浏览器不画」。
      _log('[网页] ${camera.name}: 视频源已出帧 '
          '(${(frame.length / 1024).round()} KB)');
    }
    _frames.add(frame);
  }

  /// 每台画面最多给几个网页客户端。手机上一台打印机最多摆两张卡
  /// (墙 + 放大), 3 条够用; 太多会把 Safari 的同源连接名额吃光。
  static const _maxClients = 3;

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

  /// 视频源暂时取不到 (打印机离线 / 刚建好还没配) 时多久再试。
  ///
  /// 不重试的话, 页面会一直挂着一条没有帧的连接, 服务端也永远不再解析源:
  /// 打印机回来以后画面还是黑的, 只能退出重进页面 (反馈 2026-10-25)。
  Duration sourceRetryInterval = const Duration(seconds: 5);
  var _loggedNoSource = false;

  void _ensureSource() {
    if (_disposed || _shared != null || _proc != null || _retry != null) return;
    final url = resolveUrl();
    if (url == null || url.isEmpty) {
      if (!_loggedNoSource) {
        _loggedNoSource = true;
        _log('[网页] ${camera.name}: 还没有可用的视频源, 后台继续重试');
      }
      _retrySource();
      return;
    }
    _loggedNoSource = false;
    if (url.startsWith('bmjpeg://')) {
      final p = parseBambuMjpegUrl(url);
      if (p == null) {
        _log('[网页] ${camera.name}: bmjpeg 地址无法解析');
        return;
      }
      // 和 App 的画面块共用一条打印机连接 —— 自己再开一条会互相踢。
      final s = BambuMjpegHub.instance
          .acquire(p.host, p.port, p.username, p.password);
      _shared = s;
      _sharedSub = s.frames.listen(_publish);
      _sharedErr = s.errors.listen((m) => _log('[网页] ${camera.name}: $m'));
      // 已经有帧就直接用, 网页端不用等下一帧。
      final last = s.latest;
      if (last != null) _publish(last);
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

  /// 拉 RTSP 转 MJPEG 的命令行。
  ///
  /// 读超时是 `-timeout` (rtsp 解复用器自己的选项, 微秒), **不是**
  /// `-rw_timeout`: ffmpeg 8 起 rtsp 不再接受 rw_timeout, 会在连上之前就报
  /// "Option rw_timeout not found" 退出 —— 网页端所有第三方摄像头全黑,
  /// 而 App 里自己的画面是 mpv 拉的, 一切正常, 很容易误判成手机问题
  /// (实测 ffmpeg 8.1.1, 反馈 2026-10-26)。
  static List<String> videoArgs(String url) => [
        '-loglevel', 'error',
        '-rtsp_transport', 'tcp',
        '-timeout', '5000000',
        '-i', url,
        '-an',
        '-f', 'mjpeg',
        '-q:v', '5',
        '-',
      ];

  Future<void> _runFfmpeg(String url) async {
    try {
      final proc = await Process.start(ffmpegPath, videoArgs(url));
      _proc = proc;
      _startWatchdog();
      final splitter = JpegSplitter();
      proc.stdout.listen(
        (chunk) {
          for (final f in splitter.add(chunk)) {
            _publish(f);
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
          // ffmpeg 会把整条 URL (含密码) 打进错误信息, 落日志前先打码。
          if (stderrTail.length < 3) stderrTail.add(_mask(l));
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

  /// 有观众看着却连续 [_stallAfter] 没有新帧, 说明这条流已经死了。杀掉
  /// ffmpeg 让 [_sourceDied] 走正常的退避重连 (重启后网页端不用刷新)。
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed || _proc == null || clients == 0) return;
      final at = _lastFrameAt;
      if (at != null && DateTime.now().difference(at) < _stallAfter) return;
      _log('[网页] ${camera.name}: 画面 ${_stallAfter.inSeconds}s 没有新帧, 重连');
      _lastFrameAt = DateTime.now(); // 避免连发
      try {
        _proc?.kill();
      } on ProcessException {
        // already gone
      }
    });
  }

  /// 源暂时不可用时排一次重试 (只在还有观众时)。不碰 [_retryDelay] ——
  /// 那是 ffmpeg 退出后的退避, 两条路径互不干扰。
  void _retrySource() {
    if (_disposed || clients == 0 || _retry != null) return;
    _retry = Timer(sourceRetryInterval, () {
      _retry = null;
      if (clients > 0) _ensureSource();
    });
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
    _watchdog?.cancel();
    _watchdog = null;
    _lastFrameAt = null;
    _retry?.cancel();
    _retry = null;
    unawaited(_sharedSub?.cancel());
    _sharedSub = null;
    unawaited(_sharedErr?.cancel());
    _sharedErr = null;
    _shared?.release();
    _shared = null;
    _loggedFirstFrame = false;
    try {
      _proc?.kill();
    } on ProcessException {
      // already gone
    }
    _proc = null;
    _retryDelay = const Duration(seconds: 1);
  }
}

/// 网页端的声音: RTSP 转成 MP3, 用 `<audio>` 直接播 (手机浏览器都认)。
///
/// 画面那条流是 MJPEG, 装不了音频, 所以声音要单独再拉一路 RTSP —— 萤石
/// 允许几条并发会话, 换来的是手机在外网也能听见打印机房里的动静。
/// 生命周期和 [CameraRelay] 一样: 第一个观众接入才启动, 最后一个走开
/// 宽限 10 秒后停, 免得刷新页面就重启 ffmpeg。
class AudioRelay {
  AudioRelay({
    required this.camera,
    required this.resolveUrl,
    required this.ffmpegPath,
    void Function(String message)? log,
  }) : _log = log ?? _noopLog;

  final CameraProfile camera;
  final String? Function() resolveUrl;
  final String ffmpegPath;
  final void Function(String message) _log;

  final _chunks = StreamController<Uint8List>.broadcast();
  var clients = 0;

  Timer? _stopDelay;
  Timer? _retry;
  Timer? _watchdog;
  DateTime? _lastDataAt;
  Process? _proc;
  var _retryDelay = const Duration(seconds: 1);
  var _failures = 0;
  bool _disposed = false;

  static const _maxClients = 2;
  static const _stallAfter = Duration(seconds: 10);
  static const _maxFailures = 3;

  bool get saturated => clients >= _maxClients;

  Stream<Uint8List> attach() {
    clients++;
    _stopDelay?.cancel();
    _stopDelay = null;
    _failures = 0; // 新观众再试一次 (上次可能只是摄像头没开)
    _ensureSource();
    return _chunks.stream;
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
    _chunks.close();
  }

  void _ensureSource() {
    if (_disposed || _proc != null || _retry != null) return;
    final url = resolveUrl();
    if (url == null || url.isEmpty) {
      _log('[网页] ${camera.name}: 未配置视频源 (声音)');
      return;
    }
    if (!url.startsWith('rtsp')) return; // 打印机自带画面没有音频
    _log('[网页] ${camera.name}: 开始转码声音 (${CameraRelay._mask(url)})');
    _runFfmpeg(url);
  }

  /// 同画面: 读超时只认 `-timeout` (见 [CameraRelay.videoArgs])。
  static List<String> audioArgs(String url) => [
        '-loglevel', 'error',
        '-rtsp_transport', 'tcp',
        '-timeout', '5000000',
        '-i', url,
        '-vn',
        '-ac', '1',
        '-ar', '44100',
        '-c:a', 'libmp3lame',
        '-b:a', '64k',
        '-flush_packets', '1',
        '-f', 'mp3',
        '-',
      ];

  Future<void> _runFfmpeg(String url) async {
    try {
      final proc = await Process.start(ffmpegPath, audioArgs(url));
      _proc = proc;
      _startWatchdog();
      final errTail = <String>[];
      proc.stderr.transform(utf8.decoder).listen((chunk) {
        for (final line in chunk.split('\n')) {
          final l = line.trim();
          if (l.isNotEmpty && errTail.length < 3) {
            errTail.add(CameraRelay._mask(l));
          }
        }
      }, onDone: () {
        // 摄像头这条码流没声音时 ffmpeg 会立刻退出, 把原因带进日志。
        if (errTail.isNotEmpty) {
          _log('[网页] ${camera.name}: 声音转码退出 - ${errTail.join(' | ')}');
        }
        errTail.clear();
      });
      proc.stdout.listen(
        (chunk) {
          _lastDataAt = DateTime.now();
          if (!_chunks.isClosed) {
            _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
          }
        },
        onDone: _sourceDied,
        onError: (_) => _sourceDied(),
        cancelOnError: true,
      );
      proc.exitCode.then((_) {
        if (_proc == proc) _sourceDied();
      });
    } catch (e) {
      _log('[网页] ${camera.name}: 声音转码启动失败 $e');
      _sourceDied();
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed || _proc == null || clients == 0) return;
      final at = _lastDataAt;
      if (at != null && DateTime.now().difference(at) < _stallAfter) return;
      _log('[网页] ${camera.name}: 声音 ${_stallAfter.inSeconds}s 没有数据, 重连');
      _lastDataAt = DateTime.now();
      try {
        _proc?.kill();
      } on ProcessException {
        // already gone
      }
    });
  }

  void _sourceDied() {
    _proc = null;
    _watchdog?.cancel();
    _watchdog = null;
    if (_disposed || clients == 0) return;
    _failures++;
    if (_failures >= _maxFailures) {
      // 连不上/没有音轨: 别无限重启, 等下一次有人重新点开再试。
      _log('[网页] ${camera.name}: 连续 $_failures 次拿不到声音, 暂停重试');
      return;
    }
    _retry ??= Timer(_retryDelay, () {
      _retry = null;
      _retryDelay = _retryDelay * 2 > const Duration(seconds: 10)
          ? const Duration(seconds: 10)
          : _retryDelay * 2;
      _ensureSource();
    });
  }

  void _stopSource() {
    _watchdog?.cancel();
    _watchdog = null;
    _retry?.cancel();
    _retry = null;
    _lastDataAt = null;
    _failures = 0;
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

  /// Injected page loader: the Flutter app reads the bundled asset via
  /// `rootBundle`, the standalone web service reads the .html off disk.
  /// null = serve the `BambuDeck hub` placeholder.
  Future<String> Function()? pageLoader;

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

  /// 一条长连接 (画面/声音) 的写入卡住多久就断定客户端已经走了。
  ///
  /// iOS 锁屏/切后台再回来时, 旧 socket 常常既不读也不关 (半死连接):
  /// 我们这边 flush 永远等不到, 也就永远收不到 `response.done`, relay 的
  /// `clients` 只增不减。攒满上限之后新连接都被挡, 页面一直裂图。
  ///
  /// 6s: 页面重挂的间隔是 3s, 留一倍余量就够; 15s 太久了 —— 手机的同源连接
  /// 名额 (6 条) 被半死连接占着时, 整页都加载不出来 (反馈 2026-10-26)。
  /// 现在还有「满了踢最老的」兜底 (见 [_streamClients])。测试里会调小。
  Duration streamStallTimeout = const Duration(seconds: 6);

  /// Test seam: [relayOverride] 绕过了托管的 relay, 测试靠这个钩子确认
  /// 「卡住的观众把名额还回来了」。
  void Function(CameraProfile camera)? onStreamReleased;

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

  /// 网页静音开关: 写 App 的全局「摄像头静音」。App 里正在播的画面音量
  /// 立刻跟着变; 网页端自己那一路 `<audio>` 也按这个开关启停。
  Future<void> Function(bool muted)? muteHandler;

  /// 云账号管理（产品化 2026-10-28）：登录向导 / 账号列表 / 暂定与退出。
  /// 由独立 deck_hub 的 HubService 接线；App 内嵌网页服务暂不注入（端点回
  /// 503，页面提示独立服务才提供）。登录成功即同步设备并落盘，打印机清单
  /// 从此跟随云端账号。
  Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      cloudLoginHandler;
  Future<Map<String, dynamic>> Function()? accountsHandler;
  Future<Map<String, dynamic>> Function(Map<String, dynamic> body)?
      accountUpdateHandler;

  /// 登录账号清单（快照用，不含 token）。同步状态在 HubService 的内存里，
  /// 页面要详情时走 GET /api/accounts。
  List<CloudAccount> accounts = const [];

  /// 服务状态 (2026-10-27): `/api/health` 会 GET 这条公网地址, 走 CF 边缘
  /// 进隧道再回本机, 一发探测整条链路。空 = 跳过隧道项 (App 内置网页服务
  /// 不注入; 独立 deck_hub 由 bin/hub.dart 按环境变量 HUB_TUNNEL_URL 给)。
  String tunnelProbeUrl = '';

  /// cloudflared 在 Windows 上跑成系统服务 (token 模式的 "Cloudflared
  /// agent"), pgrep 不存在 —— 配了服务名就走 `sc query`, 否则按进程名兜底。
  /// macOS 忽略此字段, 沿用 pgrep。(2026-10-29, 检测改配置驱动: 每台机器
  /// 在 hub.json settings.cloudflaredService 里写自己的服务名。)
  String cloudflaredServiceName = '';

  DateTime? _startedAt;

  /// 云台: 网页方向键经这里驱动 ONVIF / HCNetSDK。可注入假客户端测试。
  HubPtz ptz = HubPtz();

  final _states = <String, (PrinterProfile, BambuState)>{};
  final _clients = <WebSocket>{};
  final _relays = <String, CameraRelay>{};
  final _audioRelays = <String, AudioRelay>{};
  HttpServer? _server;
  Timer? _heartbeat;

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
    final load = pageLoader;
    if (pageHtml == null && load != null) {
      try {
        pageHtml = await load();
      } catch (e) {
        _log('[网页] 页面加载失败: $e');
      }
    }
    try {
      _server = await _bind(InternetAddress.anyIPv4, settings.hubPort);
    } on SocketException catch (e) {
      _log('[网页] 端口 ${settings.hubPort} 无法监听: $e');
      return;
    }
    final srv = _server!;
    _startedAt ??= DateTime.now();
    _log('[网页] 网页访问已开启: http://0.0.0.0:${srv.port}'
        ' (token 见设置)');
    srv.listen(_handle, onError: (Object e) => _log('[网页] $e'));
    // 没有打印机在推送时也要有消息: 页面的卡流看门狗靠它拿到新的帧号,
    // 空闲的 WebSocket 也容易被系统/路由悄悄掐掉。
    _heartbeat ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (_clients.isNotEmpty) _broadcast();
    });
    _startUpdateLoop();
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _updateTimer?.cancel();
    _updateTimer = null;
    final srv = _server;
    _server = null;
    for (final r in _relays.values) {
      r.dispose();
    }
    _relays.clear();
    for (final r in _audioRelays.values) {
      r.dispose();
    }
    _audioRelays.clear();
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
        // 页面是打在 App 包里的, 每次重启 App 都可能换了一版; 不加这个
        // iOS Safari (尤其是「添加到主屏幕」的独立窗口) 会拿缓存里的旧页面,
        // 用户看不到修复, 还以为没生效 (反馈 2026-10-26)。
        req.response.headers.set('Cache-Control', 'no-cache, max-age=0');
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
        case '/ws-cam':
          await _serveFrames(req);
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
        case '/api/health':
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(await _healthSnapshot()));
          await req.response.close();
        case '/api/cloud/login':
          await _handleCloudLogin(req);
        case '/api/cloud/send-code':
          await _handleCloudSendCode(req);
        case '/api/accounts':
          await _handleAccounts(req);
        case '/api/account':
          await _handleAccountUpdate(req);
        case '/api/update':
          await _handleUpdate(req);
        default:
          final m = RegExp(r'^/stream/([^/]+)$').firstMatch(path);
          final am = RegExp(r'^/audio/([^/]+)$').firstMatch(path);
          if (m != null) {
            await _serveMjpeg(req, m.group(1)!);
          } else if (am != null) {
            await _serveAudio(req, am.group(1)!);
          } else {
            // 404 必须带 JSON body: 网页端 fetch().json() 解析空 body 会抛
            // SyntaxError (2026-10-29 iOS 反馈; 旧二进制没有 /api/update
            // 路由时就走到了这), 报「HTTP 404」才是人话。
            req.response.statusCode = HttpStatus.notFound;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(
                {'ok': false, 'error': '接口不存在: $path'}));
            await req.response.close();
          }
      }
    } catch (e) {
      _log('[网页] $path 处理异常: $e');
      try {
        // 响应还没写过就补一个 JSON 500 (写过会 throw, 忽略即可);
        // 空 body = 网页端 json() 的 SyntaxError。
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': false, 'error': '$e'}));
      } catch (_) {}
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  bool _checkToken(HttpRequest req) {
    final t = settings.hubToken;
    return t.isNotEmpty && req.uri.queryParameters['token'] == t;
  }

  // -- health (服务状态 2026-10-27) ---------------------------------------
  //
  // 四项自检给网页端的「服务」chip: hub 自身 / 控制 helper / cloudflared
  // 进程 / 隧道全链路。token 鉴权与 /api/state 相同。数值字段机器读,
  // detail 是稳定枚举串, 中文展示由页面翻译。三项探测并发跑, 总耗时 =
  // 最慢一项; 每项都有界, 接口最迟 ~6s 必答。

  Future<Map<String, dynamic>> _healthSnapshot() async {
    final results = await Future.wait([
      _checkHelper(),
      _checkCloudflared(),
      _checkTunnel(),
    ]);
    final up = _startedAt;
    return <String, dynamic>{
      // hub 用运行时版本 (AOT 包读包根 version.txt), App 里两者相同
      'version': deckVersionRuntime,
      'platform': Platform.operatingSystem,
      // 候选端点 (2026-10-29): 手机/电脑可以用这些地址连上这台 hub ——
      // 局域网地址在前 (同网段直连最快), 隧道地址兜底 (不在同网段也能连)。
      // 网页端会挨个探测, 取响应最快的那个 (局域网优先 + 隧道兜底)。
      'endpoints': await _candidateEndpoints(),
      'hub': <String, dynamic>{
        'ok': true,
        if (up != null) 'uptimeSec': DateTime.now().difference(up).inSeconds,
      },
      'helper': results[0],
      'cloudflared': results[1],
      'tunnel': results[2],
    };
  }

  /// 本机所有 IPv4 地址 (http://ip:端口) + 隧道地址。
  /// 环回地址不算 (外部连不到), 隧道地址来自 hub.local.json 的
  /// tunnelProbeUrl (每台机器绑自己的域名)。
  Future<List<String>> _candidateEndpoints() async {
    final out = <String>[];
    final port = settings.hubPort;
    try {
      final ifaces = await NetworkInterface.list();
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (a.type == InternetAddressType.IPv4 && !a.isLoopback) {
            final u = 'http://${a.address}:$port';
            if (!out.contains(u)) out.add(u);
          }
        }
      }
    } catch (_) {}
    final t = tunnelProbeUrl.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
    return out;
  }

  Future<Map<String, dynamic>> _checkHelper() async {
    try {
      final ok = await CloudPrintHelper.instance
          .health()
          .timeout(const Duration(seconds: 6));
      return {'ok': ok, 'detail': ok ? 'online' : 'no_response'};
    } catch (_) {
      return {'ok': false, 'detail': 'no_response'};
    }
  }

  // -- 自更新 (2026-10-29) ------------------------------------------------
  //
  // GET  /api/update            当前版 + 最新版 + 更新说明 (带缓存)。
  // POST /api/update {action}   check=强制重查; apply=Windows 暂存后 3s
  //                             以 42 退出, 守护循环 apply-update.ps1 换装。
  //                             其它平台 apply 直接拒绝 (fail-closed)。
  bool _exiting = false;

  // -- 自动检查 (2026-10-30): 启动后 45s 查一次, 之后每 6h; GitHub 被断是
  // 常态时段, 失败静默等下一轮。结果进 _snapshot() 推给页面常驻提示,
  // 换装本身仍要点「立即更新」—— 检查自动、安装人工确认。
  Timer? _updateTimer;
  Map<String, dynamic>? _updateInfo;

  void _startUpdateLoop() {
    _updateTimer?.cancel();
    _updateTimer = Timer(const Duration(seconds: 45), _autoCheckUpdate);
  }

  Future<void> _autoCheckUpdate() async {
    try {
      final c = await HubUpdater.check(force: true);
      final changed = _updateInfo == null ||
          _updateInfo!['latest'] != c['latest'] ||
          _updateInfo!['hasUpdate'] != c['hasUpdate'];
      _updateInfo = c;
      if (changed && _clients.isNotEmpty) _broadcast();
    } catch (_) {}
    _updateTimer = Timer(const Duration(hours: 6), _autoCheckUpdate);
  }

  Future<void> _handleUpdate(HttpRequest req) async {
    req.response.headers.contentType = ContentType.json;
    try {
      if (req.method == 'GET') {
        final c = await HubUpdater.check();
        req.response.write(jsonEncode({
          'version': c['current'],
          'latest': c['latest'],
          'notes': c['notes'],
          'hasUpdate': c['hasUpdate'],
          'checkedAt': c['checkedAt'],
          'releaseUrl': c['releaseUrl'],
          'platform': Platform.operatingSystem,
        }));
      } else if (req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        final action =
            (jsonDecode(body) as Map)['action']?.toString() ?? '';
        if (_exiting) {
          req.response.write(
              jsonEncode({'ok': false, 'error': '正在退出换装, 请稍等重启'}));
        } else if (action == 'check') {
          final c = await HubUpdater.check(force: true);
          req.response.write(jsonEncode({
            'ok': true,
            'latest': c['latest'],
            'hasUpdate': c['hasUpdate'],
            'notes': c['notes'],
            'releaseUrl': c['releaseUrl'],
          }));
        } else if (action == 'apply') {
          await HubUpdater.stage();
          _exiting = true;
          req.response.write(jsonEncode({'ok': true, 'staged': true}));
          // 响应先落地, 再 42 退出让守护脚本换装 (run-hub.cmd)。
          HubUpdater.exitForSwap();
        } else {
          req.response.statusCode = HttpStatus.badRequest;
          req.response.write(
              jsonEncode({'ok': false, 'error': '未知 action: $action'}));
        }
      } else {
        req.response.statusCode = HttpStatus.methodNotAllowed;
      }
    } catch (e) {
      if (!_exiting) {
        req.response.write(jsonEncode({'ok': false, 'error': '$e'}));
      }
    }
    await req.response.close();
  }

  Future<Map<String, dynamic>> _checkCloudflared() async {
    // Windows: pgrep 不存在 (曾因此永远 unknown, 2026-10-29 实测)。cloudflared
    // 以系统服务跑 (token 模式), 配了服务名用 `sc query` 看状态最准; 没配就
    // 按进程名 tasklist 兜底。服务状态是稳定态, 单次采样即可。
    if (Platform.isWindows) {
      Future<bool> once() async {
        final name = cloudflaredServiceName.trim();
        if (name.isNotEmpty) {
          final r = await Process.run('sc', <String>['query', name])
              .timeout(const Duration(seconds: 3));
          return r.exitCode == 0 && (r.stdout as String).contains('RUNNING');
        }
        final r = await Process.run(
                'tasklist', <String>['/fi', 'imagename eq cloudflared.exe'])
            .timeout(const Duration(seconds: 3));
        return r.exitCode == 0 &&
            (r.stdout as String).contains('cloudflared.exe');
      }

      try {
        final ok = await once();
        return <String, dynamic>{
          'ok': ok,
          'detail': ok ? 'running' : 'stopped',
          'service': cloudflaredServiceName.trim().isNotEmpty
              ? cloudflaredServiceName.trim()
              : 'cloudflared.exe',
        };
      } catch (_) {
        return {'ok': null, 'detail': 'unknown'};
      }
    }
    // 单次 pgrep 会把 KeepAlive 崩溃循环里的瞬时进程误判成「运行中」
    // (每 5s 拉起、秒退), 芯片就忽绿忽红。隔 1.5s 采两次, 两次都在才算
    // 稳定运行; 第一次就不在直接判停。
    Future<bool> once() async {
      final r = await Process.run('pgrep', const <String>['-x', 'cloudflared'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    }

    try {
      final a = await once();
      if (!a) return {'ok': false, 'detail': 'stopped'};
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final b = await once();
      return {'ok': b, 'detail': b ? 'running' : 'stopped'};
    } catch (_) {
      // 非 macOS/Unix 或 pgrep 不可用 (App 内置服务也可能跑在 Windows)。
      return {'ok': null, 'detail': 'unknown'};
    }
  }

  Future<Map<String, dynamic>> _checkTunnel() async {
    if (tunnelProbeUrl.isEmpty) {
      return {'ok': null, 'detail': 'not_configured'};
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(Uri.parse(tunnelProbeUrl))
          .timeout(const Duration(seconds: 6));
      final res = await req.close().timeout(const Duration(seconds: 6));
      final code = res.statusCode;
      await res.drain<void>().timeout(const Duration(seconds: 2));
      final ok = code >= 200 && code < 300;
      return {'ok': ok, 'detail': 'http_$code', 'url': tunnelProbeUrl};
    } catch (_) {
      return {'ok': false, 'detail': 'unreachable', 'url': tunnelProbeUrl};
    } finally {
      client.close(force: true);
    }
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
          _audioRelays.remove(cam.id)?.dispose();
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

  // -- 云账号（产品化 2026-10-28） ----------------------------------------
  //
  // 薄路由：登录/列表/暂定退出都委托 HubService 注入的 handler（它们要动
  // 配置与同步引擎）；发验证码是纯协议调用，这里直接做。

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest req) async {
    if (req.method != 'POST') {
      await _json(req, HttpStatus.methodNotAllowed,
          {'ok': false, 'error': '只支持 POST'});
      return null;
    }
    try {
      final raw = await utf8.decoder.bind(req).join();
      return raw.trim().isEmpty
          ? const {}
          : (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      await _json(req, HttpStatus.badRequest,
          {'ok': false, 'error': 'body 不是合法 JSON'});
      return null;
    }
  }

  /// `POST /api/cloud/login {region, account, password|code}` —— 网页登录
  /// 向导的提交口。成功即同步设备并落盘（mtime 重启生效），响应带设备清单
  /// （不含访问码）给向导展示。业务失败回 200 + ok:false，页面负责展示。
  Future<void> _handleCloudLogin(HttpRequest req) async {
    final body = await _readJsonBody(req);
    if (body == null) return;
    final h = cloudLoginHandler;
    if (h == null) {
      await _json(req, HttpStatus.serviceUnavailable, {
        'ok': false,
        'error': '云登录未接入（独立网页服务 deck_hub 才提供）',
      });
      return;
    }
    await _json(req, HttpStatus.ok, await h(body));
  }

  /// `POST /api/cloud/send-code {region, account}` —— 邮箱/短信登录验证码。
  Future<void> _handleCloudSendCode(HttpRequest req) async {
    final body = await _readJsonBody(req);
    if (body == null) return;
    final account = (body['account'] ?? '').toString().trim();
    if (account.isEmpty) {
      await _json(req, HttpStatus.ok, {'ok': false, 'error': '请先输入账号'});
      return;
    }
    final regionName = (body['region'] ?? 'cn').toString().trim();
    final CloudRegion region;
    try {
      region = CloudRegion.values.byName(regionName);
    } catch (_) {
      await _json(
          req, HttpStatus.ok, {'ok': false, 'error': '未知区域 $regionName'});
      return;
    }
    try {
      await cloudSendLoginCode(region: region, account: account)
          .timeout(const Duration(seconds: 25));
      await _json(req, HttpStatus.ok, {'ok': true});
    } catch (e) {
      await _json(req, HttpStatus.ok, {'ok': false, 'error': '$e'});
    }
  }

  /// `GET /api/accounts` —— 账号列表 + 最近同步状态。
  Future<void> _handleAccounts(HttpRequest req) async {
    if (req.method != 'GET') {
      await _json(req, HttpStatus.methodNotAllowed,
          {'ok': false, 'error': '只支持 GET'});
      return;
    }
    final h = accountsHandler;
    if (h == null) {
      await _json(req, HttpStatus.serviceUnavailable,
          {'ok': false, 'error': '账号管理未接入（独立网页服务才提供）'});
      return;
    }
    await _json(req, HttpStatus.ok, await h());
  }

  /// `POST /api/account {id, action: suspend|resume|logout}`。
  Future<void> _handleAccountUpdate(HttpRequest req) async {
    final body = await _readJsonBody(req);
    if (body == null) return;
    final h = accountUpdateHandler;
    if (h == null) {
      await _json(req, HttpStatus.serviceUnavailable,
          {'ok': false, 'error': '账号管理未接入（独立网页服务才提供）'});
      return;
    }
    await _json(req, HttpStatus.ok, await h(body));
  }

  // -- snapshots --------------------------------------------------------

  Map<String, dynamic> _snapshot() => {
        'now': DateTime.now().toIso8601String(),
        'cameraMuted': settings.cameraMuted,
        'printers': [for (final p in printers) _printerJson(p)],
        'cameras': [for (final c in cameras) _cameraJson(c)],
        // 这个服务端有没有接云登录后端。App 内嵌的服务端没接（登录在 App 自己的
        // UI 里做），页面据此决定首屏要不要弹登录向导 —— 否则 App 用户刚打开
        // 页面就看到一个必然失败的向导。
        'cloudLogin': cloudLoginHandler != null,
        // 登录账号（脱敏，无 token）：页面据此判断「首次启动」弹登录向导，
        // 用户管理面板要同步详情时再走 GET /api/accounts。
        'accounts': [
          for (final a in accounts)
            {
              'id': a.id,
              'account': a.account,
              'region': a.region.name,
              'suspended': a.suspended,
            },
        ],
        // 自动检查的最新版结论 (没有就是还没查到过): 页面据此常驻提示
        if (_updateInfo != null)
          'update': {
            'current': _updateInfo!['current'],
            'latest': _updateInfo!['latest'],
            'hasUpdate': _updateInfo!['hasUpdate'],
            'checkedAt': _updateInfo!['checkedAt'],
          },
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
      // RTSP 摄像头的声音单独一路 (MP3), 网页用 <audio> 播。
      if (hasStream && isRtsp && settings.hubToken.isNotEmpty)
        'audioStream': '/audio/${c.id}?token=${settings.hubToken}',
      // 已拉流时带上帧号: 网页据此判断画面是不是卡住了。
      'seq': _relays[c.id]?.seq ?? 0,
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

  /// 谁来连了画面: 手机端黑屏时, 这条日志能分清「请求根本没到服务端」
  /// (iOS 并发连接被占满 / 走错地址) 和「到了但浏览器不画」。页面重挂会
  /// 反复连, 每台摄像头 5 秒只记一次。
  final _attachLoggedAt = <String, DateTime>{};
  void _logAttach(CameraProfile cam, HttpRequest req) {
    final now = DateTime.now();
    final last = _attachLoggedAt[cam.id];
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _attachLoggedAt[cam.id] = now;
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
    final ua = (req.headers.value('user-agent') ?? '?').trim();
    final who = ua.length > 40 ? '${ua.substring(0, 40)}…' : ua;
    _log('[网页] ${cam.name}: 画面请求 $remote ($who)');
  }

  /// 连接数打满只记一次: 页面每几秒重试一次, 不节流日志会被刷屏。
  final _saturatedLoggedAt = <String, DateTime>{};
  void _logSaturated(
      String what, CameraProfile cam, int clients, int max) {
    final now = DateTime.now();
    final key = '${cam.id}/$what';
    final last = _saturatedLoggedAt[key];
    if (last != null && now.difference(last) < const Duration(seconds: 30)) {
      return;
    }
    _saturatedLoggedAt[key] = now;
    _log('[网页] ${cam.name}: $what连接数已满 ($clients/$max), 拒绝新连接'
        ' —— 不读数据的连接应在 ${streamStallTimeout.inSeconds}s 内被回收');
  }

  /// 每次挂流都登记一个回收器: 名额满了就踢最老的那条。
  ///
  /// 手机 Safari 每站只给 6 条 HTTP 连接, 用满以后旧连接既不读也不关 (半死);
  /// 只「拒绝新连接」的话页面会一直卡在「连接数已满」—— 表现是整页摄像头全黑,
  /// 等 15s 回收也未必来得及 (反馈 2026-10-26)。新请求显然代表「现在要看」,
  /// 所以让新连接赢: 先断最老的, 再挂新的。
  final _streamClients = <String, List<void Function()>>{};

  /// 全站当前挂着的画面流条数。手机黑屏时看这一行: 页面只挂 1~2 张,
  /// 这里却在涨, 说明浏览器那边 `src` 摘了但连接没关 (2026-10-26)。
  int get _attachedCount =>
      _streamClients.values.fold(0, (sum, l) => sum + l.length);

  void _logEvicted(String camera, int kept) {
    final now = DateTime.now();
    final last = _saturatedLoggedAt['$camera/evict'];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _saturatedLoggedAt['$camera/evict'] = now;
    _log('[网页] $camera: 画面连接已满, 断开最老的一条给新连接'
        ' (剩 $kept 条) —— 反复出现说明页面在重复挂同一条流');
  }

  /// 能强关的流式响应 (画面 / 声音共用)。
  ///
  /// 为什么不用 `HttpResponse`: 客户端不读的时候 `flush()` 会一直挂着, 这时
  /// `close()` 抛 "StreamSink is bound to a stream", 而 `detachSocket()` 又
  /// 因为「头已发出」直接拒绝 —— 两条路都不通, 那条 TCP 就永远 ESTABLISHED。
  /// 手机经 Cloudflare 隧道来时后果最重: 边缘那条 HTTP/2 流永远结束不了,
  /// 连接级流控窗口被它吃光, 别的画面跟着一起黑, 只有重启 App 才恢复
  /// (2026-10-26 实测: cloudflared 侧积压 ~1MB 后不再读 origin)。
  ///
  /// 所以在写任何字节之前就把 socket 摘下来, HTTP 头自己写 (靠
  /// `Connection: close` 定 body 长度), 卡住就 `destroy()` —— RST 立刻生效,
  /// 隧道那头看到的是干净的 EOF 而不是半截 chunk。
  ///
  /// 探针: /tmp/deck_probe/raw_stream.dart (ffmpeg 能解码; 不读的客户端在
  /// destroy 后连接立即消失)。
  Future<void> _serveMjpeg(HttpRequest req, String cameraId) async {
    CameraProfile? cam;
    for (final c in cameras) {
      if (c.id == cameraId) cam = c;
    }
    if (cam != null) _logAttach(cam, req);
    if (cam == null || !cam.enabled) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('摄像头不存在或已停用');
      await req.response.close();
      return;
    }
    final camera = cam;
    final managed = relayOverride == null ? _relayFor(camera) : null;
    // 名额满了先踢最老的半死连接 (见 [_streamClients])。
    final mine = managed == null
        ? null
        : _streamClients.putIfAbsent(camera.id, () => <void Function()>[]);
    if (managed != null && mine != null) {
      while (managed.saturated && mine.isNotEmpty) {
        final oldest = mine.removeAt(0);
        _logEvicted(camera.name, mine.length);
        oldest();
      }
      if (managed.saturated) {
        _logSaturated('画面', camera, managed.clients, CameraRelay._maxClients);
        req.response.statusCode = HttpStatus.serviceUnavailable;
        req.response.write('该画面网页端连接数已达上限');
        await req.response.close();
        return;
      }
    }
    final Stream<Uint8List> frames;
    if (relayOverride != null) {
      frames = relayOverride!(camera);
    } else {
      frames = managed!.attach();
    }
    // 头 + body 都走自己摘下来的 socket (见 [_RawStream]): 这样卡死时能真关。
    final raw = await _RawStream.open(
        req, 'multipart/x-mixed-replace; boundary=bambudeck');
    if (raw == null) {
      _log('[网页] ${camera.name}: 摘不到 socket, 这条画面放弃');
      managed?.detach();
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
      return;
    }

    var open = true;
    var busy = false;
    StreamSubscription<Uint8List>? sub;
    Timer? stalled;

    // 断开并归还名额 (只做一次)。这次能真关: raw.close() 直接 destroy 底层
    // socket, 不像 HttpResponse.close() 那样被挂着的 flush 卡住。
    void release() {
      if (!open) return;
      open = false;
      busy = false;
      stalled?.cancel();
      stalled = null;
      managed?.detach();
      mine?.remove(release);
      raw.close();
      _log('[网页] ${camera.name}: 画面断开 (全站剩 $_attachedCount 条)');
      onStreamReleased?.call(camera);
      unawaited(sub?.cancel());
    }

    mine?.add(release);
    _log('[网页] ${camera.name}: 画面挂上 (全站 $_attachedCount 条)');
    unawaited(raw.done.then((_) => release()));

    final boundaryHead = ascii.encode('--bambudeck\r\n'
        'Content-Type: image/jpeg\r\nContent-Length: ');
    final tail = ascii.encode('\r\n');

    // First paint from the cached frame, then live ones. The `busy` flag is
    // backpressure: a phone that locked the screen often keeps the socket
    // open without reading, and writing every frame would balloon the
    // response buffer and hand the client minutes of stale video when it
    // comes back. Drop frames while the last flush is still pending.
    //
    // 但「等不到 flush」不能无限等: 客户端彻底不读了就断开回收 (见
    // [streamStallTimeout])。否则名额被半死连接占死, 隧道那头也跟着堵。
    void push(Uint8List frame) {
      if (!open || busy) return;
      busy = true;
      stalled?.cancel();
      stalled = Timer(streamStallTimeout, () {
        if (!open) return;
        _log('[网页] ${camera.name}: 画面连接 '
            '${streamStallTimeout.inSeconds}s 写不出去 (客户端不读了), 断开回收');
        release();
      });
      raw.write([
        boundaryHead,
        ascii.encode('${frame.length}\r\n\r\n'),
        frame,
        tail,
      ]).then((ok) {
        busy = false;
        stalled?.cancel();
        stalled = null;
        if (!ok) release(); // socket 没了
      });
    }

    final first = managed?.latest;
    if (first != null) push(first);
    sub = frames.listen(
      push,
      onDone: release,
      onError: (_) => release(),
    );
    await raw.done;
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

  /// `GET /audio/{cameraId}` — 摄像头声音, MP3 长流。
  ///
  /// 浏览器拿 `<audio src>` 直接播; 手机锁屏/切后台时连接会被系统掐掉,
  /// 页面回到前台会重新挂 (见 hub_page.html 的 syncWalls)。
  Future<void> _serveAudio(HttpRequest req, String cameraId) async {
    final cam = _findCamera(cameraId);
    if (cam == null || !cam.enabled) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('摄像头不存在或已停用');
      await req.response.close();
      return;
    }
    if (cam.sourceType != CameraSourceType.rtsp) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('这台摄像头没有声音');
      await req.response.close();
      return;
    }
    final relay = _audioRelayFor(cam);
    if (relay.saturated) {
      _logSaturated('声音', cam, relay.clients, AudioRelay._maxClients);
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.write('该画面声音连接数已达上限');
      await req.response.close();
      return;
    }
    final chunks = relay.attach();
    // 同画面: 自己的 socket, 卡住能真关 (见 [_RawStream])。
    final raw = await _RawStream.open(
        req, 'audio/mpeg', headers: {'Accept-Ranges': 'none'});
    if (raw == null) {
      _log('[网页] ${cam.name}: 摘不到 socket, 这条声音放弃');
      relay.detach();
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
      return;
    }

    var open = true;
    var busy = false;
    StreamSubscription<Uint8List>? sub;
    Timer? stalled;

    void release() {
      if (!open) return;
      open = false;
      busy = false;
      stalled?.cancel();
      stalled = null;
      relay.detach();
      raw.close();
      unawaited(sub?.cancel());
    }

    unawaited(raw.done.then((_) => release()));
    sub = chunks.listen(
      (chunk) {
        if (!open || busy) return; // 读得慢就丢一小段, 别让延迟越积越大
        busy = true;
        // 和画面一样: 客户端不读了 (锁屏/切后台的半死连接) 就断开回收,
        // 否则 AudioRelay.clients 只增不减, 攒满 2 路之后声音永久 503。
        stalled?.cancel();
        stalled = Timer(streamStallTimeout, () {
          if (!open) return;
          _log('[网页] ${cam.name}: 声音连接 '
              '${streamStallTimeout.inSeconds}s 写不出去, 断开回收');
          release();
        });
        raw.write([chunk]).then((ok) {
          busy = false;
          stalled?.cancel();
          stalled = null;
          if (!ok) release();
        });
      },
      onDone: release,
      onError: (_) => release(),
    );
    await raw.done;
  }

  AudioRelay _audioRelayFor(CameraProfile c) {
    return _audioRelays.putIfAbsent(
      c.id,
      () => AudioRelay(
        camera: c,
        // 和画面一样: 每次重连都重新解析 (码流/地址可能被改过)。
        resolveUrl: () {
          final cur = _findCamera(c.id) ?? c;
          final url = cur.enabled ? cur.resolveUrl(null) : null;
          return url != null && url.isNotEmpty ? url : null;
        },
        ffmpegPath: ffmpegPath,
        log: _log,
      ),
    );
  }

  // -- ws ---------------------------------------------------------------

  /// `/ws-cam` — 所有画面帧走一条 WebSocket。
  ///
  /// 为什么不用 MJPEG: WebKit(iOS Safari / WKWebView)的 `fetch` 读不出永不
  /// 结束的响应体 —— 能拿到 200 和 body, 但第一次 `read()` 立刻
  /// `TypeError: Load failed`。2026-10-26 用 Playwright 的 WebKit 对照实测
  /// (换 Node 的最小 MJPEG 服务器、换 Content-Type、换分块/关连接界定都一样
  /// 失败), 和本源实现无关; 同一个页面在电脑的 Chromium 上正常 —— 所以
  /// 「电脑有画面、iOS 全黑」。
  ///
  /// `<img src=MJPEG>` 在 iOS 上能显示, 但页面把它摘掉时 WebKit 不关连接
  /// (老问题: 名额被半死连接吃光 → 一个黑屏变全黑)。
  ///
  /// 一条 WS 承载所有可见画面: 一个站点只占 1 条连接, 退订立刻生效, 也不会
  /// 像长连接流那样把 Cloudflare 隧道的连接级窗口堵死。
  ///
  /// 协议: 文本 = 控制 (`{"sub":[id…]}` 全量订阅 / `{"unsub":[id…]}` /
  /// `{"ack":id}` / `{"kick":id}` 强制重启这一路);
  /// 二进制 = `[1 字节 id 长度][id][JPEG]`。
  /// 每路一次只放一帧出去, 客户端画完才回 ack —— 手机跟不上时服务端不会囤积。
  Future<void> _serveFrames(HttpRequest req) async {
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (e) {
      _log('[网页] 画面通道升级失败: $e');
      return;
    }
    // 协议层心跳: 手机断网/冻住时 dart:io 会自己把死连接收掉, 不至于让
    // 一路 _FrameSub 一直挂着占 relay。
    try {
      ws.pingInterval = const Duration(seconds: 20);
    } catch (_) {}
    final subs = <String, _FrameSub>{};

    void drop(String id) {
      final sub = subs.remove(id);
      sub?.close();
      if (sub != null) {
        _log('[网页] ${sub.camera.name}: 画面退订 (WS 全站 ${_FrameSub.active} 路)');
      }
    }

    void subscribe(String id) {
      if (subs.containsKey(id)) return;
      final cam = _findCamera(id);
      if (cam == null || !cam.enabled) return;
      final sub = _FrameSub(ws, cam, _relayFor(cam));
      subs[id] = sub;
      sub.start();
      _log('[网页] ${cam.name}: 画面挂上 (WS 全站 ${_FrameSub.active} 路)');
    }

    void sync(List<String> ids) {
      final want = ids.toSet();
      for (final id in subs.keys.toList()) {
        if (!want.contains(id)) drop(id);
      }
      for (final id in want.toList()) {
        subscribe(id);
      }
    }

    ws.listen((data) {
      if (data is! String) return;
      Object? msg;
      try {
        msg = jsonDecode(data);
      } catch (_) {
        return;
      }
      if (msg is! Map) return;
      if (msg['ping'] != null) {
        // 页面用它判断这条 WS 是不是被 iOS 冻住了 (冻住的 socket 不 close)。
        try {
          ws.add(jsonEncode({'pong': 1}));
        } catch (_) {}
        return;
      }
      final sub = msg['sub'];
      if (sub is List) sync(sub.whereType<String>().toList());
      final unsub = msg['unsub'];
      if (unsub is List) {
        for (final id in unsub.whereType<String>()) {
          drop(id);
        }
      }
      final ack = msg['ack'];
      if (ack is String) subs[ack]?.ack();
      final kick = msg['kick'];
      if (kick is String) {
        final old = subs.remove(kick);
        old?.close();
        subscribe(kick); // 重新解析源 (页面看门狗用)
      }
    }, onDone: () {
      for (final id in subs.keys.toList()) {
        drop(id);
      }
    }, onError: (_) {
      for (final id in subs.keys.toList()) {
        drop(id);
      }
    });
  }

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

/// 一条可以「强关」的流式 HTTP 响应: 直接把底层 socket 拿在手里。
///
/// 见 [_serveMjpeg] 上的说明 —— `HttpResponse` 在客户端不读时既关不掉也摘不
/// 走, 用这条路径才能在卡死时真的把 TCP 收掉。
class _RawStream {
  _RawStream._(this.socket);

  final Socket socket;
  StreamSubscription<Uint8List>? _sub;
  final _done = Completer<void>();
  bool _closed = false;

  bool get closed => _closed;
  Future<void> get done => _done.future;

  /// 摘 socket 并写头。失败返回 null (这条连接救不回来)。
  static Future<_RawStream?> open(
    HttpRequest req,
    String contentType, {
    Map<String, String> headers = const {},
  }) async {
    final Socket socket;
    try {
      // 必须赶在写第一个字节之前: 头一发就抛 "Headers already sent"。
      socket = await req.response.detachSocket(writeHeaders: false);
    } catch (_) {
      return null;
    }
    final stream = _RawStream._(socket);
    stream._start(contentType, headers);
    return stream;
  }

  void _start(String contentType, Map<String, String> extra) {
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}
    _sub = socket.listen((_) {}, onError: (_) => close(), onDone: close);
    final head = StringBuffer()
      ..write('HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: $contentType\r\n')
      ..write('Cache-Control: no-cache, no-store\r\n')
      // 分块传输: 一条永不结束的流没有 Content-Length, 而 Cloudflare 边缘
      // 只对 chunked 逐块转发 (关连接界定的 body 它可能一直缓着不发)。
      ..write('Transfer-Encoding: chunked\r\n')
      ..write('Connection: close\r\n');
    extra.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('\r\n');
    try {
      socket.add(ascii.encode(head.toString()));
    } catch (_) {
      close();
    }
  }

  /// 写一个 chunk 并等它真的进了内核缓冲。false = socket 已经没了。
  Future<bool> write(List<List<int>> parts) async {
    if (_closed) return false;
    var size = 0;
    for (final p in parts) {
      size += p.length;
    }
    try {
      socket.add(ascii.encode('${size.toRadixString(16)}\r\n'));
      for (final p in parts) {
        socket.add(p);
      }
      socket.add(ascii.encode('\r\n'));
      await socket.flush();
      return !_closed;
    } catch (_) {
      close();
      return false;
    }
  }

  /// 真关: `destroy()` 立刻收掉 TCP (带 RST), 不等挂着的 flush。
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      socket.destroy();
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
  }
}

/// 一路画面在 `/ws-cam` 上的订阅。
///
/// 背压: 一帧发出去后等页面的 ack 再发下一帧, 中间来的帧只留最新一张。
/// 手机画一帧 720p JPEG 要几十毫秒, 不压的话浏览器会囤一长串过期帧, 越
/// 看越延迟; 也不会像 MJPEG 那样在隧道里堆出几百 KB 的滞留字节。
class _FrameSub {
  _FrameSub(this.ws, this.camera, this.relay);

  final WebSocket ws;
  final CameraProfile camera;
  final CameraRelay relay;

  static var active = 0;

  StreamSubscription<Uint8List>? _sub;
  Uint8List? _pending;
  bool _waiting = false;
  bool _closed = false;
  Timer? _ackTimeout;

  /// 页面这么久不回 ack 就当它这一帧丢了, 放行下一帧 (不然一路卡死就永远
  /// 停住)。真死了的 socket 由协议层心跳 + onDone 收拾。
  static const _ackAfter = Duration(seconds: 8);

  void start() {
    if (_closed) return;
    active++;
    _sub = relay.attach().listen(_onFrame, onError: (_) {}, onDone: () {});
    final first = relay.latest;
    if (first != null) _send(first);
  }

  void _onFrame(Uint8List frame) {
    if (_closed) return;
    if (_waiting) {
      _pending = frame; // 只留最新一张, 旧的丢掉
      return;
    }
    _send(frame);
  }

  void _send(Uint8List frame) {
    if (_closed) return;
    final id = utf8.encode(camera.id);
    final out = Uint8List(1 + id.length + frame.length);
    out[0] = id.length;
    out.setRange(1, 1 + id.length, id);
    out.setRange(1 + id.length, out.length, frame);
    try {
      ws.add(out);
    } catch (_) {
      close();
      return;
    }
    _waiting = true;
    _ackTimeout?.cancel();
    _ackTimeout = Timer(_ackAfter, () {
      if (_closed || !_waiting) return;
      _waiting = false;
      final next = _pending;
      _pending = null;
      if (next != null) _send(next);
    });
  }

  void ack() {
    if (_closed) return;
    _waiting = false;
    _ackTimeout?.cancel();
    _ackTimeout = null;
    final next = _pending;
    _pending = null;
    if (next != null) _send(next);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    active = (active - 1).clamp(0, 1 << 30);
    _ackTimeout?.cancel();
    _ackTimeout = null;
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      relay.detach();
    } catch (_) {}
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
