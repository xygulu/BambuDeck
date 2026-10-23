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
    this.accessCode = '',
  });

  final String devId; // printer serial
  final String devName; // user-assigned name (bind field `name`)
  final String modelName; // e.g. "C12" (hardware id)
  final String productName; // e.g. "P1S"
  final bool online;

  /// LAN access code (bind field `dev_access_code`). Empty when the account
  /// has never opened LAN mode for this device.
  final String accessCode;

  @override
  String toString() => 'CloudDevice($devId $productName "$devName" '
      '${online ? "online" : "offline"})';
}

/// Extract `u_{uid}` from a JWT access token payload. The id lives under
/// `uid`, `sub`, or `user_id` depending on login path (match the helper's
/// chain). Returns null when the token is not a JWT — CN SMS login returns an
/// opaque 144-char token, so callers fall back to [resolveCloudUserId].
String? extractCloudUserId(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  final payload = _decodeBase64Url(parts[1]);
  if (payload == null) return null;
  try {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final uid = map['uid'] ?? map['sub'] ?? map['user_id'];
    if (uid == null) return null;
    final s = uid.toString().replaceFirst(RegExp(r'^u_'), '');
    return s.isEmpty ? null : 'u_$s';
  } on FormatException {
    return null;
  }
}

/// Resolve the `u_{uid}` used as the cloud-MQTT username and the helper
/// account-match gate. JWT first, then `/my/profile` for non-JWT tokens
/// (CN SMS login). Mirrors bconnect_cloud.resolve_uid: `uidStr`/`uid`/`sub`.
Future<String?> resolveCloudUserId(String token, CloudRegion region) async {
  final fromJwt = extractCloudUserId(token);
  if (fromJwt != null) return fromJwt;

  final uri = Uri.parse('${region.apiBase}/v1/user-service/my/profile');
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.set(
        HttpHeaders.userAgentHeader, 'bambu_network_agent/01.09.05.01');
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    if (res.statusCode != 200) return null;
    final doc = jsonDecode(body);
    if (doc is! Map<String, dynamic>) return null;
    final raw = doc['uidStr'] ?? doc['uid'] ?? doc['sub'];
    final s = raw?.toString().replaceFirst(RegExp(r'^u_'), '') ?? '';
    return s.isEmpty ? null : 'u_$s';
  } catch (_) {
    return null;
  } finally {
    client.close();
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

// ---------------------------------------------------------------------------
// Interactive sign-in (account+password / account+email-code).
// Endpoint shapes mirror BambuHelper cloud_login.cpp, measured on hardware.
// ---------------------------------------------------------------------------

/// What the account endpoint answered with.
sealed class LoginOutcome {
  const LoginOutcome();
}

/// Signed in - the access token (JWT).
class LoginToken extends LoginOutcome {
  const LoginToken(this.token);
  final String token;
}

/// TOTP second factor demanded. The TOTP leg rides the website host with a
/// cookie session (BambuHelper does a CSRF dance we do not replicate), so the
/// client should steer the user to the email-code path instead.
class LoginNeedsTfa extends LoginOutcome {
  const LoginNeedsTfa(this.tfaKey);
  final String tfaKey;
}

/// Bambu emailed a login code; sign in again with [cloudLogin] and [code].
class LoginNeedsEmailCode extends LoginOutcome {
  const LoginNeedsEmailCode();
}

/// The account endpoint wraps the token differently per endpoint; check both
/// spellings inside and inside a "data" wrapper (BambuHelper extractToken).
String? _extractToken(Map<String, dynamic> doc) {
  for (final container in [doc, doc['data']]) {
    if (container is! Map<String, dynamic>) continue;
    for (final key in const ['accessToken', 'token']) {
      final v = container[key];
      if (v is String && v.isNotEmpty) return v;
    }
  }
  return null;
}

/// Pull a human line out of an error body ("Incorrect account or password.")
/// instead of dumping the whole JSON envelope at the user.
String _serverMessage(String body) {
  try {
    final doc = jsonDecode(body);
    if (doc is Map<String, dynamic>) {
      for (final key in const ['error', 'message', 'msg']) {
        final v = doc[key];
        if (v is String && v.isNotEmpty) return v;
      }
    }
  } on FormatException {
    // not JSON - fall through to the raw body
  }
  return body.isEmpty ? '(no body)' : body;
}

/// POST JSON and return `(status, rawBody)` without interpreting the body.
Future<(int, String)> _postRaw(Uri uri, Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    // Bambu's WAF refuses unknown agents on some paths; pose as its own
    // network agent (same UA BambuHelper sends).
    req.headers.set(
        HttpHeaders.userAgentHeader, 'bambu_network_agent/01.09.05.01');
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    return (res.statusCode, text);
  } finally {
    client.close();
  }
}

/// POST JSON and parse the answer as a JSON object (login / device-bind
/// endpoints). Throws [HttpException] on non-200, [FormatException] if a
/// 200 body is not JSON.
Future<Map<String, dynamic>> _postJson(
    Uri uri, Map<String, dynamic> body) async {
  final (status, text) = await _postRaw(uri, body);
  if (status != 200) {
    throw HttpException('HTTP $status: ${_serverMessage(text)}', uri: uri);
  }
  final doc = jsonDecode(text);
  return doc is Map<String, dynamic> ? doc : <String, dynamic>{};
}

