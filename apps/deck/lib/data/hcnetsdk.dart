import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ptz_client.dart';

/// Pure-Dart HCNetSDK (Hikvision / EZVIZ) command-port client for port 8000.
///
/// Ported from `RenierM26/pyEzvizApi` `pyezvizapi/hcnetsdk.py`. This is the
/// path BambuDeck takes to drive EZVIZ PTZ without the vendor SDK: the
/// official macOS HCNetSDK dylib is x86_64-only, so FFI is not an option on
/// Apple Silicon.
///
/// Frame layout (every header word is big-endian):
/// ```
/// 16-byte header: total_length | family | auth_word | command_id
/// body:           4B local-ip-word (reversed) | 4B session-id | 8B zeros | tail
/// ```
/// Login family = 0x5A000000, control family = 0x63000000.

// --- protocol constants -------------------------------------------------

const _loginFamily = 0x5A000000;
const _controlFamily = 0x63000000;
const _loginField12 = 0x00010000;

final _loginSeedPrefix = Uint8List.fromList(
    [0x05, 0x01, 0x3d, 0x4b, 0x00, 0x00, 0x00, 0x01]);
final _loginSeedSuffix =
    Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6f, 0x00]);

// Fixed RSA-1024 keypair. The camera only wraps a per-login challenge in this
// public key, so a fixed key (instead of generating one per login) avoids a
// pointycastle dependency. `_publicKeyDer` is the PKCS#1 RSAPublicKey DER sent
// in login frame 1; `_rsaN`/`_rsaD` decrypt the challenge via BigInt.modPow.
final _rsaN = BigInt.parse(
    'aea1d881b2b16ad190f5432873095750c7c0f056d2b63a2abaf8a9f88957c68a2a5c'
    '8332c1444645a45604e71e692695e25167af22a5edfb28376a6870de50cf3b4c53b'
    '3c594060edc9d5cb5140121eb677b8d3d6d5ca9a93ffd433ea3173ba211700bb448'
    '41f8afd857a5cfde1ad7511faaeefc6634d41bc3555b82e88d4bbd',
    radix: 16);
final _rsaD = BigInt.parse(
    '0fdedd924bef1bca17e6724806cc5e8714e04ff75407039a468bbac6bf949e9287e'
    'f086d606b1807d43b8d0e84110254b4d0b91f8d828ef2386170e634fbbf542f6fda'
    '2081958d53e25ef78f2eb866cfb50d6e76a2e1faf5e5ef2d1c91b7bc53a71fd95da'
    'edbe3df40988ef73ad5ed822ba7977d6a53c9f9762ea31143a326f1',
    radix: 16);
final _publicKeyDer = Uint8List.fromList(_hexDecode(
    '30818902818100aea1d881b2b16ad190f5432873095750c7c0f056d2b63a2abaf8a'
    '9f88957c68a2a5c8332c1444645a45604e71e692695e25167af22a5edfb28376a68'
    '70de50cf3b4c53b3c594060edc9d5cb5140121eb677b8d3d6d5ca9a93ffd433ea31'
    '73ba211700bb44841f8afd857a5cfde1ad7511faaeefc6634d41bc3555b82e88d4b'
    'bd0203010001'));

// PTZ command ids (HcNetSdkPtzCommand): the `dwPTZCommand` values carried in
// the body tail, matching the native SDK enum.
const hcPtzTiltUp = 21;
const hcPtzTiltDown = 22;
const hcPtzPanLeft = 23;
const hcPtzPanRight = 24;
const hcPtzZoomIn = 11;
const hcPtzZoomOut = 12;

/// PTZ pan/tilt speed carried as a third word in the control tail. The EZVIZ
/// app defaults to 5; 0 is slowest, 7 fastest. We pick a slower value so a
/// hold doesn't slam the gimbal to its mechanical limit in ~2 s (that was the
/// 8-byte no-speed tail's default = fastest).
const hcPtzSpeedDefault = 2;

/// `NET_DVR_PTZControlWithSpeed_Other` command_id, captured from the EZVIZ app
/// driving a live camera on 192.168.100.102. The body tail is just
/// `[channel][signed command]` — a positive word starts a direction, its
/// two's-complement negative stops it (e.g. +21 tilt-up, -21 stop-tilt). The
/// camera answers empty success (field_4 == field_8 == 1).
const _ptzControlCommandId = 0x00030200;

