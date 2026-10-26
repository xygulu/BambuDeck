import 'app_settings.dart';
import 'camera_profile.dart';
import 'printer_profile.dart';

/// Stable sort of the printer list by the chosen mode (列表排序
/// 2026-10-27)。manual 原样返回; 其余模式以存储顺序为并列时的次序
/// (Dart 的 sort 不稳定, 显式拿原下标做决胜), 存储顺序本身不动。
List<PrinterProfile> sortPrinters(List<PrinterProfile> list, ListSortMode mode) {
  if (mode == ListSortMode.manual) return list;
  final indexed = List<(int, PrinterProfile)>.generate(
      list.length, (i) => (i, list[i]));
  indexed.sort((a, b) {
    final r = _comparePrinter(a.$2, b.$2, mode);
    return r != 0 ? r : a.$1 - b.$1;
  });
  return [for (final e in indexed) e.$2];
}

List<CameraProfile> sortCameras(List<CameraProfile> list, ListSortMode mode) {
  if (mode == ListSortMode.manual) return list;
  final indexed = List<(int, CameraProfile)>.generate(
      list.length, (i) => (i, list[i]));
  indexed.sort((a, b) {
    final r = _compareCamera(a.$2, b.$2, mode);
    return r != 0 ? r : a.$1 - b.$1;
  });
  return [for (final e in indexed) e.$2];
}

int _comparePrinter(PrinterProfile a, PrinterProfile b, ListSortMode mode) =>
    switch (mode) {
      ListSortMode.manual => 0,
      ListSortMode.name => a.name.compareTo(b.name),
      // 类型 = 局域网在前, 云端在后; 同类型按名称。
      ListSortMode.type =>
        a.mode == b.mode ? a.name.compareTo(b.name) : (a.mode.index - b.mode.index),
      ListSortMode.addedTime => a.createdAt.compareTo(b.createdAt),
    };

int _compareCamera(CameraProfile a, CameraProfile b, ListSortMode mode) =>
    switch (mode) {
      ListSortMode.manual => 0,
      ListSortMode.name => a.name.compareTo(b.name),
      // 类型 = 打印机自带在前, RTSP/ONVIF 第三方在后 (枚举序是 rtsp 在前,
      // 不能拿 index 直接比); 同类型按名称。
      ListSortMode.type => a.sourceType == b.sourceType
          ? a.name.compareTo(b.name)
          : ((a.sourceType == CameraSourceType.bambu ? 0 : 1) -
              (b.sourceType == CameraSourceType.bambu ? 0 : 1)),
      ListSortMode.addedTime => a.createdAt.compareTo(b.createdAt),
    };
