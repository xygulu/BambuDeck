import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';

import 'printer_profile.dart';

/// LAN 打印机定位 (任务 3 的跨网段一半, 2026-10-28):
/// SSDP 组播只在同网段有效 (实测本站打印机在 192.168.100.x、Mac 在
/// 192.168.24.x,组播不过路由;A1 固件甚至不回单播 M-SEARCH), 而唯一
/// 跨网段必通的口子是 8883 的 LAN MQTT。所以两段式:
///   1. TCP 扫候选子网的 8883 (快, 无认证流量);
///   2. 对每个开放的 IP × 每台待认领的打印机, 拿该打印机的访问码发
///      MQTT CONNECT —— CONNACK 0 即认证通过, serial↔IP 一锤定音。
/// 访问码就是 LAN MQTT 的密码, 别处拿不到, 所以无访问码的云模式打印机
/// 本来也无法 LAN 直连, 不在考虑范围。

/// 一台待定位的打印机: 序列号 + LAN MQTT 密码 (访问码)。
class LanProbeTarget {
  const LanProbeTarget({required this.serial, required this.accessCode});

  final String serial;
  final String accessCode;
}

/// 定位结果: serial → ip。
typedef LanProbeResult = Map<String, String>;

/// 扫 [subnetPrefixes] (前三段, 如 `192.168.100`) 各 /24 的 8883, 再用
/// [targets] 的访问码逐个认证。返回 (serial, ip) 对。
Future<LanProbeResult> locateLanPrinters({
  required List<LanProbeTarget> targets,
  required List<String> subnetPrefixes,
  int concurrency = 48,
  Duration connectTimeout = const Duration(milliseconds: 500),
  Duration authTimeout = const Duration(seconds: 3),
  void Function(int done, int total)? onProgress,
}) async {
  if (targets.isEmpty || subnetPrefixes.isEmpty) return {};
  final hosts = [
    for (final p in subnetPrefixes) ...[for (var i = 1; i <= 254; i++) '$p.$i'],
  ];

  // Phase 1: 谁开着 8883。
  final candidates = <String>[];
  var done = 0;
  await _forEach(hosts, concurrency, (ip) async {
    Socket? s;
    try {
      s = await Socket.connect(ip, 8883, timeout: connectTimeout);
      s.destroy();
      candidates.add(ip);
    } on SocketException {
      // 拒绝/过滤 —— 不是 MQTT 端点
    } on TimeoutException {
      // 慢主机, 跳过
    }
    done++;
    onProgress?.call(done, hosts.length);
  });

  // Phase 2: 认证确认。不同 IP 并行, 同一 IP 串行试各台 —— 同一 IP 用
  // 不同密码连多次可能触发固件保护, 串行错开更稳。
  final found = <String, String>{};
  await _forEach(candidates, 8, (ip) async {
    for (final t in targets) {
      if (found.containsKey(t.serial)) continue;
      if (await _authAccepts(ip, t.accessCode, authTimeout)) {
        found[t.serial] = ip;
      }
    }
  });
  return found;
}

/// 用 [accessCode] 向 ip:8883 发一条 MQTT CONNECT; CONNACK rc=0 → true。
Future<bool> _authAccepts(String ip, String accessCode, Duration timeout) async {
  SecureSocket? sock;
  try {
    sock = await SecureSocket.connect(ip, 8883,
        onBadCertificate: (_) => true, timeout: timeout);
    final clientId =
        'bmbdeck${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    sock.add(encodeMqttConnect(clientId: clientId, password: accessCode));
    final ack = await readMqttConnack(sock, timeout);
    return ack;
  } catch (_) {
    return false;
  } finally {
    sock?.destroy();
  }
}

/// 极简 MQTT 3.1.1 CONNECT (LAN 专用: user=bblp, password=访问码)。
Uint8List encodeMqttConnect({
  required String clientId,
  required String password,
  String username = 'bblp',
  int keepAlive = 30,
}) {
  final body = BytesBuilder();
  _addStr(body, utf8.encode('MQTT'));
  body.addByte(4); // level 3.1.1
  body.addByte(0xC2); // username + password + clean session
  body.addByte((keepAlive >> 8) & 0xff);
  body.addByte(keepAlive & 0xff);
  _addStr(body, utf8.encode(clientId));
  _addStr(body, utf8.encode(username));
  _addStr(body, utf8.encode(password));
  final payload = body.toBytes();

  final head = BytesBuilder();
  head.addByte(0x10); // CONNECT
  _addVarlen(head, payload.length);
  head.add(payload);
  return head.toBytes();
}

/// 等一条 CONNACK, rc=0 → true。期间来的其他包丢弃 (不该有)。
Future<bool> readMqttConnack(Socket sock, Duration timeout) async {
  final buf = BytesBuilder();
  final done = Completer<bool>();
  late final StreamSubscription<Uint8List> sub;
  final timer = Timer(timeout, () {
    if (!done.isCompleted) done.complete(false);
  });
  sub = sock.listen(
    (chunk) {
      buf.add(chunk);
      final data = buf.toBytes();
      // CONNACK: 0x20 <remainLen=2> <flags> <rc>
      if (data.length >= 4 && (data[0] & 0xf0) == 0x20) {
        timer.cancel();
        if (!done.isCompleted) done.complete(data[3] == 0);
      }
    },
    onError: (Object _) {
      timer.cancel();
      if (!done.isCompleted) done.complete(false);
    },
    onDone: () {
      timer.cancel();
      if (!done.isCompleted) done.complete(false);
    },
  );
  try {
    return await done.future;
  } finally {
    await sub.cancel();
  }
}

