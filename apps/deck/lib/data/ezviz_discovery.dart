import 'dart:async';
import 'dart:io';

import 'hcnetsdk.dart';

/// A cloud-serial → LAN-IP answer from [matchEzvizOnLan].
class EzvizLanMatch {
  const EzvizLanMatch({required this.serial, required this.ip});

  final String serial;
  final String ip;
}

/// Finds the LAN address of each wanted EZVIZ serial by sweeping port 8000
/// (the HCNetSDK command port) across `subnetPrefix.1-254` and reading the
/// camera's serial out of a successful login - the RTSP URL never carries
/// the serial, but the login frame 2 response does (萤石云端导入: 云列表只给
/// 序列号, 本地流要 IP).
///
/// [verificationCode] is the camera's 验证码 (the RTSP password); cameras
/// with a different code fail login and are skipped. Failures never throw -
/// a sweep that finds nothing just returns no match for that serial.
Future<List<EzvizLanMatch>> matchEzvizOnLan({
  required String subnetPrefix,
  required String verificationCode,
  Set<String> wanted = const {},
  int concurrency = 48,
  Duration connectTimeout = const Duration(milliseconds: 500),
  void Function(int done, int total)? onProgress,
}) async {
  final hosts = [for (var i = 1; i <= 254; i++) '$subnetPrefix.$i'];
  final open = <String>[];
  var done = 0;
  await _forEach(hosts, concurrency, (h) async {
    try {
      final s = await Socket.connect(h, 8000, timeout: connectTimeout);
      s.destroy();
      open.add(h);
    } on SocketException {
      // no command port - not a candidate
    } on TimeoutException {
      // slow host - skip
    }
    done++;
    onProgress?.call(done, hosts.length);
  });

  final matches = <EzvizLanMatch>[];
  final localIp = await detectLocalIpv4();
  await _forEach(open, 4, (ip) async {
    final client = HcNetSdkClient(host: ip, localIp: localIp);
    try {
      final session = await client.login(
          username: 'admin', password: verificationCode);
      final serial = session.serial.trim();
      if (serial.isEmpty) return;
      if (wanted.isNotEmpty && !wanted.contains(serial)) return;
      matches.add(EzvizLanMatch(serial: serial, ip: ip));
    } catch (_) {
      // wrong code / not an EZVIZ-Hik device - skip
    }
  });
  return matches;
}

/// First non-loopback IPv4 address - the default subnet prefix source and
/// the HCNetSDK local-ip word.
Future<String> detectLocalIpv4() async {
  for (final itf in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in itf.addresses) {
      if (!a.address.startsWith('127.') && !a.address.startsWith('169.254.')) {
        return a.address;
      }
    }
  }
  return '127.0.0.1';
}

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