/// `NET_DVR_STDXMLConfig` command_id — the reference's proven control path for
/// ISAPI requests over the command port.
const _stdxmlCommandId = 0x117000;

// --- AES-128 (4-round command-auth variant) -----------------------------

const _aesSbox = <int>[
  0x63, 0x7C, 0x77, 0x7B, 0xF2, 0x6B, 0x6F, 0xC5, 0x30, 0x01, 0x67, 0x2B,
  0xFE, 0xD7, 0xAB, 0x76, 0xCA, 0x82, 0xC9, 0x7D, 0xFA, 0x59, 0x47, 0xF0,
  0xAD, 0xD4, 0xA2, 0xAF, 0x9C, 0xA4, 0x72, 0xC0, 0xB7, 0xFD, 0x93, 0x26,
  0x36, 0x3F, 0xF7, 0xCC, 0x34, 0xA5, 0xE5, 0xF1, 0x71, 0xD8, 0x31, 0x15,
  0x04, 0xC7, 0x23, 0xC3, 0x18, 0x96, 0x05, 0x9A, 0x07, 0x12, 0x80, 0xE2,
  0xEB, 0x27, 0xB2, 0x75, 0x09, 0x83, 0x2C, 0x1A, 0x1B, 0x6E, 0x5A, 0xA0,
  0x52, 0x3B, 0xD6, 0xB3, 0x29, 0xE3, 0x2F, 0x84, 0x53, 0xD1, 0x00, 0xED,
  0x20, 0xFC, 0xB1, 0x5B, 0x6A, 0xCB, 0xBE, 0x39, 0x4A, 0x4C, 0x58, 0xCF,
  0xD0, 0xEF, 0xAA, 0xFB, 0x43, 0x4D, 0x33, 0x85, 0x45, 0xF9, 0x02, 0x7F,
  0x50, 0x3C, 0x9F, 0xA8, 0x51, 0xA3, 0x40, 0x8F, 0x92, 0x9D, 0x38, 0xF5,
  0xBC, 0xB6, 0xDA, 0x21, 0x10, 0xFF, 0xF3, 0xD2, 0xCD, 0x0C, 0x13, 0xEC,
  0x5F, 0x97, 0x44, 0x17, 0xC4, 0xA7, 0x7E, 0x3D, 0x64, 0x5D, 0x19, 0x73,
  0x60, 0x81, 0x4F, 0xDC, 0x22, 0x2A, 0x90, 0x88, 0x46, 0xEE, 0xB8, 0x14,
  0xDE, 0x5E, 0x0B, 0xDB, 0xE0, 0x32, 0x3A, 0x0A, 0x49, 0x06, 0x24, 0x5C,
  0xC2, 0xD3, 0xAC, 0x62, 0x91, 0x95, 0xE4, 0x79, 0xE7, 0xC8, 0x37, 0x6D,
  0x8D, 0xD5, 0x4E, 0xA9, 0x6C, 0x56, 0xF4, 0xEA, 0x65, 0x7A, 0xAE, 0x08,
  0xBA, 0x78, 0x25, 0x2E, 0x1C, 0xA6, 0xB4, 0xC6, 0xE8, 0xDD, 0x74, 0x1F,
  0x4B, 0xBD, 0x8B, 0x8A, 0x70, 0x3E, 0xB5, 0x66, 0x48, 0x03, 0xF6, 0x0E,
  0x61, 0x35, 0x57, 0xB9, 0x86, 0xC1, 0x1D, 0x9E, 0xE1, 0xF8, 0x98, 0x11,
  0x69, 0xD9, 0x8E, 0x94, 0x9B, 0x1E, 0x87, 0xE9, 0xCE, 0x55, 0x28, 0xDF,
  0x8C, 0xA1, 0x89, 0x0D, 0xBF, 0xE6, 0x42, 0x68, 0x41, 0x99, 0x2D, 0x0F,
  0xB0, 0x54, 0xBB, 0x16,
];
const _aesRcon = <int>[0x01, 0x02, 0x04, 0x08];

