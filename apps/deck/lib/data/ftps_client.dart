import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One FTP control reply: code + collapsed text. Final lines are `ddd text`,
/// interim (multiline) lines are `ddd-text`; both land in [text].
class FtpReply {
  FtpReply(this.code, this.text);

  final int code;
  final String text;

  bool get isPositiveCompletion => code >= 200 && code < 300;
  bool get isPositivePreliminary => code >= 100 && code < 200;
}

/// Incremental parser for the FTP control stream: feeds raw bytes, emits a
/// [FtpReply] whenever a final (`ddd `) line completes a reply. Extracted
/// from the socket plumbing so it is unit-testable.
class FtpReplyParser {
  final _lineBuf = StringBuffer();
  FtpReply? _pending;
  int? _pendingCode;

  /// Feed one chunk; returns the completed reply or null when more lines
  /// are needed.
  FtpReply? push(List<int> bytes) {
    _lineBuf.write(utf8.decode(bytes, allowMalformed: true));
    while (true) {
      final s = _lineBuf.toString();
      final nl = s.indexOf('\n');
      if (nl < 0) return _pending;
      final line = s.substring(0, nl).replaceAll('\r', '');
      _lineBuf.clear();
      _lineBuf.write(s.substring(nl + 1));
      final m = RegExp(r'^(\d{3})([ -])(.*)$').firstMatch(line);
      if (m == null) continue; // not a reply line - ignore
      final code = int.parse(m.group(1)!);
      final finalLine = m.group(2) == ' ';
      _pendingCode ??= code;
      if (!finalLine) continue; // multiline continuation - keep reading
      final reply = FtpReply(_pendingCode ?? code, line);
      _pendingCode = null;
      return reply;
    }
  }
}

class FtpsException implements Exception {
  FtpsException(this.message);
  final String message;

  @override
  String toString() => 'FtpsException: $message';
}

/// Minimal implicit-TLS FTPS client covering exactly what a LAN print upload
/// to a Bambu printer needs: login (bblp + access code), binary mode, PROT P,
/// PASV + STOR. The printer serves a self-signed certificate, so the TLS
/// callbacks accept anything - the access code is the shared secret here,
/// same trust model as the MQTT link.
class FtpsClient {
  FtpsClient({
    required this.host,
    this.port = 990,
    required this.username,
    required this.password,
    this.log,
  });

  final String host;
  final int port;
  final String username;
  final String password;

  /// Optional diagnostics sink (wired to LogBuffer by callers).
  final void Function(String line)? log;

  SecureSocket? _control;
  FtpReplyParser _parser = FtpReplyParser();
  StreamSubscription<Uint8List>? _ctrlSub;
  final _replies = StreamController<FtpReply>.broadcast();

  /// The reply waiter currently blocked in [_waitForReply], so a socket
  /// error/close fails it fast instead of riding out the timeout.
  Completer<FtpReply>? _awaiting;

  void _logLine(String line) => log?.call('[ftps] $line');

  /// Waits for the next control reply without sending anything (greeting,
  /// and the 226 that closes a STOR).
  Future<FtpReply> _waitForReply({Duration? timeout}) async {
    if (_control == null) throw FtpsException('control socket not open');
    final c = Completer<FtpReply>();
    _awaiting = c;
    final sub = _replies.stream.listen((r) {
      if (!c.isCompleted) c.complete(r);
    });
    try {
      final reply = await c.future.timeout(timeout ?? const Duration(seconds: 10));
      _logLine('< ${reply.code} ${reply.text}');
      return reply;
    } on TimeoutException {
      throw FtpsException('等待 FTP 应答超时(打印机无响应)');
    } finally {
      _awaiting = null;
      await sub.cancel();
    }
  }

  Future<FtpReply> _command(String cmd, {Duration? timeout}) async {
    final sock = _control;
    if (sock == null) throw FtpsException('control socket not open');
    _logLine('> $cmd');
    sock.add(utf8.encode('$cmd\r\n'));
    try {
      return await _waitForReply(timeout: timeout);
    } on TimeoutException {
      throw FtpsException('$cmd 超时(打印机无响应)');
    }
  }

  Future<void> _expect(String cmd, {bool preliminary = false}) async {
    final r = await _command(cmd);
    final ok = preliminary ? r.isPositivePreliminary : r.isPositiveCompletion;
    if (!ok) {
      throw FtpsException('$cmd 被拒绝: ${r.code} ${r.text}');
    }
  }

  /// Opens the control channel and logs in. [onBadCertificate] defaults to
  /// accepting the printer's self-signed cert.
  Future<void> connect() async {
    final sock = await SecureSocket.connect(host, port,
        onBadCertificate: (_) => true, timeout: const Duration(seconds: 8));
    _control = sock;
    _parser = FtpReplyParser();
    _ctrlSub = sock.listen((chunk) {
      final r = _parser.push(chunk);
      if (r != null && !_replies.isClosed) _replies.add(r);
    }, onError: (Object e) {
      _awaiting?.completeError(FtpsException('control 连接错误: $e'));
      _awaiting = null;
    }, onDone: () {
      _awaiting?.completeError(FtpsException('control 连接已关闭'));
      _awaiting = null;
    });
    final greeting = await _waitForReply(timeout: const Duration(seconds: 8));
    if (greeting.code != 220) {
      throw FtpsException('FTP 欢迎语异常: ${greeting.code}');
    }
    await _expect('USER $username');
    await _expect('PASS $password');
    await _expect('TYPE I');
    await _expect('PBSZ 0');
    await _expect('PROT P');
  }

  /// Uploads [bytes] to `/<directory>/<name>` (Bambu: directory "cache").
  Future<void> upload(
      {required String directory,
      required String name,
      required List<int> bytes}) async {
    await _expect('CWD /$directory');
    final pasv = await _command('PASV');
    final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)')
        .firstMatch(pasv.text);
    if (m == null) {
      throw FtpsException('PASV 应答无法解析: ${pasv.text}');
    }
    // Always dial the control host: printers behind odd NAT configs report
    // a data address that is not reachable from here.
    final dataPort =
        int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    final data = await SecureSocket.connect(host, dataPort,
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 8));
    await _expect('STOR $name', preliminary: true);
    data.add(bytes);
    await data.flush();
    await data.close();
    final done =
        await _waitForReply(timeout: const Duration(seconds: 30));
    if (done.code != 226) {
      throw FtpsException('STOR 未完成: ${done.code} ${done.text}');
    }
    _logLine('uploaded ${bytes.length}B -> /$directory/$name');
  }

  Future<void> close() async {
    try {
      if (_control != null) {
        _control!.add(utf8.encode('QUIT\r\n'));
        await _control!.flush();
      }
    } catch (_) {
      // best effort
    }
    await _ctrlSub?.cancel();
    _ctrlSub = null;
    try {
      _control?.destroy();
    } catch (_) {}
    _control = null;
    await _replies.close();
  }
}
