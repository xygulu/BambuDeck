import 'package:bambu_protocol/bambu_protocol.dart';

import 'camera_profile.dart';
import 'printer_profile.dart';

/// 「添加摄像头 → 打印机自带」的一份候选清单。
///
/// 2026-11-09 反馈:手机上新装的 App 打开添加对话框,「打印机自带」的
/// 打印机下拉是空的,而且没有任何解释 —— 用户只会得出「没法添加」。
/// 下拉里的候选、每台为什么不可用、默认选谁,统一在这里算,UI 只负责
/// 把结果摆出来(纯函数,有单测)。
class BuiltinCameraOption {
  const BuiltinCameraOption(this.printer, {required this.hasBuiltinCamera});

  final PrinterProfile printer;

  /// 已经有一台绑到这台打印机的机内摄像头(自动补挂或用户手加)。
  final bool hasBuiltinCamera;

  /// 机内画面凭局域网地址 + 访问码直连取流(判断与
  /// [CameraProfile.resolveUrl] 一致:云模式或没 IP 都取不到)。
  bool get usable =>
      printer.mode == PrinterMode.lan &&
      printer.ip.trim().isNotEmpty &&
      printer.accessCode.trim().isNotEmpty;

  /// 不能用的原因,直接给用户看;能用时为空串。
  String get blockedReason {
    if (printer.mode != PrinterMode.lan) return '云模式,没有局域网地址';
    if (printer.ip.trim().isEmpty) return '还没找到局域网 IP';
    if (printer.accessCode.trim().isEmpty) return '缺访问码';
    return '';
  }
}

/// 每台打印机一条,顺序跟打印机清单一致。
List<BuiltinCameraOption> builtinCameraOptions(
        List<PrinterProfile> printers, List<CameraProfile> cameras) =>
    [
      for (final p in printers)
        BuiltinCameraOption(
          p,
          hasBuiltinCamera: cameras.any((c) =>
              c.sourceType == CameraSourceType.bambu &&
              c.printerIds.contains(p.id)),
        ),
    ];

/// 添加时默认选中的打印机:第一台能取流、且还没加过机内摄像头的。
BuiltinCameraOption? defaultBuiltinCameraOption(
    List<BuiltinCameraOption> options) {
  for (final o in options) {
    if (o.usable && !o.hasBuiltinCamera) return o;
  }
  return null;
}
