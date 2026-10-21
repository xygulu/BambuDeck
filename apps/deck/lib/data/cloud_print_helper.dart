/// 云端打印客户端 —— 调用本机 `bconnect_helper.py`。
///
/// 背景（实测 2026-10-21）：拓竹云模式下，第三方直接调云端 API 建打印任务只能拿到
/// `status=1`，云端永不下发；必须由 Bambu Connect 以自己的合法客户端身份派单。
/// 而触发 Connect 需要在 macOS 上点三下界面（导入Gcode 3MF文件 → 打印 → 发送），
/// Flutter 侧无法实现，所以由本机 helper 代劳。
///
/// 依赖：
///   1. `python bconnect_service.py` 在本机运行（默认 127.0.0.1:8799）
///   2. 启动后会把 `{url, token}` 写到 `~/.bambudeck/helper.json`
///   3. 系统设置 → 隐私与安全性 → 辅助功能 需允许 helper 的 python
///
/// 用法：
/// ```dart
/// final r = await CloudPrintHelper.instance.print('/path/to/x.gcode.3mf');
/// if (r.ok) {
///   print('已派单 task=${r.taskId} status=${r.taskStatus}');
/// } else {
///   print('失败: ${r.error}');
/// }
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单步执行结果。
class CloudPrintStep {
  const CloudPrintStep({
    required this.step,
    required this.ok,
    this.detail,
    this.elapsed,
    this.sincePrev,
  });

  final String step;
  final bool ok;
  final String? detail;
  final double? elapsed;
  final double? sincePrev;

  factory CloudPrintStep.fromJson(Map<String, dynamic> j) => CloudPrintStep(
        step: j['step']?.toString() ?? '',
        ok: j['ok'] == true,
        detail: j['detail']?.toString(),
        elapsed: (j['elapsed'] as num?)?.toDouble(),
        sincePrev: (j['since_prev'] as num?)?.toDouble(),
      );

  @override
  String toString() {
    final t = elapsed == null ? '' : ' +${elapsed!.toStringAsFixed(1)}s';
    return '${ok ? '✓' : '✗'} $step$t${detail == null ? '' : ' ($detail)'}';
  }
}

/// 打印结果。
class CloudPrintResult {
  const CloudPrintResult({
    required this.ok,
    this.error,
    this.taskId,
    this.taskStatus,
    this.device,
    this.printerState,
    this.printerPercent,
    this.steps = const [],
    this.elapsedTotal,
  });

  final bool ok;
  final String? error;
  final int? taskId;
  final int? taskStatus;
  final String? device;
  final String? printerState;
  final int? printerPercent;
  final List<CloudPrintStep> steps;
  final double? elapsedTotal;

  /// 打印机已开始执行（status 3 表示已派单执行，2 表示成功完成）。
  bool get dispatched => taskStatus != null && taskStatus! >= 2;

  factory CloudPrintResult.fromJson(Map<String, dynamic> j) {
    final task = (j['task'] as Map<String, dynamic>?) ?? const {};
    final printer = (j['printer'] as Map<String, dynamic>?) ?? const {};
    final steps = (j['steps'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CloudPrintStep.fromJson)
        .toList();
    return CloudPrintResult(
      ok: j['ok'] == true,
      error: j['error']?.toString(),
      taskId: (task['id'] as num?)?.toInt(),
      taskStatus: (task['status'] as num?)?.toInt(),
      device: task['device']?.toString(),
      printerState: printer['state']?.toString(),
      printerPercent: (printer['percent'] as num?)?.toInt(),
      steps: steps,
      elapsedTotal: (j['elapsed_total'] as num?)?.toDouble(),
    );
  }
}

/// 控制命令结果（pause/resume/stop 经 Bambu Connect 自动化派发）。
class CloudControlResult {
  const CloudControlResult({
    required this.ok,
    this.error,
    this.command,
    this.printer,
    this.serial,
    this.method,
    this.elapsed,
  });

  final bool ok;
  final String? error;
  final String? command;
  final String? printer;
  final String? serial;
  final String? method;
  final double? elapsed;

  factory CloudControlResult.fromJson(Map<String, dynamic> j) =>
      CloudControlResult(
        ok: j['ok'] == true,
        error: j['error']?.toString(),
        command: j['command']?.toString(),
        printer: j['printer']?.toString(),
        serial: j['serial']?.toString(),
        method: j['method']?.toString(),
        elapsed: (j['elapsed'] as num?)?.toDouble(),
      );
}

/// helper 连接信息（`~/.bambudeck/helper.json`）。
class HelperEndpoint {
  const HelperEndpoint({required this.url, required this.token});

