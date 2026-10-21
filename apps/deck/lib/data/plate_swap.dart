import 'dart:io';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'cloud_print_helper.dart';
import 'ftps_client.dart';
import 'log_buffer.dart';
import 'printer_profile.dart';

/// The bundled plate-swap model (单盘换盘): its tail gcode shakes the finished
/// print off the plate and feeds the plate forward - "printing" it is the
/// plate swap. 3mf container, ~222 KB.
const kPlateSwapAsset = 'assets/plate_swap/auto_plate_swap.3mf';

/// Remote name on the printer's FTP; ASCII-only so no FTP encoding surprises.
const kPlateSwapRemoteName = 'bambudeck_plate_swap.3mf';

/// md5 of the gcode INSIDE the swap 3mf (`Metadata/plate_1.gcode`), not the
/// whole container. 2025+ firmware verifies this against the file it loads
/// and rejects the job (84033544) on a mismatch — the whole-3mf md5 silently
/// no-ops the swap (换盘无响应 2026-10-21, fixed by matching Studio's value).
/// ⚠️ 换盘模型文件一旦更新,必须同步重算此值(`unzip -p auto_plate_swap.3mf
/// Metadata/plate_1.gcode | md5 -q`)并更新这里,否则换盘会退回静默失败。
const kPlateSwapGcodeMd5 = 'e4a7d057f1ad9863849edda40f551570';

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
  ({int amsId, int slot})? ams,
});

Future<Uint8List> loadBundledPlateSwap() async =>
    (await rootBundle.load(kPlateSwapAsset)).buffer.asUint8List();

/// 换盘模型按单耗材 PLA 切片(slice_info.config type="PLA"),所以在打印机
/// 当前 AMS 里选一个类型匹配的槽位喂料;颜色不挑(用户 2026-10-21)。每次
/// 点击换盘都要重新读取,拿到的就是 report 流里的实时 AMS 状态。找不到
/// PLA(AMS 空或全是不匹配类型)时返回 null - 打印改走外置料。
({int amsId, int slot})? pickSwapAmsSlot(AmsState? ams) {
  if (ams == null) return null;
  for (final unit in ams.units) {
    for (var i = 0; i < unit.trays.length; i++) {
      final tray = unit.trays[i];
      // "PLA Matte"/"PLA-AERO" 也算 PLA 系;PETG/ABS 等不匹配。
      if (tray.present && tray.type.toUpperCase().contains('PLA')) {
        return (amsId: unit.id, slot: i);
      }
    }
  }
  return null;
}

/// One-click 自动换盘: uploads the bundled swap model to the printer's
/// `/cache` over FTPS, then tells it to print that file. LAN profiles only -
/// cloud-mode printers have no reachable FTP endpoint. [ams] is the AMS slot
/// chosen by [pickSwapAmsSlot] from the live printer state; null prints from
/// the external spool.
///
/// Throws [FtpsException] (or whatever [sendPrint] raises) with a
/// user-presentable message; the caller surfaces it.
Future<void> startPlateSwap(
  PrinterProfile profile, {
  required ProjectFileSender sendPrint,
  PlateSwapBytesLoader loadBytes = loadBundledPlateSwap,
  ({int amsId, int slot})? ams,
}) async {
  final log = LogBuffer.instance.add;
  if (profile.mode != PrinterMode.lan || profile.ip.isEmpty) {
    throw Exception('自动换盘仅支持局域网直连打印机');
  }
  log('[换盘] 读取内置换盘模型…');
  final bytes = await loadBytes();
  // 固件校验的是 3mf 内嵌 gcode 的 md5,不是整个容器(整个 3mf 的 md5 会
  // 静默 no-op,换盘无响应 2026-10-21)。换盘模型是打包资产,gcode 恒定。
  final md5Hex = kPlateSwapGcodeMd5;

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
    // STOR 226 只说明服务器收了流 - /cache 在 Studio 文件列表里看不见,
    // 必须回读确认文件真的落盘(换盘 2026-10-21)。
    await ftp.verifyUpload(
        directory: 'cache',
        name: kPlateSwapRemoteName,
        expectedBytes: bytes.length);
  } finally {
    await ftp.close();
  }

  log('[换盘] 发送 project_file (md5=$md5Hex, '
      '${ams == null ? "外置料" : "AMS${ams.amsId} 槽${ams.slot + 1}"})…');
  final ok = await sendPrint(
    url: 'ftp:///cache/$kPlateSwapRemoteName',
    md5: md5Hex,
    name: '自动换盘',
    ams: ams,
  );
  if (!ok) {
    throw Exception('project_file 发送失败(打印机未连接)');
  }
  log('[换盘] 已发送,打印机会开始换盘流程');
}

/// Cloud-mode 换盘: 云端打印机没有可达的 FTP 端点, 把内置换盘模型交给
/// Bambu Connect(持有拓竹合法客户端身份)经本机 helper 云端派单。无需开发者
/// 模式、无需局域网。返回 helper 的派单结果, 由调用方决定怎么提示用户。
Future<CloudPrintResult> startCloudPlateSwap(
  PrinterProfile profile, {
  PlateSwapBytesLoader loadBytes = loadBundledPlateSwap,
}) async {
  final log = LogBuffer.instance.add;
  log('[换盘] 读取内置换盘模型…');
  final bytes = await loadBytes();
  final file = await _writeSwapModelToTemp(bytes);
  log('[换盘] 通过 Bambu Connect 云端派单到 ${profile.name} '
      '(serial=${profile.serial})…');
  return CloudPrintHelper.instance.print(file.path, serial: profile.serial);
}

/// 把换盘模型字节写到稳定的临时路径, 供 Bambu Connect 的 deeplink 导入
/// (Connect 按文件名匹配派单后的任务)。文件名与局域网路径复用同一个, 便于
/// 日志/排查对齐。
Future<File> _writeSwapModelToTemp(Uint8List bytes) async {
  final file = File('${Directory.systemTemp.path}/$kPlateSwapRemoteName');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
