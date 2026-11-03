import 'dart:convert';
import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'app_settings.dart';
import 'camera_profile.dart';
import 'printer_profile.dart';

/// 一个登录了的拓竹云账号（网页登录向导的产物，2026-10-28 产品化）。token 是
/// bind 列表轮询的活凭据；`suspended` = 用户暂定使用：保留配置但停止同步与
/// 监控；「退出」= 从 accounts 里删除该条目（其打印机一并下架）。
class CloudAccount {
  const CloudAccount({
    required this.id,
    required this.region,
    required this.account,
    this.accessToken = '',
    this.userId = '',
    this.suspended = false,
    this.createdAt = 0,
  });

  final String id;
  final CloudRegion region;
  final String account; // email / 手机号
  final String accessToken;
  final String userId; // "u_{uid}"，云 MQTT 用户名用
  final bool suspended;
  final int createdAt; // 毫秒时间戳

  Map<String, dynamic> toJson() => {
        'id': id,
        'region': region.name,
        'account': account,
        'accessToken': accessToken,
        'userId': userId,
        'suspended': suspended,
        'createdAt': createdAt,
      };

  factory CloudAccount.fromJson(Map<String, dynamic> j) => CloudAccount(
        id: j['id'] as String? ?? '',
        region: CloudRegion.values
            .byName(j['region'] as String? ?? CloudRegion.cn.name),
        account: j['account'] as String? ?? '',
        accessToken: j['accessToken'] as String? ?? '',
        userId: j['userId'] as String? ?? '',
        suspended: j['suspended'] as bool? ?? false,
        createdAt: j['createdAt'] as int? ?? 0,
      );

  CloudAccount copyWith({
    String? accessToken,
    String? userId,
    bool? suspended,
  }) =>
      CloudAccount(
        id: id,
        region: region,
        account: account,
        accessToken: accessToken ?? this.accessToken,
        userId: userId ?? this.userId,
        suspended: suspended ?? this.suspended,
        createdAt: createdAt,
      );
}

/// The standalone web service's config: one JSON file holding everything the
/// hub needs (settings + printers + cameras). Written by the app on every
/// config change, read by bin/hub.dart so the web service can run without the
/// GUI app.
///
/// The file lives next to helper.json / signing_key.pem in `~/.bambudeck/` and
/// carries the same trust level: it contains LAN access codes and camera URLs
/// in plaintext, so it stays in the user's own home directory.
///
/// `accounts` 是产品化后新增的段：登录的拓竹云账号清单。它的所有权在网页服务
/// （登录向导/云同步）手里 —— Mac App 导出时原样保留（main.dart 的 _exportHub），
/// 两个写入方各管各的段。
class HubConfig {
  const HubConfig({
    this.settings = const AppSettings(),
    this.printers = const [],
    this.cameras = const [],
    this.accounts = const [],
  });

  final AppSettings settings;
  final List<PrinterProfile> printers;
  final List<CameraProfile> cameras;
  final List<CloudAccount> accounts;

  Map<String, dynamic> toJson() => {
        'settings': settings.toJson(),
        'printers': [for (final p in printers) p.toJson()],
        'cameras': [for (final c in cameras) c.toJson()],
        'accounts': [for (final a in accounts) a.toJson()],
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

    final accounts = <CloudAccount>[];
    final as_ = j['accounts'];
    if (as_ is List) {
      for (final a in as_) {
        if (a is Map) accounts.add(CloudAccount.fromJson(a.cast<String, dynamic>()));
      }
    }

    return HubConfig(
      settings: settings,
      printers: printers,
      cameras: cameras,
      accounts: accounts,
    );
  }
}

/// `~/.bambudeck/hub.json` — shared by the app (writer) and bin/hub.dart (reader).
/// Windows 没有 HOME, 用 USERPROFILE 兜底 (另一台 Windows 机器部署 deck_hub)。
Future<File> defaultHubConfigFile() async {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';
  return File('$home/.bambudeck/hub.json');
}

Future<HubConfig> loadHubConfig([File? file]) async {
  final f = file ?? await defaultHubConfigFile();
  // 主文件坏了(半截 JSON / 空文件)先试 .bak —— 旧版这里直接返回空配置,
  // 于是「文件里还有数据但读不出来」被当成「本来就没数据」,App 顺势把空清单
  // 写回盘上,数据就没了(2026-11-03 事故链的最后一环)。
  Future<HubConfig?> fromFile(File p) async {
    try {
      if (!await p.exists()) return null;
      final raw = await p.readAsString();
      if (raw.trim().isEmpty) return null;
      return HubConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  final main = await fromFile(f);
  if (main != null) return main;
  final bak = await fromFile(File('${f.path}.bak'));
  if (bak != null) return bak;
  return const HubConfig();
}

/// 原子写 + `.bak` 轮转(2026-11-03)。
///
/// 旧实现是裸 `writeAsString`:写到一半断电/被杀,hub.json 就是半截 JSON,
/// 下次读出来直接 `HubConfig()`(全空)—— 数据在文件里但读不出来,等于丢。
/// 现在:先落 `.tmp` → 旧文件轮转为 `.bak` → `.tmp` rename 上位。rename 在
/// 同一文件系统内是原子的,读者永远看到完整的旧版或完整的新版;万一新文件
/// 本身有问题,`.bak` 里还有上一版完整数据。
Future<void> saveHubConfig(HubConfig config, [File? file]) async {
  final f = file ?? await defaultHubConfigFile();
  await f.parent.create(recursive: true);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
  if (await f.exists()) {
    try {
      await f.rename('${f.path}.bak');
    } on FileSystemException {
      // 旧文件挪不动(被占用等):保留主文件,直接覆盖上位,不影响正确性。
      try {
        await tmp.delete();
      } on FileSystemException {
        // 忽略。
      }
      await f.writeAsString(jsonEncode(config.toJson()), flush: true);
      return;
    }
  }
  await tmp.rename(f.path);
}