void _addStr(BytesBuilder b, List<int> bytes) {
  b.addByte((bytes.length >> 8) & 0xff);
  b.addByte(bytes.length & 0xff);
  b.add(bytes);
}

void _addVarlen(BytesBuilder b, int n) {
  do {
    var digit = n % 128;
    n ~/= 128;
    if (n > 0) digit |= 0x80;
    b.addByte(digit);
  } while (n > 0);
}

Future<void> _forEach<T>(
    List<T> items, int n, Future<void> Function(T) action) async {
  var i = 0;
  Future<void> worker() async {
    while (i < items.length) {
      await action(items[i++]);
    }
  }

  await [for (var k = 0; k < n; k++) worker()].wait;
}

// -- 云端打印机的 IP 补齐 (2026-10-31, App 启动/云端添加 与 HubService 共用) --

/// 需要补定位的打印机: 有序列号、有访问码、还没 IP。App 内云端添加恒为云
/// 模式(哪怕 bind 带了 dev_access_code), 独立服务云同步升级出来的也是空
/// IP —— 这个判据对两种来源一视同仁。
bool needsLanIp(PrinterProfile p) =>
    p.serial.trim().isNotEmpty &&
    p.accessCode.isNotEmpty &&
    p.ip.trim().isEmpty;

/// 云端来的 LAN 打印机缺 IP 时跑一次发现:
/// (1) SSDP 组播 (同网段, 零流量) → (2) 8883 扫网+访问码认证 (跨网段;
/// 组播不过路由, A1 不回单播 M-SEARCH, 只有 MQTT 必通)。
/// 返回 serial → ip (只含本次要找的目标)。候选网段 = 本机各网卡 + 清单里
/// 已知打印机的网段 (同站点打印机通常同网段)。
Future<Map<String, String>> discoverLanPrinterIps(
    List<PrinterProfile> printers,
    {void Function(String msg)? log}) async {
  final need = printers.where(needsLanIp).toList();
  if (need.isEmpty) return {};
  final bySerial = <String, String>{};

  // (1) SSDP 组播。
  try {
    final hits = await ssdpDiscoverPrinters(wait: const Duration(seconds: 6))
        .timeout(const Duration(seconds: 40));
    for (final h in hits) {
      bySerial[h.serial] = h.ip;
    }
  } catch (e) {
    log?.call('[LAN 发现] SSDP 失败: $e');
  }

  // (2) 8883 扫网认证, 只补 SSDP 没认出来的。
  final rest =
      need.where((p) => !bySerial.containsKey(p.serial.trim())).toList();
  if (rest.isNotEmpty) {
    final prefixes = <String>{};
    try {
      for (final iface in await NetworkInterface.list()) {
        for (final a in iface.addresses) {
          final parts = a.address.split('.');
          if (parts.length == 4 && a.type == InternetAddressType.IPv4) {
            prefixes.add(parts.sublist(0, 3).join('.'));
          }
        }
      }
    } catch (_) {}
    for (final p in printers) {
      final parts = p.ip.split('.');
      if (parts.length == 4) prefixes.add(parts.sublist(0, 3).join('.'));
    }
    if (prefixes.isNotEmpty) {
      try {
        final found = await locateLanPrinters(
          targets: [
            for (final p in rest)
              LanProbeTarget(
                  serial: p.serial.trim(), accessCode: p.accessCode),
          ],
          subnetPrefixes: prefixes.toList(),
        ).timeout(const Duration(minutes: 3));
        bySerial.addAll(found);
        log?.call('[LAN 发现] 8883 扫网 ${prefixes.join("/")}: '
            '认出 ${found.length}/${rest.length}');
      } catch (e) {
        log?.call('[LAN 发现] 8883 扫网失败: $e');
      }
    }
  }

  // SSDP 可能顺带捡到清单里别的打印机 (已有 IP / 无访问码), 不在本次范围。
  final wanted = {for (final p in need) p.serial.trim()};
  bySerial.removeWhere((s, _) => !wanted.contains(s));
  return bySerial;
}

/// 把发现结果应用回清单: 命中的补 IP; 云模式顺手升级 LAN 直连 (能被认证
/// 命中就证明访问码对, 升级安全)。没有变化返回 null, 调用方据此跳过落盘。
List<PrinterProfile>? applyLanIps(
    List<PrinterProfile> printers, Map<String, String> hits) {
  if (hits.isEmpty) return null;
  var changed = false;
  final next = <PrinterProfile>[];
  for (final p in printers) {
    final ip = hits[p.serial.trim()];
    if (ip == null || ip == p.ip) {
      next.add(p);
      continue;
    }
    changed = true;
    next.add(p.copyWith(ip: ip, mode: PrinterMode.lan));
  }
  return changed ? next : null;
}