/// POST JSON and only require a 200. The send-code endpoints answer 200 with
/// an EMPTY body on success (BambuHelper cloud_login.cpp never parses it),
/// so parsing here would throw `Unexpected end of input`.
Future<void> _postStatus(Uri uri, Map<String, dynamic> body) async {
  final (status, text) = await _postRaw(uri, body);
  if (status != 200) {
    throw HttpException('HTTP $status: ${_serverMessage(text)}', uri: uri);
  }
}

/// Sign in with account + password, or account + emailed code.
///
/// `account` accepts an email or a phone number (CN accounts sign in with
/// their phone number + password). Exactly one of [password] / [code] must
/// be given; the code form goes with [cloudSendLoginCode].
Future<LoginOutcome> cloudLogin({
  required CloudRegion region,
  required String account,
  String? password,
  String? code,
}) async {
  final uri = Uri.parse('${region.apiBase}/v1/user-service/user/login');
  final body = <String, dynamic>{'account': account};
  if (password != null) body['password'] = password;
  if (code != null) body['code'] = code;
  final doc = await _postJson(uri, body);

  final token = _extractToken(doc);
  if (token != null) return LoginToken(token);

  final loginType = doc['loginType']?.toString() ?? '';
  final tfaKey = doc['tfaKey']?.toString() ?? '';
  // Measured on a TOTP account: the challenge arrives with an EMPTY loginType
  // and a tfaKey - the key, not the type, is what decides (BambuHelper note).
  if (loginType == 'tfa' || (loginType.isEmpty && tfaKey.isNotEmpty)) {
    if (tfaKey.isEmpty) {
      throw const HttpException('两步验证挑战缺失 tfaKey');
    }
    return LoginNeedsTfa(tfaKey);
  }
  if (loginType == 'verifyCode') return const LoginNeedsEmailCode();
  throw HttpException('登录被拒绝: ${jsonEncode(doc)}', uri: uri);
}

/// True when [account] reads as an email address rather than a phone
/// number - decides whether a login code goes by email or by SMS.
bool isEmailAccount(String account) => account.contains('@');

/// Send a login code for [account] (type "codeLogin"), then sign in with
/// [cloudLogin] + [code]. Email accounts hit `sendemail/code`; phone
/// accounts (registered by number) hit `sendsmscode` - Bambu demands a
/// verification code for password login on these, and no email is bound.
Future<void> cloudSendLoginCode({
  required CloudRegion region,
  required String account,
}) async {
  if (isEmailAccount(account)) {
    final uri =
        Uri.parse('${region.apiBase}/v1/user-service/user/sendemail/code');
    await _postStatus(uri, {'email': account, 'type': 'codeLogin'});
  } else {
    final uri =
        Uri.parse('${region.apiBase}/v1/user-service/user/sendsmscode');
    await _postStatus(uri, {'phone': account, 'type': 'codeLogin'});
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
              // The user-set name is `name`; `dev_name` does not exist in the
              // bind payload (measured - it answered empty and left the list
              // with no name).
              devName: (d['name'] ?? d['dev_name'])?.toString() ?? '',
              modelName: d['dev_model_name']?.toString() ?? '',
              productName: d['dev_product_name']?.toString() ?? '',
              online: d['online'] == true ||
                  d['online']?.toString() == 'true',
              accessCode: d['dev_access_code']?.toString() ?? '',
            ))
        .toList();
  } finally {
    if (client == null) own.close();
  }
}

/// Cover image URL of a device's most recent task that has one (Bambu
/// Handy's 任务预览图). GET `{region.apiBase}/v1/user-service/my/tasks`
/// with Bearer auth; nodes come newest-first, so the first entry for
/// [devId] carrying a non-empty `cover` wins. Null when none does.
Future<String?> fetchCloudTaskCover(
  String token,
  CloudRegion region,
  String devId, {
  HttpClient? client,
}) async {
  final own = client ?? HttpClient();
  final uri = Uri.parse('${region.apiBase}/v1/user-service/my/tasks');
  try {
    final req = await own.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    // The WAF in front of user-service drops requests without the agent UA.
    req.headers.set(
        HttpHeaders.userAgentHeader, 'bambu_network_agent/01.09.05.01');
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    if (res.statusCode != 200) {
      throw HttpException('tasks API ${res.statusCode}: $body', uri: uri);
    }
    final doc = jsonDecode(body);
    // Shape seen in the wild: {data: {nodes: [...]}}; accept a bare list
    // under data too, and dev_id either nested or flattened on the node.
    List<Object?> nodes = const [];
    if (doc is Map<String, dynamic>) {
      final data = doc['data'];
      if (data is Map<String, dynamic>) {
        nodes = data['nodes'] as List? ?? const [];
      } else if (data is List) {
        nodes = data;
      }
    } else if (doc is List) {
      nodes = doc;
    }
    for (final n in nodes) {
      if (n is! Map<String, dynamic>) continue;
      final info = n['device_info'];
      final nodeId = info is Map<String, dynamic>
          ? info['dev_id']?.toString()
          : n['dev_id']?.toString();
      if (nodeId != devId) continue;
      final cover = n['cover']?.toString() ?? '';
      if (cover.isNotEmpty) return cover;
    }
    return null;
  } finally {
    if (client == null) own.close();
  }
}
