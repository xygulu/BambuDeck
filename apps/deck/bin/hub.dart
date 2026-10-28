import 'dart:async';
import 'dart:io';

import 'package:deck/data/hub_service.dart';
import 'package:deck/data/log_buffer.dart';

/// 独立网页服务入口（不依赖 GUI app）。
///
/// 用法（在 apps/deck 下）：
///   dart run bin/hub.dart [hub.json 路径]
///
/// 配置默认 `~/.bambudeck/hub.json`（由 App 在配置变更时导出）。页面与换盘
/// 模型默认读仓库里的 `assets/`，可用 `HUB_PAGE` / `HUB_PLATE_SWAP` 环境变量
/// 覆盖，`~/.bambudeck/hub_page.html` 存在时优先用家目录那份。
Future<void> main(List<String> args) async {
  // Windows 没有 HOME, 用 USERPROFILE 兜底 (另一台 Windows 机器部署 deck_hub)。
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '';

  String env(String name) => Platform.environment[name]?.trim() ?? '';

  // 默认配置：程序目录下的 config/hub.json 优先（CWD，其次 exe 所在目录；
  // Windows 部署包布局——用户要求 json 一律放运行程序目录、不读 ~/.bambudeck，
  // 裸跑 hub 也要读到包内配置），都没有才退回家目录（macOS launchd 部署的
  // 既有路径，App 导出的 hub.json 在那里）。
  String defaultConfigPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    for (final base in [Directory.current.path, exeDir]) {
      final f = '$base${sep}config${sep}hub.json';
      if (File(f).existsSync()) return f;
    }
    return '$home/.bambudeck/hub.json';
  }

  final configArg = args.isNotEmpty ? args[0].trim() : '';
  final configPath = configArg.isNotEmpty
      ? configArg
      : (env('HUB_CONFIG').isNotEmpty ? env('HUB_CONFIG') : defaultConfigPath());

  String resolvePage() {
    final e = env('HUB_PAGE');
    if (e.isNotEmpty) return e;
    final homePage = '$home/.bambudeck/hub_page.html';
    if (File(homePage).existsSync()) return homePage;
    return 'assets/web/hub_page.html';
  }

  String resolvePlateSwap() {
    final e = env('HUB_PLATE_SWAP');
    if (e.isNotEmpty) return e;
    return 'assets/plate_swap/auto_plate_swap.3mf';
  }

  final service = HubService(
    configFile: File(configPath),
    pageFile: resolvePage(),
    plateSwapFile: resolvePlateSwap(),
  );

  // 服务状态页的隧道全链路探测地址 (2026-10-27): GET 一次 = CF 边缘 →
  // 隧道 → 本机 8787 整条链路都验过。可用 HUB_TUNNEL_URL 覆盖, 置空串跳过。
  service.hub.tunnelProbeUrl =
      env('HUB_TUNNEL_URL').isNotEmpty ? env('HUB_TUNNEL_URL') : 'https://bambu.miller.ink';

  await service.start();
  if (!service.hub.running) {
    LogBuffer.instance.add('[独立服务] 端口 ${service.hub.settings.hubPort} '
        '被占用，启动失败，稍后由 launchd 重试');
    // 非零退出让 launchd 的 KeepAlive 在端口释放后（例如 App 关掉网页访问）
    // 自动重启重试，而不是卡在「没监听但进程还活着」的坏状态。
    exit(1);
  }
  LogBuffer.instance.add('[独立服务] 网页服务已启动 '
      '(端口 ${service.hub.settings.hubPort}, 配置 $configPath)');

  // 轮询 hub.json 的 mtime：App 导出新配置（改令牌/加打印机）时自动退出，
  // 交给 launchd 的 KeepAlive 重启重载。launchd 的 WatchPaths 对新建文件不可靠，
  // 这里用进程内轮询兜底（3s 一次）。注意：本服务自己改摄像头/静音也会写
  // hub.json，会触发一次无害的重启（状态已落盘，重启只是原样重载）。
  DateTime? configMtime() {
    try {
      return File(configPath).lastModifiedSync();
    } catch (_) {
      return null; // 文件还不存在：一旦出现即触发重载。
    }
  }

  final initialMtime = configMtime();
  Timer.periodic(const Duration(seconds: 3), (_) {
    if (configMtime() != initialMtime) {
      LogBuffer.instance.add('[独立服务] 检测到 $configPath 变更，重启重载');
      exit(0); // KeepAlive 会立刻拉起新进程读新配置。
    }
  });

  // 阻塞到收到 SIGINT / SIGTERM, 然后优雅收尾（关 MQTT 连接 + HTTP 监听）。
  // Windows 只支持 SIGINT（CTRL+C），SIGTERM 监听会抛 SignalException
  // （errno 50, 2026-10-28 实测：服务刚启动就被这个未处理异常崩掉）；
  // 计划任务/无控制台场景两种信号都收不到，由守护循环 taskkill 兜底，
  // 所以监听失败只记一条日志、服务照常常驻。
  final stop = Completer<void>();
  void watch(ProcessSignal signal) {
    try {
      signal.watch().listen((_) => stop.complete());
    } on SignalException {
      LogBuffer.instance.add('[独立服务] $signal 监听不可用，退出交给 taskkill');
    }
  }

  watch(ProcessSignal.sigint);
  if (!Platform.isWindows) watch(ProcessSignal.sigterm);
  await stop.future;

  LogBuffer.instance.add('[独立服务] 正在退出');
  await service.stop();
}
