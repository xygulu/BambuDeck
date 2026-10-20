import 'dart:convert';
import 'dart:io';

/// One camera bound to an EZVIZ open-platform account (萤石开放平台).
class EzvizDevice {
  const EzvizDevice({
    required this.serial,
    required this.name,
    required this.model,
    required this.online,
    required this.isEncrypt,
  });

  final String serial;
  final String name;
  final String model;
  final bool online;

  /// True when the device enforces its verification code (验证码) for
  /// LAN/RTSP access - the normal state.
  final bool isEncrypt;

  @override
  String toString() => 'EzvizDevice($serial "$name" $model '
      '${online ? "online" : "offline"})';
}

/// Outcome of parsing a lapp-API envelope: [code] "200" is success, anything
/// else carries the platform's [message] (e.g. 10002 Token无效,
/// 20006/20007/20008 设备不存在/不在线/验证码错误).
class EzvizApiException implements Exception {
  EzvizApiException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '萤石平台错误 $code: $message';
}

/// Envelope check shared by every endpoint: returns [data] on code 200,
/// throws [EzvizApiException] otherwise. The platform sends the code as a
/// JSON string ("200") in practice, some deployments as a number - accept
/// both.
dynamic _unwrap(Map<String, dynamic> doc) {
  final code = doc['code']?.toString() ?? '';
  if (code != '200') {
    throw EzvizApiException(code, doc['msg']?.toString() ?? '(无错误信息)');
  }
  return doc['data'];
}

/// AppKey + AppSecret -> accessToken (POST /api/lapp/token/get).
String parseTokenResponse(Map<String, dynamic> doc) {
  final data = _unwrap(doc);
  if (data is! Map<String, dynamic>) {
    throw EzvizApiException('500', 'token 应答缺少 data');
  }
  final token = data['accessToken']?.toString() ?? '';
  if (token.isEmpty) {
    throw EzvizApiException('500', 'token 应答缺少 accessToken');
  }
  return token;
}

/// One page of the device list (POST /api/lapp/device/list).
List<EzvizDevice> parseDeviceListResponse(Map<String, dynamic> doc) {
  final data = _unwrap(doc);
  if (data is! List) return const [];
  return data.whereType<Map<String, dynamic>>().map((d) {
    return EzvizDevice(
      serial: d['deviceSerial']?.toString() ?? '',
      name: d['deviceName']?.toString() ?? '',
      model: d['model']?.toString() ?? '',
      online: d['status']?.toString() == '1',
      isEncrypt: d['isEncrypt']?.toString() == '1',
    );
  }).where((d) => d.serial.isNotEmpty).toList();
}

/// EZVIZ open platform client (open.ys7.com lapp v1). The endpoints take
/// form-encoded POST bodies and answer {code, msg, data} envelopes.
///
/// The caller supplies an [AppKey]/[AppSecret] pair from the 开放平台
/// console (open.ys7.com -> 控制台 -> 应用信息); one account can cover all
/// of a user's cameras.
class EzvizCloudClient {
  EzvizCloudClient({
    this.base = 'https://open.ys7.com/api/lapp',
    this.postOverride,
    this.log,
  });

  final String base;

  /// Injectable for tests: performs the form POST and returns the decoded
  /// envelope. Defaults to a real HTTPS form POST.
  Future<Map<String, dynamic>> Function(Uri uri, Map<String, String> fields)?
      postOverride;

  final void Function(String line)? log;

  Future<Map<String, dynamic>> _post(
      String path, Map<String, String> fields) async {
    final uri = Uri.parse('$base$path');
    if (postOverride != null) return postOverride!(uri, fields);
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader,
          'application/x-www-form-urlencoded; charset=utf-8');
      req.add(utf8.encode(Uri(queryParameters: fields).query));
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      log?.call('[ezviz] $path -> ${res.statusCode} '
          '${text.length > 200 ? '${text.substring(0, 200)}…' : text}');
      if (res.statusCode != 200) {
        throw EzvizApiException('${res.statusCode}', 'HTTP $path 失败');
      }
      final doc = jsonDecode(text);
      return doc is Map<String, dynamic> ? doc : <String, dynamic>{};
    } finally {
      client.close();
    }
  }

  /// Exchanges AppKey/AppSecret for an accessToken (valid 7 days; not
  /// persisted - fetched on demand).
  Future<String> fetchToken(
      {required String appKey, required String appSecret}) async {
    final doc = await _post(
        '/token/get', {'appKey': appKey, 'appSecret': appSecret});
    return parseTokenResponse(doc);
  }

  /// All devices on the account, walking pages (50 per call).
  Future<List<EzvizDevice>> fetchDevices(String accessToken) async {
    final devices = <EzvizDevice>[];
    for (var page = 1; page <= 20; page++) {
      final doc = await _post('/device/list', {
        'accessToken': accessToken,
        'pageNum': '$page',
        'pageSize': '50',
      });
      final chunk = parseDeviceListResponse(doc);
      devices.addAll(chunk);
      if (chunk.length < 50) break;
    }
    return devices;
  }
}
