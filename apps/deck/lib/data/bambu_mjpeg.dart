import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The A1 / A1 mini / P1 / P1P camera does not speak RTSP: it serves
/// 1280x720 MJPEG over implicit-TLS TCP :6000 (protocol documented in
/// Doridian/OpenBambuAPI `video.md` and ClusterM/open-bamboo-networking
/// §6.4). X1 / P1S / P2S / H2 use RTSPS :322 instead - see
/// [cameraSchemeForModel].
///
/// Wire: after TLS, send an 80-byte auth packet; the printer then pushes
/// frames - a 16-byte little-endian header (payload size, itrack, flags)
/// followed by that many bytes of a complete JPEG (`FF D8` … `FF D9`).

/// Which transport a printer model's built-in camera speaks.
/// Unknown / empty models count as the MJPEG family (A1/P1 are the
/// majority of LAN printers).
enum BambuCameraScheme { mjpeg, rtsps }

BambuCameraScheme cameraSchemeForModel(String model) {
  const rtspsModels = {'P1S', 'X1C', 'X1E', 'P2S', 'H2D', 'H2S', 'X1'};
  return rtspsModels.contains(model.trim())
      ? BambuCameraScheme.rtsps
      : BambuCameraScheme.mjpeg;
}

/// Best-effort model guess from a serial prefix ('03*' → A1 family,
/// '009*' → P1, '00M*' → X1C). Empty when unknown - callers show a
/// picker instead.
String? guessModelFromSerial(String serial) {
  final s = serial.trim().toUpperCase();
  if (s.startsWith('03')) return 'A1';
  if (s.startsWith('00M')) return 'X1C';
  if (s.startsWith('009')) return 'P1S';
  return null;
}

/// The 80-byte login packet: 16-byte header (payload 0x40, type 0x3000,
/// flags 0, reserved 0) + 32-byte NUL-padded username + 32-byte password.
Uint8List buildMjpegAuthPacket(String username, String password) {
  final b = BytesBuilder();
  final head = ByteData(16)
    ..setUint32(0, 0x40, Endian.little)
    ..setUint32(4, 0x3000, Endian.little)
    ..setUint32(8, 0, Endian.little)
    ..setUint32(12, 0, Endian.little);
  b.add(head.buffer.asUint8List());
  b.add(_pad32(username));
  b.add(_pad32(password));
  return b.takeBytes();
}

Uint8List _pad32(String s) {
  final out = Uint8List(32);
  final bytes = ascii.encode(s);
  out.setRange(0, bytes.length.clamp(0, 32), bytes);
  return out;
}

/// Parse a `bmjpeg://[user:pass@]host[:port]` camera URL.
({String host, int port, String username, String password})?
    parseBambuMjpegUrl(String url) {
  final m = RegExp(r'^bmjpeg://(?:([^:@/]*)[:@]([^@/]*)@)?([^:/]+)(?::(\d+))?')
      .firstMatch(url);
  if (m == null) return null;
  return (
    host: m.group(3)!,
    port: m.group(4) != null ? int.parse(m.group(4)!) : 6000,
    username: m.group(1) ?? 'bblp',
    password: Uri.decodeComponent(m.group(2) ?? ''),
  );
}

/// Stateful frame splitter for the 16-byte-header MJPEG framing. Feed it
/// raw TCP chunks; it hands back complete, SOI/EOI-validated JPEG frames.
/// Malformed frames (bad size or missing JPEG markers) are dropped, not
/// surfaced - the decoder must never see them.
class MjpegFramer {
  static const _headerBytes = 16;
  static const _maxFrameBytes = 4 << 20;

  final _header = Uint8List(_headerBytes);
  var _headerFill = 0;
  var _payloadSize = 0;
  final _body = BytesBuilder(copy: false);

  /// Consumes [chunk]; returns every frame completed by it (may be empty,
  /// may be several).
  List<Uint8List> add(List<int> chunk) {
    final frames = <Uint8List>[];
    var data = chunk;
    while (data.isNotEmpty) {
      if (_payloadSize == 0) {
        final take = (_headerBytes - _headerFill).clamp(0, data.length);
        _header.setRange(_headerFill, _headerFill + take, data);
        _headerFill += take;
        data = data.sublist(take);
        if (_headerFill == _headerBytes) {
          _headerFill = 0; // reset for the next frame's header
          final bd = ByteData.sublistView(_header);
          _payloadSize = bd.getUint32(0, Endian.little);
          _body.clear();
          if (_payloadSize == 0 || _payloadSize > _maxFrameBytes) {
            // Framing lost - drop everything and wait for a clean header.
            _payloadSize = 0;
            data = const [];
          }
        }
      } else {
        final take = (_payloadSize - _body.length).clamp(0, data.length);
        _body.add(data.sublist(0, take));
        data = data.sublist(take);
        if (_body.length == _payloadSize) {
          final frame = bodyFrame();
          _payloadSize = 0;
          if (frame != null) frames.add(frame);
        }
      }
    }
    return frames;
  }

  /// The completed payload as a JPEG, or null when markers say it is not.
  Uint8List? bodyFrame() {
    final frame = _body.takeBytes();
    const soi = [0xFF, 0xD8];
    const eoi = [0xFF, 0xD9];
    final ok = frame.length >= 4 &&
        frame[0] == soi[0] &&
        frame[1] == soi[1] &&
        frame[frame.length - 2] == eoi[0] &&
        frame[frame.length - 1] == eoi[1];
    return ok ? frame : null;
  }
}

/// Long-lived MJPEG connection with automatic reconnect. One JPEG frame
/// per [onFrame] call; errors surface through [onError] (reconnects keep
/// going in the background regardless).
class BambuMjpegStream {
  BambuMjpegStream({
    required this.host,
    this.port = 6000,
    required this.username,
    required this.password,
    this.onFrame,
    this.onError,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final void Function(Uint8List jpeg)? onFrame;
  final void Function(String message)? onError;

  bool _disposed = false;
  SecureSocket? _socket;
  Timer? _retry;

  static const _connectTimeout = Duration(seconds: 5);
  var _retryDelay = const Duration(milliseconds: 800);

  void start() {
    _disposed = false;
    _run();
  }

  Future<void> _run() async {
    if (_disposed) return;
    var ok = false;
    try {
      final socket = await SecureSocket.connect(host, port,
          onBadCertificate: (_) => true, timeout: _connectTimeout);
      _socket = socket;
      socket.add(buildMjpegAuthPacket(username, password));
      await _pump(socket);
      ok = true; // socket closed cleanly by the printer - retry gently
    } on SocketException catch (e) {
      onError?.call('连接失败: $e');
    } on TimeoutException {
      onError?.call('连接超时');
    } catch (e) {
      onError?.call('$e');
    }
    if (_disposed) return;
    if (ok) _retryDelay = const Duration(milliseconds: 800);
    _retry = Timer(_retryDelay, _run);
    _retryDelay *= 2;
    if (_retryDelay > const Duration(seconds: 10)) {
      _retryDelay = const Duration(seconds: 10);
    }
  }

  /// Reads framed JPEGs until the socket dies. Returns normally on close;
  /// errors propagate to _run's catch.
  Future<void> _pump(SecureSocket socket) async {
    final framer = MjpegFramer();
    await for (final chunk in socket) {
      for (final frame in framer.add(chunk)) {
        onFrame?.call(frame);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    try {
      _socket?.destroy();
    } on SocketException {
      // already gone
    }
    _socket = null;
  }
}
