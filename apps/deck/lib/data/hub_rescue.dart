import 'package:bambu_protocol/bambu_protocol.dart';

import 'app_settings.dart';
import 'camera_profile.dart';
import 'hub_config.dart';
import 'printer_profile.dart';

/// 启动自救回填(2026-11-02 事故修复)。
///
/// App 的 printers/cameras/settings 存 OS 安全存储(macOS Keychain),而更新
/// 换包(adhoc 签名每次构建身份都不同)会让部分 Keychain 条目对新二进制不再
/// 可读/回到默认 —— 数据其实还在盘上最近一次导出的 `~/.bambudeck/hub.json`
/// 里。这里在首次导出**之前**按「本地为权威,只补本地缺的」把盘上数据合回
/// 来,三条铁律:
///   1. 本地非空字段永不改写(用户在 App 里改过的值最大);
///   2. 只在有实际变化时返回新值,null = 无变化,调用方据此跳过落盘;
///   3. settings 在「本地整包=出厂默认而盘上有货」时整包采纳(Keychain 整包
///      丢失的形态),否则只逐字段补空着的密钥/地址类字段。
///
/// 调用方(main.dart)必须在自救完成前扣住 _exportHub,否则会把降级状态写回
/// 盘上、冲掉自救的数据源 —— 2026-11-02 19:56 就是这么丢的。
typedef HubRescueResult = ({
  AppSettings? settings,
  List<PrinterProfile>? printers,
  List<CameraProfile>? cameras,
});

HubRescueResult rescueHubData({
  required AppSettings settings,
  required List<PrinterProfile> printers,
  required List<CameraProfile> cameras,
  required HubConfig disk,
}) {
  return (
    settings: rescueSettings(settings, disk.settings),
    printers: rescuePrinters(printers, disk.printers),
    cameras: rescueCameras(cameras, disk.cameras),
  );
}

/// 本地是否整包处于出厂默认(= Keychain 设置条目大概率丢了)。
bool settingsLookDefault(AppSettings s) {
  const d = AppSettings();
  bool strEq(String a, String b) => a == b;
  return s.notifyOnFinish == d.notifyOnFinish &&
      s.notifyOnError == d.notifyOnError &&
      s.kioskMode == d.kioskMode &&
      s.kioskRotateSec == d.kioskRotateSec &&
      s.builtinCamDefault == d.builtinCamDefault &&
      s.cameraMuted == d.cameraMuted &&
      strEq(s.ezvizAppKey, d.ezvizAppKey) &&
      strEq(s.ezvizAppSecret, d.ezvizAppSecret) &&
      s.visionEnabled == d.visionEnabled &&
      strEq(s.visionBaseUrl, d.visionBaseUrl) &&
      strEq(s.visionApiKey, d.visionApiKey) &&
      strEq(s.visionModel, d.visionModel) &&
      strEq(s.visionFallbackBaseUrl, d.visionFallbackBaseUrl) &&
      strEq(s.visionFallbackApiKey, d.visionFallbackApiKey) &&
      strEq(s.visionFallbackModel, d.visionFallbackModel) &&
      s.visionIntervalSec == d.visionIntervalSec &&
      s.visionAutoPause == d.visionAutoPause &&
      s.hubEnabled == d.hubEnabled &&
      s.hubPort == d.hubPort &&
      strEq(s.hubToken, d.hubToken) &&
      strEq(s.helperUrl, d.helperUrl) &&
      strEq(s.helperToken, d.helperToken) &&
      s.printerSortMode == d.printerSortMode &&
      s.cameraSortMode == d.cameraSortMode;
}

