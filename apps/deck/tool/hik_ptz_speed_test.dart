// Throwaway: answer two questions about HCNetSDK PTZ on port 8000:
//   Q1. Is a `[channel][signed-cmd][speed]` 12-byte tail accepted (vs the
//       8-byte tail we currently send)?
//   Q2. Does the camera reject a second press on the SAME session, and does a
//       fresh login before every command fix it?
// Usage:
//   dart run tool/hik_ptz_speed_test.dart <ip> <verificationCode>
import 'dart:io';
import 'dart:typed_data';

import 'package:deck/data/hcnetsdk.dart';

const _ptz = 0x00030200;

Uint8List _u32(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.big);
  return b;
}

// 8-byte tail: channel + signed command (current app behavior).
Uint8List tail8(int ch, int cmd, bool stop) => Uint8List.fromList(
    [..._u32(ch), ..._u32((stop ? -cmd : cmd) & 0xFFFFFFFF)]);

// 12-byte tail: channel + signed command + speed word.
Uint8List tail12(int ch, int cmd, bool stop, int speed) => Uint8List.fromList(
    [...tail8(ch, cmd, stop), ..._u32(speed)]);

// 16-byte tail: channel + command + stop(0/1) + speed (native struct shape).
Uint8List tail16(int ch, int cmd, bool stop, int speed) => Uint8List.fromList(
    [..._u32(ch), ..._u32(cmd), ..._u32(stop ? 1 : 0), ..._u32(speed)]);

Future<void> main(List<String> args) async {
  final ip = args[0];
  final code = args[1];
  final client = HcNetSdkClient(host: ip, localIp: await _detectLocalIp());

  Future<String> send(HcNetSdkSession s, Uint8List tail) async {
    final resp = await client.control(s, commandId: _ptz, bodyTail: tail);
    return _v(resp);
  }

  Future<HcNetSdkSession> login() async {
    final s = await client.login(username: 'admin', password: code);
    stdout.writeln('  (fresh login, serial=${s.serial})');
    return s;
  }

  // Q1: is each tail shape accepted?
  stdout.writeln('== Q1: tail shape acceptance (start/stop pan-left cmd=23) ==');
  var s = await login();
  stdout.writeln('  8B  start -> ${await send(s, tail8(1, 23, false))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  8B  stop  -> ${await send(s, tail8(1, 23, true))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  12B start(spd=5) -> ${await send(s, tail12(1, 23, false, 5))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  12B stop(spd=5)  -> ${await send(s, tail12(1, 23, true, 5))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  12B start(spd=1) -> ${await send(s, tail12(1, 23, false, 1))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  12B stop(spd=1)  -> ${await send(s, tail12(1, 23, true, 1))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  16B start(spd=5) -> ${await send(s, tail16(1, 23, false, 5))}');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  stdout.writeln('  16B stop(spd=5)  -> ${await send(s, tail16(1, 23, true, 5))}');

  // Q2: same session, three start/stop cycles (reproduces "locks after one").
  stdout.writeln('== Q2a: same session, 3 start/stop cycles (8B tail) ==');
  for (var i = 0; i < 3; i++) {
    stdout.writeln('  cycle $i start -> ${await send(s, tail8(1, 24, false))}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    stdout.writeln('  cycle $i stop  -> ${await send(s, tail8(1, 24, true))}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  // Q2b: fresh login before EVERY command.
  stdout.writeln('== Q2b: fresh login per command, 3 cycles (8B tail) ==');
  for (var i = 0; i < 3; i++) {
    s = await login();
    stdout.writeln('  cycle $i start -> ${await send(s, tail8(1, 24, false))}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    s = await login();
    stdout.writeln('  cycle $i stop  -> ${await send(s, tail8(1, 24, true))}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
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
