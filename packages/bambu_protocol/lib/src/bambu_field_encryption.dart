/// Field encryption for secured (developer-mode-off) printers (§10.3).
///
/// On a secured printer some cleartext fields inside privileged `print`
/// objects must be replaced by RSA ciphertext under the **printer device-cert
/// public key** — `url` → `url_enc` (project_file), `param` → `param_enc`
/// (gcode_line). Signing (§bambu_signing.dart) runs *after* this step so the
/// `header.sign_string` covers the on-wire `*_enc` fields.
///
/// The device cert public key comes from the printer itself (never leaves the
/// printer's private key): LAN TLS handshake on :8883 (`CN=<serial>`) or the
/// `security.app_cert_install` reply's `printer_cert`.
///
/// Algorithm (`EncryptField`, open-bamboo-networking §10.3): plaintext is
/// split into ≤245-byte chunks (RSA-2048 PKCS#1 v1.5 ceiling = 256 − 11), each
/// chunk encrypts to one 256-byte block, blocks concatenate, whole thing
/// Base64-encoded. A short field → 1 block (256 B → ~344 Base64 chars); the
/// captured Studio temperature gcode_line → 512 B = 2 blocks.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// RSA-2048 PKCS#1 v1.5 ceiling: 256-byte block minus the 11-byte padding
/// header leaves 245 bytes of plaintext per block.
const int kFieldEncryptChunkSize = 245;

/// Blockwise RSA-PKCS#1 v1.5 field encryptor keyed to a printer's device cert.
class BambuFieldEncryptor {
  BambuFieldEncryptor(this.publicKey) {
    _engine = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
  }

  /// The device-cert public key the printer will decrypt against.
  final RSAPublicKey publicKey;

  late final AsymmetricBlockCipher _engine;

  /// `EncryptField`: encrypts [value] under the device cert and returns the
  /// Base64 wire form (`url_enc` / `param_enc`). [value] must be the exact
  /// UTF-8 cleartext the firmware would otherwise read.
  String encryptField(String value) {
    final plaintext = Uint8List.fromList(utf8.encode(value));
    final out = BytesBuilder();
    for (var off = 0; off < plaintext.length; off += kFieldEncryptChunkSize) {
      final len = math.min(kFieldEncryptChunkSize, plaintext.length - off);
      final block = Uint8List(_engine.outputBlockSize);
      final n = _engine.processBlock(plaintext, off, len, block, 0);
      out.add(block.sublist(0, n));
    }
    return base64.encode(out.toBytes());
  }
}

/// Extracts the RSA public key from an X.509 certificate PEM (the printer's
/// device cert, `CN=<serial>`). Parses the DER by hand with pointycastle's
/// ASN.1 primitives — no `package:x509` dependency needed.
///
/// Layout: Certificate → tbsCertificate (SEQUENCE) → subjectPublicKeyInfo
/// (the SEQUENCE whose 2nd element is a BIT STRING) → that BIT STRING's
/// content is a DER `RSAPublicKey ::= SEQUENCE { modulus INTEGER,
/// publicExponent INTEGER }`.
RSAPublicKey rsaPublicKeyFromCertPem(String pem) {
  final der = _pemToDer(pem);
  final cert = ASN1Parser(Uint8List.fromList(der)).nextObject() as ASN1Sequence;
  final tbs = cert.elements![0] as ASN1Sequence;

  ASN1Sequence? spki;
  for (final e in tbs.elements!) {
    if (e is ASN1Sequence &&
        e.elements != null &&
        e.elements!.length >= 2 &&
        e.elements![1] is ASN1BitString) {
      spki = e;
      break;
    }
  }
  if (spki == null) {
    throw const FormatException('certificate has no subjectPublicKeyInfo');
  }

  final bitString = spki.elements![1] as ASN1BitString;
  // stringValues is the BIT STRING content with the unused-bits octet already
  // stripped — i.e. the DER-encoded RSAPublicKey.
  final rsaSeq =
      ASN1Parser(Uint8List.fromList(bitString.stringValues!)).nextObject()
          as ASN1Sequence;
  final modulus = (rsaSeq.elements![0] as ASN1Integer).integer!;
  final exponent = (rsaSeq.elements![1] as ASN1Integer).integer!;
  return RSAPublicKey(modulus, exponent);
}

Uint8List _pemToDer(String pem) {
  final body = pem
      .split(RegExp(r'\r?\n'))
      .where((line) => line.isNotEmpty && !line.startsWith('-----'))
      .join();
  return base64.decode(body);
}
