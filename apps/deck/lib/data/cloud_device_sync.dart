import 'dart:async';
import 'dart:io';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'hub_config.dart';
import 'log_buffer.dart';
import 'printer_profile.dart';

/// 云端设备同步 —— 账号的 bind 列表是打印机清单的活源头（2026-10-28 产品化：
/// 网页登录即接入，打印机的增/删/改名跟随云端，不再手改配置文件）。
///
/// 所有权划分：PrinterProfile.accountId 非空的条目归本模块管；空串 = 手工
/// 添加，同步永不触碰（与 Mac App 的 hub.json 导出互不覆盖）。
///
/// 合并规则见 [mergeCloudDevices]（纯函数便于测试）。拉取失败沿用缓存清单，
/// 错误记在内存态 [status] 里，绝不动本地、绝不中断服务。
///
/// 落盘时机：只有设备清单真的变了才写 hub.json —— 写盘会触发 bin/hub.dart 的
/// mtime 监视退出重启（守护循环/launchd 拉起），同步元数据（[status]）落盘会
/// 造成每轮同步都重启，所以元数据只在内存。
class CloudDeviceSync {
  /// 每个账号最近一次同步结果（accountId → 状态，内存态）。
  final Map<String, AccountSyncStatus> status = {};

  bool _syncing = false;

  /// 同步所有活动账号（未暂定且有 token）。返回是否有设备变化（变化已写盘，
  /// 由调用方的 mtime 机制重启生效）。
  Future<bool> syncAll(HubConfig config, File configFile) async {
    final active = config.accounts
        .where((a) => !a.suspended && a.accessToken.isNotEmpty)
        .toList();
    if (active.isEmpty || _syncing) return false;
    _syncing = true;
    try {
      var printers = config.printers;
      var changed = false;
      final activeIds = active.map((a) => a.id).toSet();
      for (final acc in active) {
        List<CloudDevice> devices;
        try {
          devices = await fetchCloudDevices(acc.accessToken, acc.region)
              .timeout(const Duration(seconds: 20));
          status[acc.id] = AccountSyncStatus(
              ok: true, at: DateTime.now(), count: devices.length);
        } catch (e) {
          status[acc.id] = AccountSyncStatus(
              ok: false, at: DateTime.now(), error: '$e');
          LogBuffer.instance.add('[云同步] ${acc.account} 拉取失败，沿用缓存: $e');
          continue;
        }
        final (next, c) = mergeCloudDevices(
          printers: printers,
          account: acc,
          devices: devices,
        );
        printers = next;
        changed |= c;
      }
      // 孤儿清理：归属的账号已经不在列表里（退出/删除）→ 其打印机一并下架。
      final kept = printers
          .where((p) => p.accountId.isEmpty || activeIds.contains(p.accountId))
          .toList();
      if (kept.length != printers.length) changed = true;
      if (!changed) return false;
      await saveHubConfig(
        HubConfig(
          settings: config.settings,
          printers: kept,
          cameras: config.cameras,
          accounts: config.accounts,
        ),
        configFile,
      );
      LogBuffer.instance.add('[云同步] 设备清单有变化，已写入配置');
      return true;
    } finally {
      _syncing = false;
    }
  }
}

/// 一个账号最近一次同步的结果（内存态，供网页状态区展示）。
class AccountSyncStatus {
  const AccountSyncStatus({
    required this.ok,
    required this.at,
    this.count = 0,
    this.error = '',
  });

  final bool ok;
  final DateTime at;
  final int count;
  final String error;
}

/// 纯函数：把 [devices]（账号 [account] 的 bind 列表）合并进 [printers]。
/// 返回 `(新清单, 是否有变化)`。
///
/// - 云端有、本地无 → 入列：有访问码走 LAN 模式；没有走云模式（直接用账号
///   token/uid 监控，不等 LAN/SSDP 补 IP）；
/// - 两边都有（serial 相同）→ 云端权威：name（云端为空沿用本地）、accessCode
///   （云端非空才覆盖）、model；本地偏好（ip/builtinCam/autoPlateSwap）不动；
///   无归属的手工条目撞上即升级归属（accountId 填上，只发生一次）；
/// - 本地归属本账号、云端没有 → 移除（解绑即下架）；他账号的条目不动；
/// - mode 已是云模式的条目只刷新 accountId/名称，不动其 token。
(List<PrinterProfile>, bool) mergeCloudDevices({
  required List<PrinterProfile> printers,
  required CloudAccount account,
  required List<CloudDevice> devices,
}) {
  final bySerial = <String, CloudDevice>{
    for (final d in devices)
      if (d.devId.isNotEmpty) d.devId: d,
  };
  final out = <PrinterProfile>[];
  final claimed = <String>{};
  var changed = false;

  for (final p in printers) {
    final d = p.serial.isEmpty ? null : bySerial[p.serial];
    if (d == null) {
      // 云端没有：本账号的条目下架，其余保留。
      if (p.accountId == account.id) {
        changed = true;
        continue;
      }
      out.add(p);
      continue;
    }
    // 他账号的打印机，本账号的 bind 不碰（serial 先登记，防止下方当作
    // 「云端新设备」重复入列）。
    if (p.accountId.isNotEmpty && p.accountId != account.id) {
      claimed.add(d.devId);
      out.add(p);
      continue;
    }
    claimed.add(d.devId);
    var np = p;
    if (p.accountId != account.id) {
      np = np.copyWith(accountId: account.id);
      changed = true;
    }
    if (d.devName.isNotEmpty && d.devName != np.name) {
      np = np.copyWith(name: d.devName);
      changed = true;
    }
    if (d.accessCode.isNotEmpty && d.accessCode != np.accessCode) {
      // 拿到访问码：云模式升级为 LAN 直连（控制秒回、不怕云隧道抖动）。
      np = np.copyWith(accessCode: d.accessCode, mode: PrinterMode.lan);
      changed = true;
    }
    final model = d.productName.isNotEmpty ? d.productName : d.modelName;
    if (model.isNotEmpty && model != np.model) {
      np = np.copyWith(model: model);
      changed = true;
    }
    out.add(np);
  }

  // 云端新设备 → 入列。
  for (final d in devices) {
    if (d.devId.isEmpty || claimed.contains(d.devId)) continue;
    final hasCode = d.accessCode.isNotEmpty;
    final model = d.productName.isNotEmpty ? d.productName : d.modelName;
    out.add(PrinterProfile(
      id: 'c${account.id}-${d.devId}',
      name: d.devName.isNotEmpty
          ? d.devName
          : (model.isNotEmpty ? model : d.devId),
      mode: hasCode ? PrinterMode.lan : PrinterMode.cloud,
      serial: d.devId,
      accessCode: d.accessCode,
      region: account.region,
      token: hasCode ? '' : account.accessToken,
      userId: hasCode ? '' : account.userId,
      model: model,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      accountId: account.id,
    ));
    changed = true;
  }

  return (out, changed);
}
