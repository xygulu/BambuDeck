/// Bambu Cloud helpers: JWT user-id extraction and the device-bind list.
///
/// Ported from BambuHelper `src/bambu_cloud.cpp` / `cloud_login.cpp`
/// (token-based paths). The interactive password / email-code login flow
/// arrives in a later iteration; this module covers everything a client
/// needs after it holds an access token.
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';

class CloudDevice {
  const CloudDevice({
    required this.devId,
    required this.devName,
    required this.modelName,
    required this.productName,
    required this.online,
  });

  final String devId; // printer serial
  final String devName;
  final String modelName; // e.g. "C12" (hardware id)
  final String productName; // e.g. "P1S"
  final bool online;

  @override
  String toString() => 'CloudDevice($devId $productName "$devName" '
      '${online ? "online" : "offline"})';
}

/// Extract `u_{uid}` from a JWT access token payload (field `uid`).
/// Returns null when the token is not a JWT or carries no uid.
String? extractCloudUserId(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  final payload = _decodeBase64Url(parts[1]);
  if (payload == null) return null;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final uid = map['uid'];
    if (uid == null) return null;
    return 'u_$uid';
  } on FormatException {
    return null;
  }
}

String? _decodeBase64Url(String s) {
  final normalized = base64.normalize(s.replaceAll('-', '+').replaceAll('_', '/'));
  try {
    return utf8.decode(base64.decode(normalized));
  } on FormatException {
    return null;
  }
}

/// Fetch the printers bound to the account behind [token].
///
/// GET `{region.apiBase}/v1/iot-service/api/user/bind?device_type=all`
/// with `Authorization: Bearer <token>`. CA-verified TLS only.
Future<List<CloudDevice>> fetchCloudDevices(String token, CloudRegion region,
    {HttpClient? client}) async {
  final own = client ?? HttpClient();
  final uri = Uri.parse(
      '${region.apiBase}/v1/iot-service/api/user/bind?device_type=all');
  try {
    final req = await own.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    if (res.statusCode != 200) {
      throw HttpException('bind API ${res.statusCode}: $body',
          uri: uri);
    }
    final doc = jsonDecode(body) as Map<String, dynamic>;
    final devices = doc['devices'];
    if (devices is! List) return const [];
    return devices
        .whereType<Map<String, dynamic>>()
        .map((d) => CloudDevice(
              devId: d['dev_id']?.toString() ?? '',
              devName: d['dev_name']?.toString() ?? '',
              modelName: d['dev_model_name']?.toString() ?? '',
              productName: d['dev_product_name']?.toString() ?? '',
              online: d['online'] == true ||
                  d['online']?.toString() == 'true',
            ))
        .toList();
  } finally {
    if (client == null) own.close();
  }
}