List<List<int>> _roundKeys(Uint8List key, int rounds) {
  final words = <List<int>>[
    for (var i = 0; i < 16; i += 4) [key[i], key[i + 1], key[i + 2], key[i + 3]],
  ];
  while (words.length < 4 * (rounds + 1)) {
    var word = List<int>.from(words.last);
    if (words.length % 4 == 0) {
      word = [word[1], word[2], word[3], word[0]];
      word = [for (final b in word) _aesSbox[b]];
      word[0] ^= _aesRcon[(words.length ~/ 4) - 1];
    }
    final prev = words[words.length - 4];
    words.add([for (var i = 0; i < 4; i++) prev[i] ^ word[i]]);
  }
  final expanded = <int>[];
  for (final w in words) {
    expanded.addAll(w);
  }
  return [
    for (var i = 0; i < 16 * (rounds + 1); i += 16)
      expanded.sublist(i, i + 16),
  ];
}

Uint8List _addRoundKey(Uint8List state, List<int> roundKey) =>
    Uint8List.fromList(
        [for (var i = 0; i < 16; i++) state[i] ^ roundKey[i]]);

Uint8List _subBytes(Uint8List state) =>
    Uint8List.fromList([for (final b in state) _aesSbox[b]]);

Uint8List _shiftRows(Uint8List state) => Uint8List.fromList([
      state[0], state[5], state[10], state[15], //
      state[4], state[9], state[14], state[3],
      state[8], state[13], state[2], state[7],
      state[12], state[1], state[6], state[11],
    ]);

int _xtime(int v) => ((v << 1) ^ ((v & 0x80) != 0 ? 0x1B : 0)) & 0xFF;

Uint8List _mixColumns(Uint8List state) {
  final out = <int>[];
  for (var c = 0; c < 16; c += 4) {
    final a = state.sublist(c, c + 4);
    final d = [for (final v in a) _xtime(v)];
    out.addAll([
      d[0] ^ a[3] ^ a[2] ^ d[1] ^ a[1],
      d[1] ^ a[0] ^ a[3] ^ d[2] ^ a[2],
      d[2] ^ a[1] ^ a[0] ^ d[3] ^ a[3],
      d[3] ^ a[2] ^ a[1] ^ d[0] ^ a[0],
    ]);
  }
  return Uint8List.fromList(out);
}

/// The native SDK's four-round AES-128 over one 16-byte block.
Uint8List hcNetSdkFourRoundAes(Uint8List block, Uint8List key) {
  final rk = _roundKeys(key, 4);
  var state = _addRoundKey(block, rk[0]);
  for (var r = 1; r < 4; r++) {
    state = _subBytes(state);
    state = _shiftRows(state);
    state = _mixColumns(state);
    state = _addRoundKey(state, rk[r]);
  }
  state = _subBytes(state);
  state = _shiftRows(state);
  return _addRoundKey(state, rk[4]);
}

// --- small helpers ------------------------------------------------------

List<int> _hexDecode(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];

Uint8List _u32be(int v) {
  final b = Uint8List(4);
  ByteData.sublistView(b).setUint32(0, v, Endian.big);
  return b;
}

/// The login/control "local IP word": the 4 IPv4 bytes in reverse order.
Uint8List _localIpWord(String ip) {
  final parts = ip.split('.');
  return Uint8List.fromList(
      [for (final p in parts.reversed) int.parse(p) & 0xFF]);
}

Uint8List _loginPrefix(String ip) =>
    Uint8List.fromList([..._loginSeedPrefix, ..._localIpWord(ip), ..._loginSeedSuffix]);

Uint8List _username(String name) {
  final b = Uint8List(48);
  final bytes = name.codeUnits;
  b.setRange(0, bytes.length > 48 ? 48 : bytes.length, bytes);
  return b;
}

/// PKCS#1 v1.5 decrypt of the 128-byte challenge block with the fixed key.
Uint8List _rsaDecrypt(Uint8List cipher) {
  final c = BigInt.parse(
      cipher.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      radix: 16);
  final m = c.modPow(_rsaD, _rsaN);
  var em = m.toRadixString(16);
  if (em.length % 2 != 0) em = '0$em';
  final bytes = Uint8List.fromList(_hexDecode(em.padLeft(256, '0')));
  // bytes should be 00 02 [PS] 00 [message].
  var i = 2;
  while (i < bytes.length && bytes[i] != 0) {
    i++;
  }
  if (i >= bytes.length) throw const FormatException('bad PKCS#1 padding');
  return bytes.sublist(i + 1);
}