AppSettings? rescueSettings(AppSettings local, AppSettings disk) {
  if (settingsLookDefault(local)) {
    if (settingsLookDefault(disk)) return null; // 两边都默认,没得救也没必要
    return disk; // 本地整包丢了 → 盘上整包拿回
  }
  // 本地有用户改过的痕迹:只补空着的密钥/地址类字段。
  final out = local.copyWith(
    ezvizAppKey: local.ezvizAppKey.isEmpty ? disk.ezvizAppKey : null,
    ezvizAppSecret: local.ezvizAppSecret.isEmpty ? disk.ezvizAppSecret : null,
    visionApiKey: local.visionApiKey.isEmpty ? disk.visionApiKey : null,
    visionFallbackApiKey:
        local.visionFallbackApiKey.isEmpty ? disk.visionFallbackApiKey : null,
    hubToken: local.hubToken.isEmpty ? disk.hubToken : null,
    helperUrl: local.helperUrl.isEmpty ? disk.helperUrl : null,
    helperToken: local.helperToken.isEmpty ? disk.helperToken : null,
  );
  // AppSettings 未实现 ==(逐字段比),copyWith 恒返新实例,不能拿 == 判变化。
  final changed = out.ezvizAppKey != local.ezvizAppKey ||
      out.ezvizAppSecret != local.ezvizAppSecret ||
      out.visionApiKey != local.visionApiKey ||
      out.visionFallbackApiKey != local.visionFallbackApiKey ||
      out.hubToken != local.hubToken ||
      out.helperUrl != local.helperUrl ||
      out.helperToken != local.helperToken;
  return changed ? out : null;
}

/// 打印机按 serial 匹配(无 serial 退回 id):本地缺 ip/访问码/云凭据/归属
/// 时采纳盘上值,采纳 ip 时顺手把云模式升级 LAN 直连;盘上多出的照单收进
/// 本地清单(两端清单本来就该一致)。
List<PrinterProfile>? rescuePrinters(
    List<PrinterProfile> local, List<PrinterProfile> disk) {
  String key(PrinterProfile p) =>
      p.serial.trim().isNotEmpty ? 's:${p.serial.trim()}' : 'i:${p.id}';
  final diskByKey = {for (final p in disk) key(p): p};
  final localKeys = <String>{};
  var changed = false;
  final out = <PrinterProfile>[];
  for (final p in local) {
    localKeys.add(key(p));
    final d = diskByKey[key(p)];
    if (d == null) {
      out.add(p);
      continue;
    }
    final adoptIp = p.ip.trim().isEmpty && d.ip.trim().isNotEmpty;
    final next = p.copyWith(
      ip: adoptIp ? d.ip : null,
      mode: adoptIp && p.mode != PrinterMode.lan ? PrinterMode.lan : null,
      accessCode: p.accessCode.isEmpty ? d.accessCode : null,
      token: p.token.isEmpty ? d.token : null,
      userId: p.userId.isEmpty ? d.userId : null,
      accountId: p.accountId.isEmpty ? d.accountId : null,
    );
    if (next.ip != p.ip ||
        next.mode != p.mode ||
        next.accessCode != p.accessCode ||
        next.token != p.token ||
        next.userId != p.userId ||
        next.accountId != p.accountId) {
      changed = true;
      out.add(next);
    } else {
      out.add(p);
    }
  }
  for (final d in disk) {
    if (!localKeys.contains(key(d))) {
      out.add(d);
      changed = true;
    }
  }
  return changed ? out : null;
}

/// 摄像头按 id 并集:本地条目原样保留,盘上多出的补到队尾。
List<CameraProfile>? rescueCameras(
    List<CameraProfile> local, List<CameraProfile> disk) {
  final ids = {for (final c in local) c.id};
  final extra = disk.where((c) => !ids.contains(c.id)).toList();
  return extra.isEmpty ? null : [...local, ...extra];
}

