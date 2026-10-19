// Throwaway: test the A1/P1 MJPEG camera protocol on TLS :6000.
// Usage: dart run tool/mjpeg_test.dart <serial> <ip> [out.jpg]
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> args) async {
  final serial = args[0];
  final ip = args[1];
  final outPath = args.length > 2 ? args[2] : '/tmp/bambu_cam_test.jpg';

  final confPath =
      '${Platform.environment['HOME']}/Library/Application Support/'
      'BambuStudio/BambuStudio.conf';
  final conf =
      jsonDecode(File(confPath).readAsStringSync()) as Map<String, dynamic>;
  final code = (conf['access_code'] as Map<String, dynamic>)[serial] as String;

  final socket = await SecureSocket.connect(ip, 6000,
      onBadCertificate: (_) => true, timeout: const Duration(seconds: 5));
  stdout.writeln('TLS connected');

  // 80-byte auth packet: len(0x40) type(0x3000) flags(0) resv(0),
  // 32B username + 32B password, all little-endian, NUL-padded.
  final auth = BytesBuilder();
  final head = ByteData(16);
  head.setUint32(0, 0x40, Endian.little);
  head.setUint32(4, 0x3000, Endian.little);
  head.setUint32(8, 0, Endian.little);
  head.setUint32(12, 0, Endian.little);
  auth.add(head.buffer.asUint8List());
  Uint8List pad32(String s) {
    final b = Uint8List(32);
    final bytes = ascii.encode(s);
    b.setRange(0, bytes.length.clamp(0, 32), bytes);
    return b;
  }

  auth.add(pad32('bblp'));
  auth.add(pad32(code));
  socket.add(auth.takeBytes());
  stdout.writeln('auth sent (${auth.length} bytes)');

  // Read 16-byte frame header, then payload; save first JPEG frame.
  final buf = BytesBuilder();
  final header = Uint8List(16);
  var headerFill = 0;
  var payloadTarget = 0;
  final done = Completer<void>();

  final sub = socket.listen((chunk) {
    if (done.isCompleted) return;
    var data = chunk;
    while (data.isNotEmpty) {
      if (payloadTarget == 0) {
        final need = 16 - headerFill;
        final take = need <= data.length ? need : data.length;
        header.setRange(headerFill, headerFill + take, data);
        headerFill += take;
        data = data.sublist(take);
        if (headerFill == 16) {
          final bd = ByteData.sublistView(header);
          payloadTarget = bd.getUint32(0, Endian.little);
          final itrack = bd.getUint32(4, Endian.little);
          final flags = bd.getUint32(8, Endian.little);
          stdout.writeln(
              'frame header: payload=$payloadTarget itrack=$itrack flags=$flags');
          buf.clear();
          if (payloadTarget == 0 || payloadTarget > 4 << 20) {
            stdout.writeln('bogus payload size, aborting');
            done.complete();
            return;
          }
        }
      } else {
        final need = payloadTarget - buf.length;
        final take = need <= data.length ? need : data.length;
        buf.add(data.sublist(0, take));
        data = data.sublist(take);
        if (buf.length == payloadTarget) {
          final jpg = buf.takeBytes();
          File(outPath).writeAsBytesSync(jpg);
          stdout.writeln(
              'frame saved: ${jpg.length} bytes, SOI=${jpg[0] == 0xFF && jpg[1] == 0xD8}, EOI=${jpg[jpg.length - 2] == 0xFF && jpg[jpg.length - 1] == 0xD9}');
          done.complete();
          return;
        }
      }
    }
  }, onError: (Object e) {
    stdout.writeln('socket error: $e');
    if (!done.isCompleted) done.complete();
  }, onDone: () {
    stdout.writeln('socket closed by printer');
    if (!done.isCompleted) done.complete();
  });

  var got = true;
  await done.future.timeout(const Duration(seconds: 8), onTimeout: () {
    stdout.writeln('timeout waiting for frame');
    got = false;
  });
  sub.cancel();
  socket.destroy();
  exit(got ? 0 : 3);
}
