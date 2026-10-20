// Throwaway: HCNetSDK (port 8000) PTZ verification for EZVIZ cameras.
// Usage: dart run tool/hik_ptz_probe.dart <ip> <verificationCode> [localIp]
// The verification code is passed on the command line and never stored.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:deck/data/hcnetsdk.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
        'usage: dart run tool/hik_ptz_probe.dart <ip> <verificationCode> [localIp]');
    exit(64);
  }
  final ip = args[0];
  final code = args[1];
  final localIp = args.length > 2 ? args[2] : await _detectLocalIp();

  stdout.writeln('target $ip:8000 localIp=$localIp');
  final client = HcNetSdkClient(host: ip, localIp: localIp);

  final session = await _login(client, code);
  if (session == null) {
    stderr.writeln('all logins failed (tried admin + EZ_LOCAL_USER)');
    exit(1);
  }

  const dirs = <(String, int)>[
    ('tilt-up', hcPtzTiltUp),
    ('tilt-down', hcPtzTiltDown),
    ('pan-left', hcPtzPanLeft),
    ('pan-right', hcPtzPanRight),
  ];
  stdout.writeln('watch the camera — sending start/stop for each direction');
  var ok = true;
  for (final (name, command) in dirs) {
    stdout.writeln('== $name ==');
    try {
      final start =
          await client.ptzControl(session, command: command, stop: false);
      _printResp('  start', start);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final stop = await client.ptzControl(session, command: command, stop: true);
      _printResp('  stop ', stop);
      ok = ok && _accepted(start) && _accepted(stop);
    } catch (e) {
      stdout.writeln('  failed: $e');
      ok = false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  stdout.writeln(ok
      ? 'done — every start/stop was accepted (field_4==field_8∈{0,1}). '
          'If the camera did not move, re-check the command id.'
      : 'some commands were rejected — see field_4/field_8 above (equal & '
          '>1 = rejection, the value is the error code).');
}

Future<HcNetSdkSession?> _login(HcNetSdkClient client, String code) async {
  final candidates = <(String, String)>[
    ('admin', code),
    // EZVIZ local user fallback: md5(code)[8:24], lowercased.
    ('EZ_LOCAL_USER', _md5Slice(code)),
  ];
  for (final (username, password) in candidates) {
    stdout.writeln('trying login username=$username ...');
    try {
      final s = await client.login(username: username, password: password);
      stdout.writeln(
          'LOGIN OK  username=$username serial=${s.serial} sessionId=${_hex(s.sessionId)}');
      return s;
    } catch (e) {
      stdout.writeln('  login failed ($username): $e');
    }
  }
  return null;
}

String _md5Slice(String code) =>
    md5.convert(code.codeUnits).toString().substring(8, 24).toLowerCase();

void _printResp(String label, Uint8List resp) {
  final header = resp.length >= 16 ? resp.sublist(0, 16) : resp;
  final f4 = _u32be(header, 4);
  final f8 = _u32be(header, 8);
  final verdict = _accepted(resp) ? 'OK' : 'REJECTED(err=$f8)';
  stdout.writeln('$label resp ${resp.length}B f4=0x${f4.toRadixString(16).padLeft(8, '0')} '
      'f8=0x${f8.toRadixString(16).padLeft(8, '0')} $verdict');
}

/// Success = field_4 != field_8, or both equal to 0/1. field_4 == field_8
/// and > 1 is a rejection whose error code is field_8.
bool _accepted(Uint8List resp) {
  if (resp.length < 16) return false;
  final f4 = _u32be(resp, 4);
  final f8 = _u32be(resp, 8);
  return f4 != f8 || f8 <= 1;
}

int _u32be(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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