// --- frame --------------------------------------------------------------

Uint8List _buildFrame(Uint8List body,
    {required int family, int authWord = 0, int commandId = 0}) {
  final header = Uint8List(16);
  final bd = ByteData.sublistView(header);
  bd.setUint32(0, 16 + body.length, Endian.big);
  bd.setUint32(4, family, Endian.big);
  bd.setUint32(8, authWord, Endian.big);
  bd.setUint32(12, commandId, Endian.big);
  return Uint8List.fromList([...header, ...body]);
}

/// A login/control session: everything the post-login control frames need.
class HcNetSdkSession {
  HcNetSdkSession({
    required this.sessionId,
    required this.authSeed,
    required this.challenge,
    required this.passwordSeed,
    required this.serial,
  });

  /// Network-order 4-byte login session id (reused in control bodies).
  final Uint8List sessionId;
  /// auth_seed = the login response's second header word.
  final int authSeed;
  /// RSA-decrypted challenge (NUL-stripped); its first 16 bytes are the AES key.
  final Uint8List challenge;
  final Uint8List passwordSeed;
  final String serial;
}

/// Buffers a [Socket]'s single subscription into exact-length reads.
class _BufferedSocket {
  _BufferedSocket(this._socket) {
    _socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  final Socket _socket;
  final List<int> _buf = [];
  final List<Completer<void>> _waiters = [];
  Object? _error;
  bool _done = false;

  void _onData(Uint8List data) {
    _buf.addAll(data);
    _wake();
  }

  void _onError(Object e) {
    _error = e;
    _done = true;
    _wake();
  }

  void _onDone() {
    _done = true;
    _wake();
  }

  void _wake() {
    for (final w in List.of(_waiters)) {
      if (!w.isCompleted) w.complete();
    }
  }

  Future<void> _waitFor(int n) async {
    while (_buf.length < n && _error == null && !_done) {
      final c = Completer<void>();
      _waiters.add(c);
      await c.future;
    }
  }

  Future<Uint8List> readExact(int n) async {
    await _waitFor(n);
    if (_buf.length < n) {
      final e = _error;
      if (e != null) throw e;
      throw const SocketException('connection closed');
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }
}

/// One post-login control command over a fresh command-port socket.
class HcNetSdkClient {
  HcNetSdkClient({
    required this.host,
    this.port = 8000,
    required this.localIp,
    this.timeout = const Duration(seconds: 5),
  });

  final String host;
  final int port;
  final String localIp;
  final Duration timeout;

  Future<Socket> _connect() => Socket.connect(host, port, timeout: timeout);

  Future<Uint8List> _exchange(Uint8List request) async {
    final sock = await _connect();
    final reader = _BufferedSocket(sock);
    try {
      sock.add(request);
      return await _readFrame(reader);
    } finally {
      sock.destroy();
    }
  }

  /// One full frame (16-byte header + body) off [reader].
  Future<Uint8List> _readFrame(_BufferedSocket reader) async {
    final header = await reader.readExact(16).timeout(timeout);
    final total = ByteData.sublistView(header).getUint32(0, Endian.big);
    if (total < 16) return header;
    final body = await reader.readExact(total - 16).timeout(timeout);
    return Uint8List.fromList([...header, ...body]);
  }

  /// Full RSA/challenge login handshake. Returns the session on success.
  ///
  /// The handshake is one conversation on a SINGLE socket — frame 1 (challenge
  /// request) → response → frame 2 (proofs) → response. The reference closes
  /// the login socket afterwards and sends authenticated control commands on
  /// fresh sockets, so [control]/[ptzControl] keep using [_exchange].
  Future<HcNetSdkSession> login({
    required String username,
    required String password,
  }) async {
    final sock = await _connect();
    final reader = _BufferedSocket(sock);
    try {
      // Frame 1: seed prefix + username + PKCS#1 public key.
      final frame1 = _buildFrame(
        Uint8List.fromList([
          ..._loginPrefix(localIp),
          ..._username(username),
          ..._publicKeyDer,
        ]),
        family: _loginFamily,
        commandId: _loginField12,
      );
      sock.add(frame1);
      final resp1 = await _readFrame(reader);
      final resp1Body = resp1.sublist(16);
      if (resp1Body.length < 128 + 64) {
        throw const FormatException('login challenge response truncated');
      }
      final challenge =
          _rsaDecrypt(Uint8List.fromList(resp1Body.sublist(0, 128)));
      final challengeTrimmed = _rstripNul(challenge);
      final passwordSeed = Uint8List.fromList(resp1Body.sublist(128, 192));

      // Frame 2: proofs.
      final digestBytes = sha256
          .convert([...username.codeUnits, ...passwordSeed, ...password.codeUnits])
          .toString()
          .codeUnits;
      final primary =
          Hmac(md5, challengeTrimmed).convert(username.codeUnits).bytes;
      final secondary = Hmac(md5, challengeTrimmed).convert(digestBytes).bytes;
      final frame2 = _buildFrame(
        Uint8List.fromList([
          ..._loginPrefix(localIp),
          ...primary,
          ...List.filled(32 - primary.length, 0),
          ...secondary.sublist(0, 16),
        ]),
        family: _loginFamily,
        commandId: _loginField12,
      );
      sock.add(frame2);
      final resp2 = await _readFrame(reader);
      final resp2Header = Uint8List.fromList(resp2.sublist(0, 16));
      final resp2Body = resp2.sublist(16);
      final authSeed =
          ByteData.sublistView(resp2Header).getUint32(4, Endian.big);
      if (resp2Body.length < 4) {
        throw const FormatException('login session response truncated');
      }
      final sessionId = Uint8List.fromList(resp2Body.sublist(0, 4));
      if (sessionId[0] == 0 && sessionId[1] == 0 && sessionId[2] == 0 && sessionId[3] == 0) {
        throw const FormatException('login failed (empty session id)');
      }
      final serialBytes = resp2Body.length >= 48 ? resp2Body.sublist(4, 48) : resp2Body.sublist(4);
      final serial = String.fromCharCodes(serialBytes).split('\u0000').first;

      return HcNetSdkSession(
        sessionId: sessionId,
        authSeed: authSeed,
        challenge: challengeTrimmed,
        passwordSeed: passwordSeed,
        serial: serial,
      );
    } finally {
      sock.destroy();
    }
  }

  /// Build + send one post-login control frame, returning the raw response.
  Future<Uint8List> control(
    HcNetSdkSession session, {
    required int commandId,
    Uint8List? bodyTail,
    Uint8List? maskSeed,
  }) {
    final tail = bodyTail ?? Uint8List(0);
    final mask = maskSeed ?? Uint8List(0);
    final body = Uint8List.fromList([
      ..._localIpWord(localIp),
      ...session.sessionId,
      ...List.filled(8, 0),
      ...tail,
    ]);
    final auth = hcNetSdkAuthWord(
      sessionId: session.sessionId,
      authSeed: session.authSeed,
      commandId: commandId,
      challenge: session.challenge,
      maskSeed: mask,
    );
    return _exchange(_buildFrame(
      body,
      family: _controlFamily,
      authWord: auth,
      commandId: commandId,
    ));
  }

  /// Run an ISAPI request (`GET/PUT /ISAPI/...`) through the STDXML command.
  /// This is the reference's proven control path on EZVIZ devices: the request
  /// text is carried as the command tail and the response body carries XML/JSON.
  Future<Uint8List> stdxml(
    HcNetSdkSession session, {
    required String request,
    String inBuffer = '',
  }) {
    final requestBytes = utf8.encode(request);
    final inBytes = utf8.encode(inBuffer);
    final payload = Uint8List.fromList([...requestBytes, ...inBytes]);
    final totalLength = 12 + payload.length;
    final tail = Uint8List.fromList([
      ...List.filled(8, 0),
      ..._u32be(totalLength),
      ..._u32be(requestBytes.length),
      0x01, 0x00, 0x00, 0x00, // flags
      ...payload,
    ]);
    return control(session, commandId: _stdxmlCommandId, bodyTail: tail);
  }

  /// PTZ move over the command port. [command] is an `hcPtz*` value; [stop]
  /// issues the stop for that direction. Wire format (captured from the EZVIZ
  /// app): `[channel][signed command][speed]`, the command negated to stop.
  /// The speed word was missing originally (the camera then ran at its fastest
  /// preset and a ~2 s hold slammed the gimbal to its mechanical limit).
  Future<Uint8List> ptzControl(
    HcNetSdkSession session, {
    required int command,
    required bool stop,
    int channel = 1,
    int speed = hcPtzSpeedDefault,
  }) {
    final signedCommand = stop ? -command : command;
    final tail = Uint8List.fromList([
      ..._u32be(channel),
      ..._u32be(signedCommand & 0xFFFFFFFF),
      ..._u32be(speed),
    ]);
    return control(session, commandId: _ptzControlCommandId, bodyTail: tail);
  }
}

Uint8List _rstripNul(Uint8List b) {
  var end = b.length;
  while (end > 0 && b[end - 1] == 0) {
    end--;
  }
  return Uint8List.fromList(b.sublist(0, end));
}

/// The native post-login command auth word: folds the four-round AES-128
/// result down to one little-endian word and adds the session word.
/// [challenge] supplies the AES key (its first 16 bytes).
int hcNetSdkAuthWord({
  required Uint8List sessionId,
  required int authSeed,
  required int commandId,
  required Uint8List challenge,
  Uint8List? maskSeed,
}) {
  final mask = maskSeed ?? Uint8List(0);
  final sessionWord =
      ByteData.sublistView(sessionId).getUint32(0, Endian.big);
  var maskTerm = 0;
  for (var i = 0; i < 6; i++) {
    final seed = i < mask.length ? mask[i] : 0;
    maskTerm += seed & ((sessionWord >> (5 * i)) & 0xFF);
  }
  final inputWord = (authSeed + (commandId * 2) + maskTerm) & 0xFFFFFFFF;
  final block = Uint8List(16);
  ByteData.sublistView(block).setUint32(0, inputWord, Endian.little);
  final transformed = hcNetSdkFourRoundAes(block, challenge.sublist(0, 16));
  final folded = Uint8List(4);
  for (var i = 0; i < 4; i++) {
    folded[i] = transformed[i] ^
        transformed[i + 4] ^
        transformed[i + 8] ^
        transformed[i + 12];
  }
  final foldedWord = ByteData.sublistView(folded).getUint32(0, Endian.little);
  return (foldedWord + sessionWord) & 0xFFFFFFFF;
}

/// Press-and-hold PTZ driver over the HCNetSDK command port (EZVIZ/Hikvision).
/// Mirrors [OnvifPtz]'s probe/move/stop surface so [PtzPad] can drive either
/// transport. EZVIZ cameras speak this natively on port 8000 — no ONVIF
/// enablement in the app needed — which is why the pad falls back to it when
/// ONVIF is unreachable.
class HcNetSdkPtz implements PtzClient {
  HcNetSdkPtz({
    required this.host,
    this.port = 8000,
    required this.username,
    required this.password,
    this.localIp,
    this.channel = 1,
  });

  final String host;
  final int port;

  /// Usually `admin` — the device's RTSP user name.
  final String username;

  /// The device verification code (also the RTSP password).
  final String password;

  /// Local interface IP carried in the login/control frames; auto-detected
  /// when null.
  final String? localIp;

  final int channel;

  HcNetSdkClient? _client;
  HcNetSdkSession? _session;
  int? _active;
  String? _localIp;

  /// Serializes PTZ operations so a START and its matching STOP can never
  /// interleave, and a slow login can't open a second session that would
  /// orphan a START (the "hold runs to the limit" bug).
  Future<void> _chain = Future.value();

  @override
  bool get available => _session != null;

  @override
  Future<bool> probe() async {
    if (_session != null) return true;
    return _login();
  }

  /// Full login handshake (cached local IP). Called on probe and again before
  /// each START: EZVIZ rejects PTZ with err=151 after a handful of commands on
  /// one session — and the live RTSP stream shortens that budget further — so a
  /// fresh session per press is the only reliable pattern (verified against
  /// .102: same-session locks after ~12 cmds, fresh-login-per-command never).
  Future<bool> _login() async {
    try {
      final client = HcNetSdkClient(
        host: host,
        port: port,
        localIp: _localIp ??= (localIp ?? await detectLocalIpv4()),
      );
      // EZVIZ login: `admin` + verification code first, then the reference's
      // fallback local user whose password is the md5 slice of the code.
      HcNetSdkSession session;
      try {
        session = await client.login(username: username, password: password);
      } catch (_) {
        final slice = md5
            .convert(password.codeUnits)
            .toString()
            .substring(8, 24)
            .toLowerCase();
        session = await client.login(username: 'EZ_LOCAL_USER', password: slice);
      }
      _client = client;
      _session = session;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Queues an op behind the last one so START/STOP are strictly ordered and
  /// at most one login is ever in flight. The chain keeps its own swallowed
  /// tail so a throwing op can't wedge the next one.
  Future<void> _enqueue(Future<void> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> move({double pan = 0, double tilt = 0, double zoom = 0}) async {
    final command = _commandFor(pan, tilt, zoom);
    if (command == null) return;
    // HCNetSDK's START keeps the camera moving until a single STOP — unlike
    // ONVIF ContinuousMove it has no keep-alive timeout. The pad re-issues
    // move() every 250 ms, so dedupe: only issue a new START when the
    // direction actually changes. `_active` is marked synchronously (before
    // any await) so a re-issue can't open a second session mid-login — that
    // second session's orphaned START was the "hold runs to the limit" bug.
    if (_active == command) return;
    _active = command;
    await _enqueue(() async {
      // Superseded by stop()/a new direction while queued or mid-login:
      // drop the START so the camera never keeps moving unattended.
      if (_active != command) return;
      // Fresh session per press (err=151 locks a session after a few cmds).
      if (!await _login()) {
        if (_active == command) _active = null;
        return;
      }
      if (_active != command) return;
      final session = _session;
      if (session == null) return;
      try {
        final resp = await _client!
            .ptzControl(session, command: command, stop: false, channel: channel);
        // ignore: avoid_print
        print('PTZ move cmd=$command ${_ptzVerdict(resp)}');
      } catch (e) {
        // ignore: avoid_print
        print('PTZ move cmd=$command ERROR: $e');
      }
    });
  }

  @override
  Future<void> stop() async {
    // Clear the active direction synchronously so any in-flight move()
    // drops its pending START; the matching STOP is queued behind it.
    final command = _active;
    _active = null;
    if (command == null) return;
    await _enqueue(() async {
      final session = _session;
      if (session == null) return;
      try {
        final resp = await _client!
            .ptzControl(session, command: command, stop: true, channel: channel);
        // ignore: avoid_print
        print('PTZ stop cmd=$command ${_ptzVerdict(resp)}');
      } catch (e) {
        // ignore: avoid_print
        print('PTZ stop cmd=$command ERROR: $e');
      }
    });
  }

  /// Map the pad's velocity axes to the single active direction. The pad
  /// drives one axis at a time; zoom is unused by the current pad layout.
  int? _commandFor(double pan, double tilt, double zoom) {
    if (tilt > 0) return hcPtzTiltUp;
    if (tilt < 0) return hcPtzTiltDown;
    if (pan < 0) return hcPtzPanLeft;
    if (pan > 0) return hcPtzPanRight;
    if (zoom > 0) return hcPtzZoomIn;
    if (zoom < 0) return hcPtzZoomOut;
    return null;
  }

  @override
  void dispose() {
    // Commands run on per-request sockets, so there is no connection to keep
    // open — drop the session so a disposed pad cannot fire again.
    _client = null;
    _session = null;
    _active = null;
  }
}

/// Human-readable accept/reject verdict for a PTZ response header, mirroring
/// the probe tool's judgement (field_4 == field_8 and > 1 = rejection).
String _ptzVerdict(Uint8List resp) {
  if (resp.length < 16) return 'resp ${resp.length}B';
  final f4 = ByteData.sublistView(resp).getUint32(4, Endian.big);
  final f8 = ByteData.sublistView(resp).getUint32(8, Endian.big);
  final accepted = f4 != f8 || f8 <= 1;
  return 'f4=0x${f4.toRadixString(16)} f8=0x${f8.toRadixString(16)} '
      '${accepted ? "OK" : "REJECTED(err=$f8)"}';
}

/// First non-loopback IPv4 interface address, used as the login/control
/// "local IP word" when the caller doesn't supply one. Also public: the
/// EZVIZ cloud-import flow derives the default LAN prefix from it.
Future<String> detectLocalIpv4() async {
  for (final itf
      in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in itf.addresses) {
      if (!a.address.startsWith('127.') && !a.address.startsWith('169.254.')) {
        return a.address;
      }
    }
  }
  return '127.0.0.1';
}