/// 导出时的打印机清单合并(2026-11-03,「更新后数据被清空」的第二道闸)。
///
/// App 把清单导出到 `~/.bambudeck/hub.json` 给网页服务用。但导出是**覆盖
/// 式**的:App 里少一台,盘上就少一台。而 App 的清单可能因为存储层降级
/// (Keychain 砖化 / 新存储第一次为空)而少 —— 那一刻用户并没有删打印机,
/// 只是 App 读不到,导出却把「读不到」当成了「用户删了」,盘上数据被清空。
///
/// 判定原则:**只有用户显式删除过的那台才允许消失**,其余一律以盘上为准。
/// 显式删除由 [tombstoned] 给出(调用方在 remove 时记一笔)。
///
/// 归属规则:
///   - 云账号打印机(accountId 非空):App 是权威(云同步/网页端管它们),
///     但盘上多出的仍保留 —— 云端下架由云同步那条路径处理,不靠导出。
///   - 手工打印机(accountId 为空):盘上是权威。App 有就以 App 为准(改名/
///     填访问码等编辑要生效),App 没有但墓碑里也没有 → 保留盘上那条。
///
/// 返回合并后的清单(顺序:App 的在前,盘上多出的追加到队尾,与
/// [rescuePrinters] 的习惯一致)。
List<PrinterProfile> mergeExportPrinters({
  required List<PrinterProfile> app,
  required List<PrinterProfile> disk,
  Set<String> tombstoned = const {},
}) {
  String key(PrinterProfile p) =>
      p.serial.trim().isNotEmpty ? 's:${p.serial.trim()}' : 'i:${p.id}';

  // App 里的云账号归属要带回来(账号是网页端/云同步的地盘,App 侧可能没有)。
  final accountIdBySerial = {
    for (final p in disk)
      if (p.accountId.isNotEmpty && p.serial.trim().isNotEmpty)
        p.serial.trim(): p.accountId,
  };

  final out = <PrinterProfile>[];
  final seen = <String>{};
  for (final p in app) {
    final k = key(p);
    if (!seen.add(k)) continue;
    final acc = accountIdBySerial[p.serial.trim()];
    out.add(acc != null && p.accountId.isEmpty ? p.copyWith(accountId: acc) : p);
  }
  for (final p in disk) {
    final k = key(p);
    if (seen.contains(k)) continue;
    // 盘上多出的手工打印机:除非用户明确删过,否则保留 —— 这就是「导出不得
    // 清空用户数据」的闸门。
    if (tombstoned.contains(k)) continue;
    if (p.accountId.isNotEmpty) {
      // 云账号打印机:App 侧没有就是 App 删的?——不,云端下架走云同步。
      // 保守起见也保留(除非墓碑),避免网页端/App 任一侧读空就清空对方。
      if (!seen.add(k)) continue;
      out.add(p);
      continue;
    }
    if (!seen.add(k)) continue;
    out.add(p);
  }
  return out;
}

/// 为「有访问码」的打印机补一台绑定的机内摄像头 (2026-11-03 需求:
/// 云端批量接入打印机后机内摄像头自动出现)。
///
/// 2026-11-09 修正:以前还要求「LAN 模式或已有 IP」,导致手机上刚用云端账号
/// 添加的打印机(云模式、码有了但还没扫到 IP)永远补不上摄像头 —— 用户看到
/// 的就是「自带摄像头加不了」。机内画面的地址/码本来就是播放时从绑定的打印机
/// 档案现取的,所以码一到就可以把摄像头建出来:先以离线形态出现,等补扫把
/// IP 填上、云升 LAN 后自动亮。
///
/// [deletedIds] 是用户显式删过的摄像头 id(墓碑)。删掉的不再复活;调用方
/// 可以每轮都调用本函数,幂等且不会把用户删掉的加回来。
/// 返回 null = 没有要补的。
List<CameraProfile>? ensureBuiltinCameras(
  List<PrinterProfile> printers,
  List<CameraProfile> cameras, {
  Set<String> deletedIds = const {},
}) {
  final out = <CameraProfile>[];
  for (final p in printers) {
    if (p.accessCode.trim().isEmpty) continue;
    final camId =
        'bambu_${p.serial.trim().isNotEmpty ? p.serial.trim() : p.id}';
    // 墓碑按「c:<id>」记 (CamerasNotifier.remove), 两种写法都认。
    if (deletedIds.contains(camId) || deletedIds.contains('c:$camId')) {
      continue;
    }
    final exists = cameras.any((c) =>
        c.sourceType == CameraSourceType.bambu &&
        (c.printerIds.contains(p.id) || c.id == camId));
    if (exists) continue;
    out.add(CameraProfile(
      id: camId,
      name: '${p.name} 摄像头',
      sourceType: CameraSourceType.bambu,
      printerIds: [p.id],
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }
  return out.isEmpty ? null : [...cameras, ...out];
}
