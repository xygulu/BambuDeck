// Throwaway: RTSP-scan the Mac's own /24 and print the report.
// Usage: dart run tool/scan_my_lan.dart [subnetPrefix]
import 'dart:io';

import 'package:deck/data/rtsp_scanner.dart';

Future<void> main(List<String> args) async {
  var prefix = args.isNotEmpty ? args[0] : '';
  if (prefix.isEmpty) {
    final interfaces = await NetworkInterface.list();
    for (final itf in interfaces) {
      for (final addr in itf.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (addr.address.startsWith('127.')) continue;
        final p = addr.address.split('.');
        if (p.length == 4) prefix = '${p[0]}.${p[1]}.${p[2]}';
      }
    }
  }
  stdout.writeln('scanning $prefix.1-254 on 554/8554/10554 …');
  final sw = Stopwatch()..start();
  final report = await scanRtspCameras(
    subnetPrefix: prefix,
    onProgress: (d, t) {
      if (d % 128 == 0 || d == t) stdout.write('\r$d/$t');
    },
  );
  stdout.writeln('\ndone in ${sw.elapsedMilliseconds} ms, '
      'openPorts=${report.openPorts}');
  for (final h in report.hits) {
    stdout.writeln('HIT $h');
  }
  if (report.hits.isEmpty) stdout.writeln('no RTSP hits');
  exit(0);
}
