/// Bambu MQTT command signing (ClusterM/open-bamboo-networking §10.4).
///
/// Non-developer-mode firmware rejects every top-level `print` frame that
/// lacks a verified signature envelope (print_error 84033543 - the
/// 暂停/停止/换盘 silent-drop symptom), while `pushing`/`system` frames
/// stay unsigned. Wire envelope:
///
/// ```json
/// {"header":{"cert_id":"...","payload_len":N,"sign_alg":"RSA_SHA256",
///            "sign_string":"<base64>","sign_ver":"v1.0"},
///  "print":{...}}
/// ```
///
/// The signature is RSA-SHA256 (PKCS#1 v1.5) over the exact UTF-8 bytes of
/// `{"print":<print>}`. The firmware reconstructs that string from the
/// envelope bytes, so the `print` section we sign and the one we emit must
/// be byte-identical - this module serializes the print node exactly once
/// and feeds the same string to both the signer and the envelope.
///
/// The signing identity is the Bambu Connect interop key the community
/// extracted in Jan 2025 for exactly this purpose. The app reads it from
/// `~/.bambudeck/signing_key.pem` (kept outside the repo on purpose);
/// without the file BambuMqttClient falls back to unsigned frames.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// `cert_id` of the signing certificate: lowercase-hex serial number +
/// RFC4514 issuer, no separator (precomputed with openssl from the cert
/// matching the signing key; the firmware string-matches this against its
/// trusted app-cert table).
const String kSigningCertId =
    'ee3cac0712ceeacda8b7fbc42e74ba2cCN=GLOF3813734089.bambulab.com';

/// SHA-256 DigestInfo ASN.1 prefix for the PKCS#1 v1.5 block.
const _sha256DigestInfoPrefix = '0609608648016503040201';

/// RSA-SHA256 signer for Bambu `print` command envelopes.
class BambuCommandSigner {
  /// Parses a PKCS#8 PEM private key (the ~/.bambudeck form).
  factory BambuCommandSigner.fromPem(String privateKeyPem) =>
      BambuCommandSigner(_parsePkcs8Pem(privateKeyPem));

  /// Direct construction from an already-parsed key (tests).
  BambuCommandSigner(RSAPrivateKey key) : _key = key {
    _engine = RSASigner(SHA256Digest(), _sha256DigestInfoPrefix)
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(key));
  }

  final RSAPrivateKey _key;
  late final RSASigner _engine;

  /// Public key matching this private key. pointycastle's RSAPrivateKey
  /// constructor stores the PRIVATE exponent in the inherited `exponent`
  /// slot, so the true public exponent is recovered from the CRT halves:
  /// e = d⁻¹ mod λ(n), λ = lcm(p-1, q-1).
  RSAPublicKey get publicKey {
    final p = _key.p;
    final q = _key.q;
    final d = _key.privateExponent;
    if (p != null && q != null && d != null) {
      final lambda =
          (p - BigInt.one) * (q - BigInt.one) ~/ (p - BigInt.one).gcd(q - BigInt.one);
      return RSAPublicKey(_key.modulus!, d.modInverse(lambda));
    }
    return RSAPublicKey(_key.modulus!, _key.exponent!);
  }

  /// Serializes [printNode] once, signs `{"print":<bytes>}`, and returns the
  /// full wire envelope whose `print` section is byte-for-byte what was
  /// signed (the firmware's verify path depends on that equality).
  String wrapSigned(Map<String, dynamic> printNode) {
    final printText = json.encode(printNode);
    final toSign = utf8.encode('{"print":$printText}');
    final signature = _engine.generateSignature(toSign);
    final header = json.encode({
      'cert_id': kSigningCertId,
      'payload_len': toSign.length,
      'sign_alg': 'RSA_SHA256',
      'sign_string': base64.encode(signature.bytes),
      'sign_ver': 'v1.0',
    });
    return '{"header":$header,"print":$printText}';
  }

  /// Standard RSA-SHA256 verify over [message] - proves our sign path
  /// round-trips (tests).
  bool verify(Uint8List message, Uint8List signature,
      {RSAPublicKey? withKey}) {
    final verifier = RSASigner(SHA256Digest(), _sha256DigestInfoPrefix)
      ..init(false, PublicKeyParameter<RSAPublicKey>(withKey ?? publicKey));
    return verifier.verifySignature(message, RSASignature(signature));
  }
}

RSAPrivateKey _parsePkcs8Pem(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  final der = base64.decode(body);
  final top =
      ASN1Parser(Uint8List.fromList(der)).nextObject() as ASN1Sequence;
  // PrivateKeyInfo ::= SEQUENCE { version INTEGER,
  //   AlgorithmIdentifier SEQUENCE, privateKey OCTET STRING }
  final pkcs1 =
      ASN1Parser((top.elements![2] as ASN1OctetString).octets!).nextObject()
          as ASN1Sequence;
  BigInt intAt(int i) => (pkcs1.elements![i] as ASN1Integer).integer!;
  // RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }
  return RSAPrivateKey(intAt(1), intAt(3), intAt(4), intAt(5));
}
