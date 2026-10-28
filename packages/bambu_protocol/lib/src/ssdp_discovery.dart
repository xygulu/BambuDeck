import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// SSDP 局域网发现 (任务 3, 2026-10-28): 云端同步来的打印机只有序列号,
/// LAN 直连还缺 IP。拓竹打印机都开 UPnP: 组播一条 M-SEARCH (ST 用
/// `urn:bambulab-com:device:3dprinter::1`), 应答的 LOCATION 指向
/// http://<ip>/device.xml, 里面的 serialNumber 就是配对钥匙。
///
/// 应答是单播回给我们绑的临时端口; Windows 防火墙对出站发起的 UDP 回包
/// 默认放行, 无需加规则。

/// 一台被发现的打印机。
class SsdpHit {
  const SsdpHit({required this.ip, required this.serial, this.name = ''});

  final String ip;
  final String serial;

  /// device.xml 的 friendlyName, 仅供展示。
  final String name;
}

const _msearchTarget = 'urn:bambulab-com:device:3dprinter::1';

/// 组播 M-SEARCH 并收集应答对应描述 XML, 按序列号去重。
/// [ssdpAll] 为 true 时再补发一条 `ST: ssdp:all`(个别固件只认这个),
/// 非 3D 打印机的应答在抓 XML 后按 deviceType 过滤掉。
Future<List<SsdpHit>> ssdpDiscoverPrinters({
  Duration wait = const Duration(seconds: 4),
  bool ssdpAll = true,
  HttpClient? client,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  var closed = false;
  void closeSocket() {
    if (!closed) {
      closed = true;
      socket.close();
    }
  }

  final http =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 4));
  try {
    String msearch(String st) => 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: $st\r\n'
        '\r\n';
    socket.send(
        msearch(_msearchTarget).codeUnits, InternetAddress('239.255.255.250'), 1900);
    if (ssdpAll) {
      // 错开半秒, 两波应答不挤在一起。
      Future.delayed(const Duration(milliseconds: 600), () {
        try {
          if (!closed) {
            socket.send(msearch('ssdp:all').codeUnits,
                InternetAddress('239.255.255.250'), 1900);
          }
        } catch (_) {}
      });
    }

    // LOCATION → 应答头里的 ST (ssdp:all 的应答先收下, 抓 XML 时按类型过滤)。
    final locations = <String, String>{};
    final timer = Timer(wait, closeSocket);
    await for (final ev in socket) {
      final pkg = ev == RawSocketEvent.read ? socket.receive() : null;
      if (pkg == null) continue;
      final text = utf8.decode(pkg.data, allowMalformed: true);
      if (!text.toUpperCase().contains('LOCATION:')) continue;
      final loc = headerValue(text, 'LOCATION');
      if (loc == null) continue;
      locations[loc] = headerValue(text, 'ST') ?? '';
    }
    timer.cancel();

    // 并发抓描述 XML, 认得出 serialNumber 且类型是拓竹打印机的才留。
    final hits = await Future.wait([
      for (final e in locations.entries) _describe(e.key, e.value, http),
    ]);
    final bySerial = <String, SsdpHit>{};
    for (final h in hits) {
      if (h == null) continue;
      bySerial[h.serial] = h; // 重复应答按序列号去重
    }
    return bySerial.values.toList();
  } finally {
    closeSocket();
    if (client == null) http.close();
  }
}

/// 抓 device.xml 并解析; 不是拓竹打印机 (类型不符/无序列号) 返回 null。
Future<SsdpHit?> _describe(String url, String st, HttpClient http) async {
  try {
    final req = await http
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 4));
    final res = await req.close().timeout(const Duration(seconds: 4));
    if (res.statusCode != 200) return null;
    final xml = await res.transform(utf8.decoder).join();
    final serial = extractTag(xml, 'serialNumber');
    if (serial == null || serial.isEmpty) return null;
    // ssdp:all 会把网络里所有 UPnP 设备都叫醒 (NVR、音箱…); ST 已指明
    // 打印机的直接放行, 其余看 deviceType。
    final type = extractTag(xml, 'deviceType') ?? st;
    if (!type.contains('bambulab')) return null;
    return SsdpHit(
      ip: Uri.parse(url).host,
      serial: serial,
      name: extractTag(xml, 'friendlyName') ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// 大小写无关地取一个 HTTP 头 (SSDP 应答的头大小写随固件心情)。按 \n 切,
/// 兼容个别固件不带 \r 的应答。
String? headerValue(String text, String name) {
  for (final line in text.split('\n')) {
    final i = line.indexOf(':');
    if (i <= 0) continue;
    if (line.substring(0, i).trim().toUpperCase() == name.toUpperCase()) {
      return line.substring(i + 1).trim();
    }
  }
  return null;
}

/// 抠一个 XML 标签的文本 (描述文件极小, 不值得上解析器)。
String? extractTag(String xml, String tag) {
  final m =
      RegExp('<$tag[^>]*>([^<]+)</$tag>', caseSensitive: false).firstMatch(xml);
  return m?.group(1)?.trim();
}
