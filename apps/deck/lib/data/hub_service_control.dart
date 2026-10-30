import 'dart:async';
import 'dart:io';

import 'app_settings.dart';

/// 独立 hub 服务的探测与控制 (2026-10-31,「服务开关完整改造」)。
///
/// 「网页访问」开关的语义:
///   打开 = 独立 hub 服务在跑(App 关了也继续跑,开机自启);
///   关闭 = 把服务停掉(并撤掉自启)。
/// 装了独立服务的机器上, App 内置网页服务不参与(避免抢端口); 没装的机器
/// 回退为内置服务(随 App 退出而停), 界面会如实说明并给出安装指引。
///
/// 平台落点:
/// - macOS: LaunchAgent `com.bambudeck.hub`
///   (plist `~/Library/LaunchAgents/com.bambudeck.hub.plist`,
///    二进制 `~/.bambudeck/bin/deck_hub_bundle/bin/hub`)
/// - Windows: 计划任务 `BambuDeckHub`(部署包 install-service.bat 注册)
/// - 其它平台(Android/iOS/Linux): 没有独立服务形态, [probe] 恒报未安装。
///
/// 所有命令都有界超时并吞掉异常(结果以 error 字符串返回), 保证 UI 侧
/// 不会因为服务管理器无响应而挂住。
class HubServiceControl {
  HubServiceControl._();
  static final HubServiceControl instance = HubServiceControl._();

  static const _macLabel = 'com.bambudeck.hub';
  static const _winTask = 'BambuDeckHub';

  /// 最近一次 [probe] 的结果, 设置页直接读它展示。
  HubServiceStatus lastStatus = const HubServiceStatus();

  bool get supported => Platform.isMacOS || Platform.isWindows;

  String get _plistPath =>
      '${Platform.environment['HOME']}/Library/LaunchAgents/$_macLabel.plist';
  String get _bundleBin =>
      '${Platform.environment['HOME']}/.bambudeck/bin/deck_hub_bundle/bin/hub';

  int? _uid;
  Future<int?> _macUid() async {
    if (_uid != null) return _uid;
    try {
      final r = await Process.run('id', ['-u'])
          .timeout(const Duration(seconds: 4));
      if (r.exitCode == 0) {
        _uid = int.tryParse((r.stdout as String).trim());
      }
    } catch (_) {}
    return _uid;
  }

  Future<(int, String, String)> _run(
      String exec, List<String> args) async {
    try {
      final r = await Process.run(exec, args)
          .timeout(const Duration(seconds: 8));
      return (
        r.exitCode,
        (r.stdout as String).trim(),
        (r.stderr as String).trim(),
      );
    } catch (e) {
      return (-1, '', e.toString());
    }
  }

