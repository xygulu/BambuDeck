// Throwaway: confirm whether repeated PTZ START commands (the PtzPad's 250ms
// repeat) lock the camera with err=151. Usage:
//   dart run tool/hik_ptz_repeat_test.dart <ip> <verificationCode>
import 'dart:io';
import 'dart:typed_data';

import 'package:deck/data/hcnetsdk.dart';

Future<void> main(List<String> args) async {
  final ip = args[0];
  final code = args[1];
  final client = HcNetSdkClient(host: ip, localIp: await _detectLocalIp());
  final session = await client.login(username: 'admin', password: code);
  stdout.writeln('logged in, serial=${session.serial}');

  // Test A: single start/stop twice on the SAME direction.
  stdout.writeln('== A: single start(24)/stop x2 (same direction) ==');
  for (var i = 0; i < 2; i++) {
    final s = await client.ptzControl(session, command: 24, stop: false);
    stdout.writeln('  start 24 -> ${_v(s)}');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final t = await client.ptzControl(session, command: 24, stop: true);
    stdout.writeln('  stop 24  -> ${_v(t)}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  // Test B: repeated start (the app's 250ms repeat) then stop, then a
  // DIFFERENT direction.
  stdout.writeln('== B: start(24) x9 @250ms then stop, then start(21) ==');
  for (var i = 0; i < 9; i++) {
    final s = await client.ptzControl(session, command: 24, stop: false);
    stdout.writeln('  start 24 #$i -> ${_v(s)}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final t = await client.ptzControl(session, command: 24, stop: true);
  stdout.writeln('  stop 24  -> ${_v(t)}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final up = await client.ptzControl(session, command: 21, stop: false);
  stdout.writeln('  start 21 (after repeat cycle) -> ${_v(up)}');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final upt = await client.ptzControl(session, command: 21, stop: true);
  stdout.writeln('  stop 21  -> ${_v(upt)}');
}

String _v(Uint8List resp) {
  if (resp.length < 16) return 'resp ${resp.length}B';
  final f4 = ByteData.sublistView(resp).getUint32(4, Endian.big);
  final f8 = ByteData.sublistView(resp).getUint32(8, Endian.big);
  final ok = f4 != f8 || f8 <= 1;
  return 'f4=0x${f4.toRadixString(16)} f8=0x${f8.toRadixString(16)} '
      '${ok ? "OK" : "REJECTED(err=$f8)"}';
}

Future<String> _detectLocalIp() async {
  for (final itf in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in itf.addresses) {
      if (!a.address.startsWith('127.') && !a.address.startsWith('169.254.')) {
        return a.address;
      }
    }
  }
  return '127.0.0.1';
}
