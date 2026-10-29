import 'dart:io';

/// GitHub Release 资产的镜像兜底 (2026-10-29)。
///
/// 国内网络对 Release 的资产站是**半通**: `api.github.com` / `github.com`
/// 正常, 但 302 到的 `release-assets.githubusercontent.com` TLS 握手直接
/// 失败 (盒子实测: `curl` 报 `schannel: failed to receive handshake`,
/// PowerShell 报「从传输接收的数据 EOF 0 字节」)。所以自更新在盒子上一开始
/// 根本走不通。
///
/// 兜底只换传输通道, 不换信任根: 清单 (version.json) 仍从 api.github.com
/// 取, 里面的 sha256 才是判据 —— 镜像给的内容对不上哈希照样删掉放弃。
class GhMirror {
  /// 前缀式镜像 (mirror + 完整 GitHub URL)。按可用性排序, 直连永远第一。
  static const prefixes = <String>[
    'https://ghfast.top/',
    'https://gh-proxy.com/',
  ];

  /// 直连 + 各镜像的候选 URL 列表 (非 github.com 的地址不给镜像)。
  static List<String> candidates(String url) {
    if (!url.startsWith('https://github.com/')) return <String>[url];
    return <String>[url, for (final p in prefixes) '$p$url'];
  }

  /// 依次尝试候选地址写进 [out]; 每次失败先删半截文件再换下一个。
  /// [onLog] 用于把「正在走镜像」写进日志, [onProgress] 报告累计字节。
  static Future<void> fetch(
    HttpClient client,
    String url,
    File out, {
    Duration timeout = const Duration(minutes: 10),
    void Function(int got)? onProgress,
    void Function(String msg)? onLog,
  }) async {
    final list = candidates(url);
    Object? last;
    for (var i = 0; i < list.length; i++) {
      try {
        await _once(client, list[i], out, timeout, onProgress);
        if (i > 0) onLog?.call('[更新] 直连不通, 已走镜像: ${list[i]}');
        return;
      } catch (e) {
        last = e;
        onLog?.call('[更新] 下载失败 (${i + 1}/${list.length}): $e');
        try {
          if (await out.exists()) await out.delete();
        } catch (_) {}
      }
    }
    throw '下载失败: $last';
  }

  static Future<void> _once(
    HttpClient client,
    String url,
    File out,
    Duration timeout,
    void Function(int got)? onProgress,
  ) async {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      await res.drain<void>().catchError((_) {});
      throw 'HTTP ${res.statusCode}';
    }
    final sink = out.openWrite();
    var got = 0;
    try {
      await for (final chunk in res) {
        got += chunk.length;
        sink.add(chunk);
        onProgress?.call(got);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close().catchError((_) {});
      rethrow;
    }
  }
}
