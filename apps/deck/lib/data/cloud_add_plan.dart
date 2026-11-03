import 'package:bambu_protocol/bambu_protocol.dart';

import 'printer_profile.dart';

/// 「云端一键添加」的决策结果(纯函数,便于测试)。
///
/// 分成三堆:
///  * [toAdd]  本地还没有的打印机 —— 交给调用方逐台保存;
///  * [patches] 本地已有、但没有访问码而云端这次给了码的打印机 —— 就地补码,
///    不重复添加。恢复数据/换机之后打印机没有访问码时,这是唯一能把码补回来
///    的入口(2026-11-03);
///  * [skipped] 本地已有且访问码已一致 —— 什么都不用做。
class CloudAddPlan {
  const CloudAddPlan({
    required this.toAdd,
    required this.patches,
    required this.skipped,
  });

  final List<CloudDevice> toAdd;

  /// 打印机 id → 补码后的完整档案。
  final Map<String, PrinterProfile> patches;

  final int skipped;

  bool get isNoop => toAdd.isEmpty && patches.isEmpty;
}

/// 按序列号匹配本地与云端设备。云端没登录出序列号时按 devId 兜底。
CloudAddPlan planCloudAdd({
  required List<PrinterProfile> existing,
  required List<CloudDevice> devices,
  required String token,
  required String userId,
}) {
  final existingBySerial = <String, PrinterProfile>{
    for (final p in existing)
      if (p.serial.trim().isNotEmpty) p.serial.trim(): p,
  };
  final toAdd = <CloudDevice>[];
  final patches = <String, PrinterProfile>{};
  var skipped = 0;
  for (final d in devices) {
    final match = existingBySerial[d.devId.trim()];
    if (match == null) {
      toAdd.add(d);
      continue;
    }
    if (d.accessCode.isNotEmpty && match.accessCode != d.accessCode) {
      patches[match.id] = match.copyWith(
        accessCode: d.accessCode,
        token: token,
        userId: userId,
      );
    } else {
      skipped++;
    }
  }
  return CloudAddPlan(toAdd: toAdd, patches: patches, skipped: skipped);
}
