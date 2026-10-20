import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'ftps_client.dart';
import 'log_buffer.dart';
import 'printer_profile.dart';

/// The bundled plate-swap model (单盘换盘): its tail gcode shakes the finished
/// print off the plate and feeds the plate forward - "printing" it is the
/// plate swap. 3mf container, ~222 KB.
const kPlateSwapAsset = 'assets/plate_swap/auto_plate_swap.3mf';

/// Remote name on the printer's FTP; ASCII-only so no FTP encoding surprises.
const kPlateSwapRemoteName = 'bambudeck_plate_swap.3mf';

/// Bytes of the bundled swap model (injectable so tests run without the
/// Flutter asset bundle).
typedef PlateSwapBytesLoader = Future<Uint8List> Function();

/// How the swap order reaches the printer - a tear-off of
/// ConnectionNotifier.printProjectFile in the app, a stub in tests.
typedef ProjectFileSender = Future<bool> Function({
  required String url,
  String param,
  String md5,
  String name,
});

Future<Uint8List> loadBundledPlateSwap() async =>
    (await rootBundle.load(kPlateSwapAsset)).buffer.asUint8List();

/// One-click 自动换盘: uploads the bundled swap model to the printer's
/// `/cache` over FTPS, then tells it to print that file. LAN profiles only -
/// cloud-mode printers have no reachable FTP endpoint.
///
/// Throws [FtpsException] (or whatever [sendPrint] raises) with a
/// user-presentable message; the caller surfaces it.
Future<void> startPlateSwap(
  PrinterProfile profile, {
  required ProjectFileSender sendPrint,
  PlateSwapBytesLoader loadBytes = loadBundledPlateSwap,
}) async {
  final log = LogBuffer.instance.add;
  if (profile.mode != PrinterMode.lan || profile.ip.isEmpty) {
    throw Exception('自动换盘仅支持局域网直连打印机');
  }
  log('[换盘] 读取内置换盘模型…');
  final bytes = await loadBytes();
  final md5Hex = md5.convert(bytes).toString();

  log('[换盘] FTPS 上传到 ${profile.ip}:990 /cache …');
  final ftp = FtpsClient(
    host: profile.ip,
    username: 'bblp',
    password: profile.accessCode,
    log: log,
  );
  try {
    await ftp.connect();
    await ftp.upload(
        directory: 'cache', name: kPlateSwapRemoteName, bytes: bytes);
  } finally {
    await ftp.close();
  }

  log('[换盘] 发送 project_file (md5=$md5Hex)…');
  final ok = await sendPrint(
    url: 'ftp:///cache/$kPlateSwapRemoteName',
    md5: md5Hex,
    name: '自动换盘',
  );
  if (!ok) {
    throw Exception('project_file 发送失败(打印机未连接)');
  }
  log('[换盘] 已发送,打印机会开始换盘流程');
}