  /// 127.0.0.1:port 有没有人在听 —— 「服务真的在跑」的唯一权威判据
  /// (服务管理器只告诉我们“该不该在跑”, 端口才说明“在跑”)。
  Future<bool> portOpen(int port) async {
    try {
      final s = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(milliseconds: 700));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 独立服务是否已安装 (二进制+注册都在, 缺一样都算没装 —— 没注册就
  /// 没有“开机自启/脱离 App”的语义)。
  Future<bool> installed() async {
    if (!supported) return false;
    if (Platform.isMacOS) {
      return File(_bundleBin).existsSync() && File(_plistPath).existsSync();
    }
    final (code, _, _) = await _run(
        'schtasks', ['/query', '/tn', _winTask]);
    return code == 0;
  }

  /// 服务管理器视角的状态串 (launchd state / schtasks Status)。
  /// 取不到就返回空串, 不算错。
  Future<String> managerState() async {
    if (Platform.isMacOS) {
      final uid = await _macUid();
      if (uid == null) return '';
      final (code, out, _) = await _run('launchctl',
          ['print', 'gui/$uid/$_macLabel']);
      if (code != 0) return '';
      final m = RegExp(r'state = (\w+)').firstMatch(out);
      return m?.group(1) ?? 'loaded';
    }
    final (code, out, _) = await _run('schtasks',
        ['/query', '/tn', _winTask, '/fo', 'csv', '/nh']);
    if (code != 0) return '';
    // 最后一列是 Status: "Running"/"Ready"/...
    final cols = out.split('","');
    if (cols.isEmpty) return '';
    return cols.last.replaceAll('"', '').trim();
  }

  /// 全量探测: 安装 + 端口 + 管理器状态。设置页与 _syncHub 共用。
  Future<HubServiceStatus> probe(AppSettings s) async {
    if (!supported) {
      lastStatus = const HubServiceStatus(installed: false, serving: false);
      return lastStatus;
    }
    final inst = await installed();
    final serving = await portOpen(s.hubPort);
    final mgr = inst ? await managerState() : '';
    lastStatus = HubServiceStatus(
      installed: inst,
      serving: serving,
      managerState: mgr,
    );
    return lastStatus;
  }

  /// 启动独立服务 (幂等: 端口已在听就直接返回成功)。
  /// 返回 null = 成功; 否则是给人看的错误说明。
  Future<String?> start(AppSettings s) async {
    if (!supported) return '本平台没有独立 hub 服务形态';
    if (await portOpen(s.hubPort)) return null;
    if (!await installed()) return '独立服务未安装';

    if (Platform.isMacOS) {
      final uid = await _macUid();
      if (uid == null) return '拿不到当前用户 uid';
      await _run('launchctl', ['enable', 'gui/$uid/$_macLabel']);
      // bootstrap 对已加载的 agent 会报 "already bootstrapped", 属正常。
      await _run('launchctl', ['bootstrap', 'gui/$uid', _plistPath]);
      final (code, _, err) = await _run(
          'launchctl', ['kickstart', '-k', 'gui/$uid/$_macLabel']);
      if (code != 0) return 'launchctl kickstart 失败: $err';
    } else {
      // 先 enable: 上次开关关掉时任务被 disable, 不 enable /run 会白跑。
      await _run('schtasks', ['/change', '/tn', _winTask, '/enable']);
      final (code, _, err) =
          await _run('schtasks', ['/run', '/tn', _winTask]);
      if (code != 0) return 'schtasks /run 失败: $err';
    }

    // 服务起来要几秒 (载配置 + 连打印机), 轮询端口等它。
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (await portOpen(s.hubPort)) return null;
    }
    return '服务已下发启动命令, 但 ${s.hubPort} 端口 ${7}s 内没有开始监听'
        '(看服务日志: ~/.bambudeck/hub.log 或部署包 logs\\)';
  }

  /// 停掉独立服务 (幂等: 端口没人听就只补一刀 disable, 保证自启也撤掉)。
  Future<String?> stop(AppSettings s) async {
    if (!supported) return '本平台没有独立 hub 服务形态';

    if (Platform.isMacOS) {
      final uid = await _macUid();
      if (uid == null) return '拿不到当前用户 uid';
      if (await portOpen(s.hubPort)) {
        final (code, _, err) = await _run(
            'launchctl', ['bootout', 'gui/$uid/$_macLabel']);
        if (code != 0) return 'launchctl bootout 失败: $err';
      }
      // disable 让下次登录也不被 RunAtLoad 拉起, 开关语义跨重启成立。
      await _run('launchctl', ['disable', 'gui/$uid/$_macLabel']);
    } else {
      if (await portOpen(s.hubPort)) {
        final (code, _, err) =
            await _run('schtasks', ['/end', '/tn', _winTask]);
        if (code != 0) return 'schtasks /end 失败: $err';
      }
      await _run('schtasks', ['/change', '/tn', _winTask, '/disable']);
    }

    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!await portOpen(s.hubPort)) return null;
    }
    return '停止命令已执行, 但 ${s.hubPort} 端口仍在监听';
  }
}

class HubServiceStatus {
  const HubServiceStatus({
    this.installed = false,
    this.serving = false,
    this.managerState = '',
    this.error,
    this.busy = false,
  });

  /// 独立服务已安装 (mac: 二进制+plist 都在; win: 计划任务在)。
  final bool installed;

  /// 服务端口有响应 —— 真的在跑。
  final bool serving;

  /// launchd / 计划任务视角的状态串 ('running'/'Ready'/...)。
  final String managerState;

  /// 上一次操作的失败说明 (null = 没错)。
  final String? error;

  /// start/stop 正在执行 (界面显示“正在启动/停止…”)。
  final bool busy;

  bool get standaloneActive => installed;
}