  final String url;
  final String token;

  static String get _infoPath {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/.bambudeck/helper.json';
  }

  /// 读取 helper 写下的 {url, token}；未启动 helper 时返回 null。
  static Future<HelperEndpoint?> load() async {
    try {
      final f = File(_infoPath);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final url = j['url']?.toString();
      final token = j['token']?.toString();
      if (url == null || token == null) return null;
      return HelperEndpoint(url: url, token: token);
    } catch (_) {
      return null;
    }
  }
}

/// 云端打印入口（单例）。
class CloudPrintHelper {
  CloudPrintHelper._();

  static final CloudPrintHelper instance = CloudPrintHelper._();

  /// helper 是否在线。
  Future<bool> health() async {
    final ep = await HelperEndpoint.load();
    if (ep == null) return false;
    try {
      final res = await _request(ep, 'GET', '/health');
      return res['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 把 3mf 交给 Bambu Connect 派单到云端。
  ///
  /// [file] 必须是本机绝对路径的 `.3mf` / `.gcode.3mf`。
  /// [serial] 指定目标打印机，null 用 helper 默认值。
  /// [stopBeforeSend] 为 true 时只走到打印页、不点发送（不会真打印，便于自测）。
  Future<CloudPrintResult> print(
    String file, {
    String? serial,
    bool stopBeforeSend = false,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final ep = await HelperEndpoint.load();
    if (ep == null) {
      return const CloudPrintResult(
        ok: false,
        error: '本机打印 helper 未启动（找不到 ~/.bambudeck/helper.json）。'
            '请先运行 python bconnect_service.py',
      );
    }
    try {
      final res = await _request(ep, 'POST', '/print', body: {
        'file': file,
        if (serial != null) 'serial': serial,
        'stop_before_send': stopBeforeSend,
      }, timeout: timeout);
      return CloudPrintResult.fromJson(res);
    } on TimeoutException {
      return const CloudPrintResult(ok: false, error: 'helper 超时未响应');
    } catch (e) {
      return CloudPrintResult(ok: false, error: 'helper 调用失败: $e');
    }
  }

  /// 发送控制命令（pause/resume/stop）经 Bambu Connect 自动化。
  ///
  /// [serial] 是目标打印机的唯一标识——名称或序列号均可（helper 用正则匹配）。
  /// dev-OFF/云模式打印机 LAN MQTT 控制会被固件 84033543 拦，所以走 Connect。
  Future<CloudControlResult> control(
    String serial,
    String command, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final ep = await HelperEndpoint.load();
    if (ep == null) {
      return const CloudControlResult(
        ok: false,
        error: '本机打印 helper 未启动（找不到 ~/.bambudeck/helper.json）。'
            '请先运行 python bconnect_service.py',
      );
    }
    try {
      final res = await _request(ep, 'POST', '/command', body: {
        'serial': serial,
        'command': command,
        'params': const <String, dynamic>{},
      }, timeout: timeout);
      return CloudControlResult.fromJson(res);
    } on TimeoutException {
      return const CloudControlResult(ok: false, error: 'helper 超时未响应');
    } catch (e) {
      return CloudControlResult(ok: false, error: 'helper 调用失败: $e');
    }
  }

  /// 调试：读取 Connect 当前界面的按钮标题。
  Future<List<String>> buttons() async {
    final ep = await HelperEndpoint.load();
    if (ep == null) return const [];
    try {
      final res = await _request(ep, 'POST', '/buttons');
      return (res['buttons'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _request(
    HelperEndpoint ep,
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse('${ep.url}$path');
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set('X-Deck-Token', ep.token);
      if (body != null) {
        // 必须显式设 Content-Length:不设时 Dart HttpClient 用 chunked 编码,
        // 而 helper 的 BaseHTTPRequestHandler 只按 Content-Length 读 body ——
        // 读到 0 字节,服务端看到空对象,报「缺字段 serial」(2026-10-21 实测:
        // 暂停/换盘/视觉暂停全部这样哑掉,GET /health 正常所以更隐蔽)。
        final payload = utf8.encode(jsonEncode(body));
        req.headers.contentLength = payload.length;
        req.headers.contentType = ContentType.json;
        req.add(payload);
      }
      final resp = await req.close().timeout(timeout);
      final text = await resp.transform(utf8.decoder).join().timeout(timeout);
      final decoded = text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
      if (resp.statusCode >= 400 && decoded['ok'] != true) {
        return decoded;
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}
