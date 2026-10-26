import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';
import 'camera_profile.dart';
import 'printer_profile.dart';

/// The standalone web service's config: one JSON file holding everything the
/// hub needs (settings + printers + cameras). Written by the app on every
/// config change, read by bin/hub.dart so the web service can run without the
/// GUI app.
///
/// The file lives next to helper.json / signing_key.pem in `~/.bambudeck/` and
/// carries the same trust level: it contains LAN access codes and camera URLs
/// in plaintext, so it stays in the user's own home directory.
class HubConfig {
  const HubConfig({
    this.settings = const AppSettings(),
    this.printers = const [],
    this.cameras = const [],
  });

  final AppSettings settings;
  final List<PrinterProfile> printers;
  final List<CameraProfile> cameras;

  Map<String, dynamic> toJson() => {
        'settings': settings.toJson(),
        'printers': [for (final p in printers) p.toJson()],
        'cameras': [for (final c in cameras) c.toJson()],
      };

  factory HubConfig.fromJson(Map<String, dynamic> j) {
    AppSettings settings = const AppSettings();
    final s = j['settings'];
    if (s is Map) settings = AppSettings.fromJson(s.cast<String, dynamic>());

    final printers = <PrinterProfile>[];
    final ps = j['printers'];
    if (ps is List) {
      for (final p in ps) {
        if (p is Map) printers.add(PrinterProfile.fromJson(p.cast<String, dynamic>()));
      }
    }

    final cameras = <CameraProfile>[];
    final cs = j['cameras'];
    if (cs is List) {
      for (final c in cs) {
        if (c is Map) cameras.add(CameraProfile.fromJson(c.cast<String, dynamic>()));
      }
    }

    return HubConfig(settings: settings, printers: printers, cameras: cameras);
  }
}

/// `~/.bambudeck/hub.json` — shared by the app (writer) and bin/hub.dart (reader).
Future<File> defaultHubConfigFile() async {
  final home = Platform.environment['HOME'] ?? '';
  return File('$home/.bambudeck/hub.json');
}

Future<HubConfig> loadHubConfig([File? file]) async {
  try {
    final f = file ?? await defaultHubConfigFile();
    if (!await f.exists()) return const HubConfig();
    return HubConfig.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  } catch (_) {
    return const HubConfig();
  }
}

Future<void> saveHubConfig(HubConfig config, [File? file]) async {
  final f = file ?? await defaultHubConfigFile();
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode(config.toJson()), flush: true);
}
