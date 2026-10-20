import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'ptz_client.dart';

/// Minimal ONVIF PTZ client (ver20/wsdl) for third-party cameras.
/// Covers what the monitoring tiles need: probe the device for a media
/// profile token, then ContinuousMove while a pad button is held and Stop
/// on release. Auth is WS-UsernameToken with the PasswordDigest binding -
/// the same admin / device-verification-code pair most Hikvision-family
/// cameras (EZVIZ included) use for RTSP.
///
/// Devices expose their services under /onvif/*; the exact suffix varies
/// (…_service vs plain), so [probe] walks the common candidates once and
/// remembers what worked.
class OnvifPtz implements PtzClient {
  OnvifPtz({
    required this.host,
    this.port = 8899,
    required this.username,
    required this.password,
  });

  final String host;
  final int port;
  final String username;
  final String password;

  static const _mediaPaths = ['/onvif/media_service', '/onvif/media'];
  static const _ptzPaths = ['/onvif/ptz_service', '/onvif/ptz'];

  String? _profileToken;
  String? _ptzPath;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  @override
  bool get available => _profileToken != null;

  /// Returns true when the camera answered GetProfiles with a profile
  /// token (i.e. ONVIF is reachable and credentials work). Safe to call
  /// repeatedly - the result is cached.
  @override
  Future<bool> probe() async {
    if (_profileToken != null) return true;
    for (final path in _mediaPaths) {
      try {
        final body = await _post(path, _envelope(
            '<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>'));
        final m = RegExp(r'token="([^"]+)"').firstMatch(body);
        if (m != null) {
          _profileToken = m.group(1);
          return true;
        }
      } catch (_) {
        // try the next candidate path
      }
    }
    return false;
  }

  /// Continuous move. [pan]/[tilt] in -1..1, [zoom] 0..1; a repeat timer
  /// on the UI side keeps re-issuing this while the button is held.
  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    final token = _profileToken;
    if (token == null) return;
    await _ptzRequest('''
<ContinuousMove xmlns="http://www.onvif.org/ver20/ptz/wsdl">
<ProfileToken>$token</ProfileToken>
<Velocity>
<PanTilt x="${pan.toStringAsFixed(2)}" y="${tilt.toStringAsFixed(2)}"
 xmlns="http://www.onvif.org/ver10/schema"/>
<Zoom z="${zoom.toStringAsFixed(2)}" xmlns="http://www.onvif.org/ver10/schema"/>
</Velocity>
</ContinuousMove>''');
  }

  @override
  Future<void> stop() async {
    final token = _profileToken;
    if (token == null) return;
    await _ptzRequest('''
<Stop xmlns="http://www.onvif.org/ver20/ptz/wsdl">
<ProfileToken>$token</ProfileToken>
<PanTilt>true</PanTilt><Zoom>true</Zoom>
</Stop>''');
  }

  Future<void> _ptzRequest(String body) async {
    if (_ptzPath != null) {
      await _post(_ptzPath!, _envelope(body));
      return;
    }
    for (final path in _ptzPaths) {
      try {
        await _post(path, _envelope(body));
        _ptzPath = path;
        return;
      } catch (_) {
        // try the next candidate path
      }
    }
  }

  String _envelope(String body) {
    final created =
        '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
    final nonce = List<int>.generate(
        16, (_) => Random.secure().nextInt(256));
    final digest = base64.encode(sha1
        .convert([...nonce, ...utf8.encode(created), ...utf8.encode(password)])
        .bytes);
    return '''
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
<s:Header>
<Security s:mustUnderstand="1"
 xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
<UsernameToken>
<Username>$username</Username>
<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">$digest</Password>
<Nonce>${base64.encode(nonce)}</Nonce>
<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">$created</Created>
</UsernameToken>
</Security>
</s:Header>
<s:Body>$body</s:Body>
</s:Envelope>''';
  }

  Future<String> _post(String path, String soap) async {
    final req = await _http.openUrl(
        'post', Uri.parse('http://$host:$port$path'));
    req.headers.set(HttpHeaders.contentTypeHeader,
        'application/soap+xml; charset=utf-8; action=""');
    req.add(utf8.encode(soap));
    final res = await req.close().timeout(const Duration(seconds: 4));
    final text = await utf8.decodeStream(res);
    if (res.statusCode != 200) {
      final snippet = text.length > 120 ? text.substring(0, 120) : text;
      throw HttpException('ONVIF ${res.statusCode}: $snippet');
    }
    return text;
  }

  @override
  void dispose() => _http.close();
}
