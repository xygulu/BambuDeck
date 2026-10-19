import 'package:flutter/foundation.dart';

/// In-memory run log (connection diagnostics, command traces, cloud calls).
/// Ring-buffered: the oldest lines fall off past the cap. Shared by the MQTT
/// link's log seam and the settings log page; nothing here hits disk.
class LogBuffer {
  LogBuffer._();
  static final instance = LogBuffer._();

  static const _cap = 800;

  final ValueNotifier<List<String>> lines =
      ValueNotifier<List<String>>(const <String>[]);

  /// Timestamped push; also mirrors to the debug console when attached.
  void add(String message) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final next = [...lines.value, '$stamp $message'];
    if (next.length > _cap) {
      next.removeRange(0, next.length - _cap);
    }
    lines.value = next;
    debugPrint(message);
  }

  /// Whole log as one clipboard-ready blob (settings -> 日志 -> 复制).
  String dump() => lines.value.join('\n');

  void clear() => lines.value = const <String>[];
}
