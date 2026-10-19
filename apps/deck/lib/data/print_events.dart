import 'package:bambu_protocol/bambu_protocol.dart';

import 'app_settings.dart';
import 'printer_profile.dart';

/// Desktop local notification seam. The real implementation lands in
/// main.dart (flutter_local_notifications); tests plug a recorder.
abstract class DeckNotifier {
  Future<void> show({required String title, required String body});
}

/// No-op used until main() installs the platform one (and in tests).
class NullDeckNotifier implements DeckNotifier {
  const NullDeckNotifier();

  @override
  Future<void> show({required String title, required String body}) async {}
}

/// Currently installed notifier; swapped at startup.
DeckNotifier deckNotifier = const NullDeckNotifier();

/// Watches per-printer state transitions and raises notifications:
/// task FINISH / FAILED, and error onset with the sentence-table text.
/// Lives outside Riverpod so the connection listeners can call it
/// without rebuild plumbing; tests construct their own instance.
class PrintEventWatcher {
  PrintEventWatcher({DeckNotifier notifier = const NullDeckNotifier()})
      : _notifier = notifier;

  final DeckNotifier _notifier;

  /// Synced from appSettingsProvider by the app shell.
  AppSettings settings = const AppSettings();

  final _last = <String, BambuState>{};

  /// Feed one state update. Returns the notification title if one fired
  /// (handy for assertions); null otherwise.
  Future<String?> observe(
      PrinterProfile profile, BambuState? prev, BambuState next) async {
    _last[profile.id] = next;
    if (prev == null) return null; // first frame: nothing to transition from

    if (prev.gcodeState != GcodeState.finish &&
        next.gcodeState == GcodeState.finish &&
        settings.notifyOnFinish) {
      final title = '✅ 打印完成';
      await _notifier.show(title: title, body: _body(profile, next));
      return title;
    }
    if (prev.gcodeState != GcodeState.failed &&
        next.gcodeState == GcodeState.failed &&
        settings.notifyOnFinish) {
      final title = '❌ 打印失败';
      await _notifier.show(title: title, body: _body(profile, next));
      return title;
    }
    // Error onset only - HMS lists persist across frames, so notify once.
    if (!prev.hasError &&
        next.hasError &&
        settings.notifyOnError) {
      final title = '⚠ ${profile.name} 打印机报错';
      await _notifier.show(title: title, body: _errorBody(next));
      return title;
    }
    return null;
  }

  String _body(PrinterProfile profile, BambuState s) =>
      '${profile.name}${s.subtaskName.isEmpty ? '' : ' · ${s.subtaskName}'}'
      ' · ${s.progress}%';

  /// First HMS sentence if the table knows the code, else the print_error
  /// sentence, else the raw codes.
  String _errorBody(BambuState s) {
    if (s.hms.isNotEmpty) {
      final e = s.hms.first;
      return hmsDescription(e) ?? e.ecode;
    }
    if (s.printError != 0) {
      return printErrorDescription(s.printError) ??
          'print_error ${s.printError}';
    }
    return '打印机上报了错误';
  }
}

/// App-wide watcher instance, driven by the connection listeners.
final printEvents = PrintEventWatcher();
