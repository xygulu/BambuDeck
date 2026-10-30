import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One discovered RTSP endpoint.
class RtspHit {
  const RtspHit({
    required this.ip,
    required this.port,
    required this.path,
    this.server = '',
    this.needsAuth = false,
  });

  final String ip;
  final int port;

  /// Stream path that answered, e.g. `/Streaming/Channels/101`.
  final String path;

  /// `Server:` response header, often names the vendor.
  final String server;

  /// True when the endpoint answered 401 - camera present, credentials
  /// needed before playback.
  final bool needsAuth;

  /// Full rtsp URL without credentials (the user adds their own).
  String get url => 'rtsp://$ip:$port$path';

  /// Best-effort vendor name from the Server header.
  String? get vendor {
    final s = server.toLowerCase();
    if (s.contains('ezviz')) return '萤石';
    if (s.contains('hikvision') || s.contains('hik')) return '海康威视';
    if (s.contains('dahua') || s.contains('daheng')) return '大华';
    if (s.contains('tp-link')) return 'TP-LINK';
    if (s.contains('reolink')) return 'Reolink';
    if (s.contains('axis')) return 'Axis';
    return null;
  }

  @override
  String toString() => '$url${needsAuth ? " (需密码)" : ""}'
      '${vendor == null ? "" : " [$vendor]"}';
}

/// Sweep outcome: answering endpoints plus how many ports were open, so
/// the UI can tell "nothing on this subnet" apart from "ports open but
/// nobody answered DESCRIBE".
class RtspScanReport {
  const RtspScanReport({required this.hits, required this.openPorts});

  final List<RtspHit> hits;

  /// TCP ports found open during the sweep, answering RTSP or not.
  final int openPorts;
}

/// LAN RTSP camera discovery, tuned for networks where multicast (SSDP /
/// WS-Discovery / mDNS) does not cross subnets but TCP unicast routes:
/// sweep [ports] across `subnetPrefix.1-254`, then RTSP-DESCRIBE common
/// stream paths on every open port.
///
/// `subnetPrefix` is the first three octets, e.g. `192.168.100`. Progress
/// reports completed first-phase probes.
Future<RtspScanReport> scanRtspCameras({
  required String subnetPrefix,
  List<int> ports = const [554, 8554, 10554],
  List<String> paths = defaultProbePaths,
  int concurrency = 64,
  Duration connectTimeout = const Duration(milliseconds: 400),
  Duration responseTimeout = const Duration(milliseconds: 700),
  void Function(int done, int total)? onProgress,
}) async {
  final hosts = [for (var i = 1; i <= 254; i++) '$subnetPrefix.$i'];
  final targets = [
    for (final h in hosts)
      for (final p in ports) (ip: h, port: p),
  ];

  // Phase 1: TCP sweep for open RTSP ports.
  final open = <(String, int)>[];
  var done = 0;
  await _forEach(targets, concurrency, (t) async {
    try {
      final s = await Socket.connect(t.ip, t.port, timeout: connectTimeout);
      s.destroy();
      open.add((t.ip, t.port));
    } on SocketException {
      // refused / filtered - not an RTSP endpoint
    } on TimeoutException {
      // slow host - skip
    }
    done++;
    onProgress?.call(done, targets.length);
  });

  // Phase 2: path probing on the survivors.
  final hits = <RtspHit>[];
  await _forEach(open, 8, (t) async {
    final hit = await _probeHost(
      t.$1,
      t.$2,
      paths,
      responseTimeout: responseTimeout,
    );
    if (hit != null) hits.add(hit);
  });
  hits.sort((a, b) => a.url.compareTo(b.url));
  return RtspScanReport(hits: hits, openPorts: open.length);
}

/// DESCRIBE each candidate path; prefer an authorized 200, else a 401
/// proves presence. Null when nothing answered.
Future<RtspHit?> _probeHost(
  String ip,
  int port,
  List<String> paths, {
  required Duration responseTimeout,
}) async {
  RtspHit? authOnly;
  for (final path in paths) {
    final res = await _describe(ip, port, path, responseTimeout);
    if (res == null) continue;
    if (!res.needsAuth) return res;
    authOnly ??= res;
  }
  return authOnly;
}

Future<RtspHit?> _describe(
    String ip, int port, String path, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: timeout);
    socket.write('DESCRIBE rtsp://$ip:$port$path RTSP/1.0\r\n'
        'CSeq: 1\r\n'
        'User-Agent: BambuDeck\r\n'
        'Accept: application/sdp\r\n'
        '\r\n');
    // RTSP servers keep the connection open after replying, so the read
    // must stop at the header terminator, not at close - and must not
    // hang when the server never answers at all.
    final buffer = StringBuffer();
    final done = Completer<String>();
    late final StreamSubscription<Uint8List> sub;
    final timer = Timer(timeout, () {
      socket?.destroy();
      if (!done.isCompleted) done.complete(buffer.toString());
    });
    sub = socket.listen(
      (chunk) {
        buffer.write(utf8.decode(chunk));
        if (buffer.toString().contains('\r\n\r\n')) {
          timer.cancel();
          if (!done.isCompleted) done.complete(buffer.toString());
        }
      },
      onError: (Object _) {
        timer.cancel();
        if (!done.isCompleted) done.complete(buffer.toString());
      },
      onDone: () {
        timer.cancel();
        if (!done.isCompleted) done.complete(buffer.toString());
      },
    );
    final reply = await done.future;
    await sub.cancel();
    final status = RegExp(r'RTSP/\d\.\d (\d{3})').firstMatch(reply);
    if (status == null) return null;
    final code = int.parse(status.group(1)!);
    if (code != 200 && code != 401) return null;
    final server =
        RegExp(r'^server:\s*(.+?)\s*$', multiLine: true, caseSensitive: false)
            .firstMatch(reply)
            ?.group(1) ??
        '';
    return RtspHit(
      ip: ip,
      port: port,
      path: path,
      server: server,
      needsAuth: code == 401,
    );
  } on SocketException {
    return null;
  } on TimeoutException {
    return null;
  } finally {
    socket?.destroy();
  }
}

/// Common stream paths: generic first, then the big vendors' fixed schemes.
const defaultProbePaths = [
  '/stream1',
  '/1',
  '/h264',
  '/live/ch0',
  '/Streaming/Channels/101', // Hikvision main stream
  '/h264/ch1/main/av_stream', // EZVIZ main stream
  '/cam/realmonitor?channel=1&subtype=0', // Dahua main stream
  '/h264Preview_01_main', // Reolink main stream (legacy firmware)
  '/onvif1',
  '/',
];

Future<void> _forEach<T>(
    List<T> items, int n, Future<void> Function(T) action) async {
  var i = 0;
  Future<void> worker() async {
    while (i < items.length) {
      await action(items[i++]);
    }
  }

  await [for (var k = 0; k < n; k++) worker()].wait;
}
