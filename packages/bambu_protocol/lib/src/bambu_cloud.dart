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

Future<Map<String, dynamic>> _postJson(
    Uri uri, Map<String, dynamic> body) async {
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
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}: ${_serverMessage(text)}',
          uri: uri);
    }
    final doc = jsonDecode(text);
    return doc is Map<String, dynamic> ? doc : <String, dynamic>{};
  } finally {
    client.close();
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
    await _postJson(uri, {'email': account, 'type': 'codeLogin'});
  } else {
    final uri =
        Uri.parse('${region.apiBase}/v1/user-service/user/sendsmscode');
    await _postJson(uri, {'phone': account, 'type': 'codeLogin'});
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
