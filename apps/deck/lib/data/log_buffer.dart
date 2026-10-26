import 'dart:async';

/// In-memory run log (connection diagnostics, command traces, cloud calls).
/// Ring-buffered: the oldest lines fall off past the cap. Shared by the MQTT
/// link's log seam and the settings log page; nothing here hits disk.
///
/// Pure Dart (no Flutter): the standalone web service (bin/hub.dart) keeps the
/// same log. The UI reads [lines] through a StreamBuilder; `print` mirrors to
/// the console exactly like the old debugPrint did.
class LogBuffer {
  LogBuffer._();
  static final instance = LogBuffer._();

  static const _cap = 800;

  final _controller = StreamController<List<String>>.broadcast();
  List<String> _lines = const <String>[];

  /// Pushes a new immutable snapshot on every change (the ring-buffer list is
  /// never mutated in place, so the StreamBuilder always rebuilds).
  Stream<List<String>> get lines => _controller.stream;

  /// Current snapshot (e.g. `StreamBuilder.initialData`).
  List<String> get value => _lines;

  /// Timestamped push; also mirrors to the console when attached.
  void add(String message) {
    final now = DateTime.now();
    final stamp =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    final next = [..._lines, '$stamp $message'];
    if (next.length > _cap) {
      next.removeRange(0, next.length - _cap);
    }
    _lines = next;
    _controller.add(next);
    // Mirror to the console like the old debugPrint did (the standalone
    // service has no debug console, stdout is its log).
    // ignore: avoid_print
    print(message);
  }

  /// Whole log as one clipboard-ready blob (settings -> 日志 -> 复制).
  String dump() => _lines.join('\n');

  void clear() {
    _lines = const <String>[];
    _controller.add(_lines);
  }
}
