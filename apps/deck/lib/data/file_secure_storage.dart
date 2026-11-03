import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_settings.dart';
import 'camera_profile.dart';
import 'hub_rescue.dart';
import 'printer_profile.dart';

/// macOS 专用文件安全存储(2026-11-03 事故根治)。
///
/// Keychain 的访问判定挂在代码签名身份上:CI 的包是未签名产物 + adhoc 补签
/// (无 entitlements),DP Keychain 读永远空、写直接抛(等于砖化);legacy
/// Keychain 换一次签名就要重新授权,无人值守时读还会直接被拒。两种形态都会
/// 在「更新换包」时把用户数据变成读不出来 —— 0600 文件与签名身份完全解耦,
/// 更新永不触碰 `~/.bambudeck/`,这是把「更新后数据被清空」这一类问题连根
/// 拔掉的根本手段。凭据明文落盘的信任级别与 hub.json 一致(hub 服务本来就
/// 需要明文凭据才能工作)。
///
/// 可靠性三件套:临时文件 + rename 原子落盘;每次写盘前把旧内容轮转为
/// `.bak`,主文件损坏时自动回退;.bak 也损坏才返回空(此时 hub_rescue 仍可
/// 从 hub.json 把数据合回来)。
class FileSecureStorage implements SecureStorageAdapter {
  FileSecureStorage(this.path) {
    _bakPath = '$path.bak';
    _tmpPath = '$path.tmp';
  }

  final String path;
  late final String _bakPath;
  late final String _tmpPath;

  Map<String, String>? _cache;
  Future<void>? _queue;

  Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    Map<String, String> read(String p) {
      final raw = File(p).readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not a map');
      return decoded.map((k, v) => MapEntry(k as String, v as String));
    }

    Map<String, String> m;
    try {
      m = read(path);
    } catch (_) {
      try {
        m = read(_bakPath);
      } catch (_) {
        m = {};
      }
    }
    _cache = m;
    return m;
  }

  @override
  Future<String?> read(String key) async {
    final m = await _load();
    return m[key];
  }

  @override
  Future<void> write(String key, String value) {
    // 写入串行化:三个 store 并发 save 时避免「读-改-写」互相覆盖。
    _queue =
        (_queue ?? Future<void>.value()).then((_) => _writeNow(key, value));
    return _queue!;
  }

  Future<void> _writeNow(String key, String value) async {
    final m = Map<String, String>.from(await _load());
    m[key] = value;
    _cache = m;
    final f = File(path);
    await f.parent.create(recursive: true);
    // 原子写:先落 .tmp,再把旧主文件轮转为 .bak,最后 rename 上位。
    final tmp = File(_tmpPath);
    await tmp.writeAsString(jsonEncode(m), flush: true);
    if (await f.exists()) {
      try {
        await f.rename(_bakPath);
      } on FileSystemException {
        // 首次没有旧文件/占用等:忽略,bak 缺失不影响正确性。
      }
    }
    await tmp.rename(path);
    try {
      await Process.run('chmod', <String>['600', path]);
    } catch (_) {
      // 权限收紧尽力而为,失败不阻断。
    }
  }
}

/// 三个 store 的键(store 类里是私有常量,这里同步维护)。
const _printerKey = 'bambudeck.printers';
const _settingsKey = 'bambudeck.settings';
const _cameraKey = 'bambudeck.cameras';

/// 启动种子迁移(必须先于任何 store 读取执行)。
///
/// 文件存储是新事物,历史数据还躺在 Keychain 里:legacy(false 选项)是
/// 2026-11-03 修复后 App 在用的库,DP(默认)是更早团队签名构建留下的、
/// 事故中被孤儿化的条目 —— 那里可能有文件里已经丢掉的打印机访问码和萤石/
/// 视觉密钥。规则:**文件为权威,Keychain 只补缺**(逐段复用 hub_rescue 的
/// 合并函数),用户在文件里改过的值永不被旧数据覆盖。每次启动都跑,代价是
/// 几次 Keychain 读;当用户在 Xcode 里续期 profile、重新用团队签名构建后,
/// DP 条目恢复可读,其中的访问码会自动流回文件。
Future<void> seedFileStore(
  FileSecureStorage storage, {
  FlutterSecureStorage? legacySource,
  FlutterSecureStorage? dpSource,
}) async {
  final legacy = legacySource ??
      const FlutterSecureStorage(
          mOptions: MacOsOptions(useDataProtectionKeyChain: false));
  final dp = dpSource ?? const FlutterSecureStorage();

  Future<Map<String, String>?> tryRead(
      FlutterSecureStorage s, String key) async {
    try {
      // 超时兜底:换过签名的机器上,读旧 Keychain 条目可能弹授权框并一直
      // 等待点击 —— 这里在启动路径上,绝不能把 App 卡死在「没响应」。等不到
      // 就当没有,文件存储本身不受影响。
      final v = await s
          .read(key: key)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
      return (v == null || v.isEmpty) ? null : {key: v};
    } catch (_) {
      // Keychain 拒读(交互不允许等):安静跳过,不影响文件存储自身。
      return null;
    }
  }

  // 依次用 legacy → DP 的条目给文件补缺;同一键两个来源都有时,先到的
  // (legacy,更新)已经把非空字段占住,后到的(更旧)只能填真空缺。
  for (final src in [legacy, dp]) {
    for (final key in [_printerKey, _settingsKey, _cameraKey]) {
      final got = await tryRead(src, key);
      if (got == null) continue;
      final have = await storage.read(key);
      if (have == null) {
        await storage.write(key, got[key]!);
        continue;
      }
      await storage.write(key, mergeSeedSegment(key, have, got[key]!));
    }
  }
}

/// 文件侧(本地权威)与 Keychain 侧(补缺来源)逐段合并,返回合并后的 JSON。
/// 公开便于测试(纯函数,不碰 Keychain)。
String mergeSeedSegment(String key, String localRaw, String seedRaw) {
  try {
    if (key == _settingsKey) {
      final merged = rescueSettings(AppSettings.fromJson(
            jsonDecode(localRaw) as Map<String, dynamic>,
          ),
          AppSettings.fromJson(jsonDecode(seedRaw) as Map<String, dynamic>));
      return jsonEncode((merged ?? AppSettings.fromJson(
            jsonDecode(localRaw) as Map<String, dynamic>,
          )).toJson());
    }
    if (key == _printerKey) {
      List<PrinterProfile> parse(String raw) =>
          (jsonDecode(raw) as List).whereType<Map<String, dynamic>>().map(
                PrinterProfile.fromJson,
              ).toList();
      final merged = rescuePrinters(parse(localRaw), parse(seedRaw));
      return jsonEncode(
          (merged ?? parse(localRaw)).map((p) => p.toJson()).toList());
    }
    if (key == _cameraKey) {
      List<CameraProfile> parse(String raw) =>
          (jsonDecode(raw) as List).whereType<Map<String, dynamic>>().map(
                CameraProfile.fromJson,
              ).toList();
      final merged = rescueCameras(parse(localRaw), parse(seedRaw));
      return jsonEncode(
          (merged ?? parse(localRaw)).map((c) => c.toJson()).toList());
    }
  } catch (_) {
    // 半条损坏数据不值得让启动失败:保住本地原样。
  }
  return localRaw;
}
