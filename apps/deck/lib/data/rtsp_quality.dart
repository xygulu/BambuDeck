/// RTSP stream quality (main vs sub stream) for third-party cameras.
/// The sub stream is smaller and smoother - the right default for an
/// always-on monitoring tile; the main stream is what you switch to when
/// you want detail.
library;

enum RtspQuality { main, sub }

RtspQuality rtspQualityFromName(String? name) =>
    name == 'sub' ? RtspQuality.sub : RtspQuality.main;

/// Vendors encode main/sub in the URL path differently. Each entry knows
/// how to detect and flip one style. Order matters only for readability.
class _PathStyle {
  const _PathStyle(this.isMain, this.toMain, this.toSub);

  final RegExp isMain;
  final String Function(String url) toMain;
  final String Function(String url) toSub;
}

/// Shorthand for a marker swap: [mainMarker] is what the main-stream URL
/// carries, [subMarker] its sub-stream counterpart.
_PathStyle _swap(String detect, String mainMarker, String subMarker) =>
    _PathStyle(
      RegExp(detect, caseSensitive: false),
      (url) => url.replaceFirst(subMarker, mainMarker),
      (url) => url.replaceFirst(mainMarker, subMarker),
    );

final _styles = <_PathStyle>[
  // EZVIZ / Hikvision: /h264/ch1/main/av_stream <-> /sub/
  _swap(r'/h264/ch\d+/(main|sub)/', '/main/', '/sub/'),
  // Hikvision ISAPI: /Streaming/Channels/101 <-> /102 (channel*10+1/+2)
  _PathStyle(
    RegExp(r'/Streaming/Channels/\d+10[12]', caseSensitive: false),
    (url) => url.replaceFirst(RegExp(r'102(?:/|$)'), '101'),
    (url) => url.replaceFirst(RegExp(r'101(?:/|$)'), '102'),
  ),
  // Dahua: /cam/realmonitor?channel=1&subtype=0 <-> 1
  _swap(r'subtype=[01]', 'subtype=0', 'subtype=1'),
  // TP-Link / tapo / unifi style: /stream1 <-> /stream2
  _swap(r'/stream[12]', '/stream1', '/stream2'),
  // Reolink: h264Preview_01_main <-> _sub
  _swap(r'h264Preview_\d+_(main|sub)', '_main', '_sub'),
];

/// True when the URL's path visibly encodes main/sub and can be flipped.
bool rtspQualitySwappable(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'rtsp' && u.scheme != 'rtsps') return false;
  return _styles.any((s) => s.isMain.hasMatch(url));
}

RtspQuality rtspQualityOfUrl(String url) {
  // Markers are style-specific on purpose - a bare "102" would also match
  // an IP address like 192.168.100.102.
  if (RegExp(r'/sub/', caseSensitive: false).hasMatch(url)) {
    return RtspQuality.sub;
  }
  if (RegExp(r'/Streaming/Channels/\d*102', caseSensitive: false)
      .hasMatch(url)) {
    return RtspQuality.sub;
  }
  if (url.contains('subtype=1') ||
      RegExp(r'/stream2', caseSensitive: false).hasMatch(url) ||
      RegExp(r'_sub', caseSensitive: false).hasMatch(url)) {
    return RtspQuality.sub;
  }
  return RtspQuality.main;
}

/// Rewrites [url] to the requested quality. Returns it unchanged when the
/// path does not encode a recognizable main/sub style.
String applyRtspQuality(String url, RtspQuality quality) {
  for (final style in _styles) {
    if (!style.isMain.hasMatch(url)) continue;
    return quality == RtspQuality.main ? style.toMain(url) : style.toSub(url);
  }
  return url;
}
