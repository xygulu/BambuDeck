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

/// 设备详情 (POST /api/lapp/device/info). Status 1 = online, 2 = offline.
class EzvizDeviceInfo {
  const EzvizDeviceInfo({
    required this.serial,
    required this.name,
    required this.model,
    required this.version,
    required this.online,
    required this.isEncrypt,
  });

  final String serial;
  final String name;
  final String model;
  final String version;
  final bool online;
  final bool isEncrypt;

  @override
  String toString() =>
      'EzvizDeviceInfo($serial "$name" $model v$version '
      '${online ? "online" : "offline"})';
}

/// Parses the device/info envelope. `deviceType` carries the model on most
/// accounts; some firmware returns `model` instead, so prefer whichever is
/// non-empty.
EzvizDeviceInfo parseDeviceInfoResponse(Map<String, dynamic> doc) {
  final data = _unwrap(doc);
  if (data is! Map<String, dynamic>) {
    throw EzvizApiException('500', '设备详情应答缺少 data');
  }
  final serial = data['deviceSerial']?.toString() ?? '';
  if (serial.isEmpty) {
    throw EzvizApiException('500', '设备详情应答缺少 deviceSerial');
  }
  final model = (data['deviceType']?.toString() ?? '').isNotEmpty
      ? data['deviceType'].toString()
      : data['model']?.toString() ?? '';
  return EzvizDeviceInfo(
    serial: serial,
    name: data['deviceName']?.toString() ?? '',
    model: model,
    version: data['deviceVersion']?.toString() ?? '',
    online: data['status']?.toString() == '1',
    isEncrypt: data['isEncrypt']?.toString() == '1',
  );
}

/// Extracts the first address from a v2 live-address response. The platform
/// answers `data` as a list of address objects on some deployments and as a
/// single object (`url`, or `{ret: {url}}`) on others.
String parseLiveAddressResponse(Map<String, dynamic> doc) {
  final data = _unwrap(doc);
  String urlOf(dynamic item) {
    if (item is! Map) return '';
    final ret = item['ret'];
    return (item['url'] ?? (ret is Map ? ret['url'] : null))?.toString() ?? '';
  }

  String url = '';
  if (data is List) {
    for (final item in data) {
      url = urlOf(item);
      if (url.isNotEmpty) break;
    }
  } else {
    url = urlOf(data);
  }
  if (url.isEmpty) {
    throw EzvizApiException('500', '取流应答缺少 url');
  }
  return url;
}

/// Extracts `data.picUrl` from a capture response.
String parseCaptureResponse(Map<String, dynamic> doc) {
  final data = _unwrap(doc);
  final url = data is Map<String, dynamic>
      ? data['picUrl']?.toString() ??
          ((data['picUrlList'] as List?)?.isNotEmpty == true
              ? data['picUrlList'].first.toString()
              : '')
      : '';
  if (url.isEmpty) {
    throw EzvizApiException('500', '抓图应答缺少 picUrl');
  }
  return url;
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

  /// 设备详情 (POST /api/lapp/device/info).
  Future<EzvizDeviceInfo> fetchDeviceInfo(
      String accessToken, String deviceSerial) async {
    final doc = await _post('/device/info', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
    });
    return parseDeviceInfoResponse(doc);
  }

  /// 云端改名 (POST /api/lapp/device/name/update). [deviceName] is capped by
  /// the platform at 50 bytes; callers validate before calling.
  Future<void> renameDevice(
      String accessToken, String deviceSerial, String deviceName) async {
    final doc = await _post('/device/name/update', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
      'deviceName': deviceName,
    });
    _unwrap(doc);
  }

  /// 云端抓图 (POST /api/lapp/device/capture). Returns a picture URL valid
  /// for about two hours; the platform allows one capture per 4 seconds.
  Future<String> capture(String accessToken, String deviceSerial,
      {int channelNo = 1}) async {
    final doc = await _post('/device/capture', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
      'channelNo': '$channelNo',
    });
    return parseCaptureResponse(doc);
  }

  /// 云端直播地址 (POST /api/lapp/v2/live/address/get). [protocol]: 1 ezopen,
  /// 2 HLS, 3 RTMP, 4 FLV (H.264 only); [quality]: 1 main, 2 sub;
  /// [expireSeconds] 30 .. 720 days.
  Future<String> liveAddress(String accessToken, String deviceSerial,
      {int channelNo = 1,
      int protocol = 4,
      int quality = 1,
      int expireSeconds = 3600}) async {
    final doc = await _post('/v2/live/address/get', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
      'channelNo': '$channelNo',
      'protocol': '$protocol',
      'quality': '$quality',
      'expireTime': '$expireSeconds',
      'type': '1',
    });
    return parseLiveAddressResponse(doc);
  }

  /// 云台开始转动 (POST /api/lapp/device/ptz/start). [direction]: 0 up,
  /// 1 down, 2 left, 3 right, 4 up-left, 5 down-left, 6 up-right,
  /// 7 down-right, 8 zoom in, 9 zoom out, 10 near focus, 11 far focus,
  /// 16 auto. HIK-backed cameras reject speed 0, so the default is 1.
  Future<void> ptzStart(String accessToken, String deviceSerial, int direction,
      {int channelNo = 1, int speed = 1}) async {
    final doc = await _post('/device/ptz/start', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
      'channelNo': '$channelNo',
      'direction': '$direction',
      'speed': '$speed',
    });
    _unwrap(doc);
  }

  /// 云台停止 (POST /api/lapp/device/ptz/stop). The platform requires the
  /// same direction that was started.
  Future<void> ptzStop(String accessToken, String deviceSerial, int direction,
      {int channelNo = 1}) async {
    final doc = await _post('/device/ptz/stop', {
      'accessToken': accessToken,
      'deviceSerial': deviceSerial,
      'channelNo': '$channelNo',
      'direction': '$direction',
    });
    _unwrap(doc);
  }
}
