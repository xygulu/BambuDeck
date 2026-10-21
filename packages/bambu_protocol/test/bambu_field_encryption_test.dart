// Field-encryption (§10.3) regression tests: device-cert public-key extraction
// and the blockwise RSA-PKCS#1 v1.5 `EncryptField` algorithm.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

// Throwaway `openssl req -x509 -newkey rsa:2048 -subj /CN=test-device-cert` —
// no real printer material. Exercise the X.509 DER parser on a real cert.
const _testCertPem =
    '-----BEGIN CERTIFICATE-----\n'
    'MIICsjCCAZoCCQD/qraHVSkrcjANBgkqhkiG9w0BAQsFADAbMRkwFwYDVQQDDBB0\n'
    'ZXN0LWRldmljZS1jZXJ0MB4XDTI2MTAyMTA1MTY0MVoXDTI3MTAyMTA1MTY0MVow\n'
    'GzEZMBcGA1UEAwwQdGVzdC1kZXZpY2UtY2VydDCCASIwDQYJKoZIhvcNAQEBBQAD\n'
    'ggEPADCCAQoCggEBALBQGwOPKrfH3fHVVBHaotFnC2tAKfFPQOZac004EZQA7V8S\n'
    'ieMkfIPdzIhAIDpCVwf9p7ZiM5sITa43LbOyTbl9MfK2n8F//c+ELh2jzekSBexd\n'
    'tCKsX3JScrZfhDz/7zKvWgGnkn1j/A8pi0uMT54g0wsvQai9mS0kjmSwzM0D7FNU\n'
    'ptm6Q59UqJALm6W/VtBLJISxRI1WBN5HXkaFzQHrJk7gayih04fjGmHNqOMMmX2Z\n'
    'ru06yHW6W6hfiNG3sTWQ/9ERBjPq/atLVcP5q5pr29SGl8ZCKBiMASBNzfnAs5tK\n'
    'KYeK3mDXBVJR6EzHzTNjNp7nkjdEdZHK93lv3U8CAwEAATANBgkqhkiG9w0BAQsF\n'
    'AAOCAQEAmFguc3Oq/xBRRfe27a681xrUyx/nFCTpc3K11Q74lmy8Wx4H+pXGJ0pR\n'
    'WTxrzkZ2y87ofuuJ8iU1dlPlVQ5jscwG0I87EplakBnG8kHSu7OmBv2gtHZnjWT1\n'
    'pCBfJQxpOXB4AM7pzdYRbwX30WNmbmF2IkbRJBcB5vYGDsMnvn6nRwgm4z6C4Y58\n'
    '2KIdyi94xQS/7BMFHznG+oqxxO0QM1HvMQ87Gsnyc9gIOb27w3c5UiOUO5s3Z/Qq\n'
    'yDlq3E/Pq0Vjahxo+SL16A6zHjzTntQnGqpMSZG7QEw9VrGpQZ3jKDPRCktFwUGw\n'
    'dQ/vIHe6GyZlhPFw29DA0Dt+M8jp2w==\n'
    '-----END CERTIFICATE-----\n';

// Lowercase-hex modulus of the throwaway cert, from `openssl rsa -modulus`.
const _testModulusHex = 'b0501b038f2ab7c7ddf1d55411daa2d1670b6b4029f14f40'
    'e65a734d38119400ed5f1289e3247c83ddcc8840203a425707fda7b662339b084dae372'
    'db3b24db97d31f2b69fc17ffdcf842e1da3cde91205ec5db422ac5f725272b65f843cff'
    'ef32af5a01a7927d63fc0f298b4b8c4f9e20d30b2f41a8bd992d248e64b0cccd03ec535'
    '4a6d9ba439f54a8900b9ba5bf56d04b2484b1448d5604de475e4685cd01eb264ee06b28'
    'a1d387e31a61cda8e30c997d99aeed3ac875ba5ba85f88d1b7b13590ffd1110633eafda'
    'b4b55c3f9ab9a6bdbd48697c64228188c01204dcdf9c0b39b4a29878ade60d7055251e8'
    '4cc7cd3363369ee79237447591caf7796fdd4f';

void main() {
  test('rsaPublicKeyFromCertPem extracts modulus + exponent', () {
    final pub = rsaPublicKeyFromCertPem(_testCertPem);
    expect(pub.exponent, BigInt.from(65537));
    expect(pub.modulus!.toRadixString(16), _testModulusHex);
  });

  test('encryptField is PKCS#1 v1.5 blockwise and round-trips', () {
    final (priv, pub) = _generateKeyPair();
    final enc = BambuFieldEncryptor(pub);

    // Short field (swap URL) → 1 block = 256 B → 344 Base64 chars.
    final short = 'ftp:///cache/bambudeck_plate_swap.3mf';
    final shortEnc = enc.encryptField(short);
    expect(shortEnc.length, 344);
    expect(_decrypt(priv, shortEnc), short);

    // 246 bytes spills into a 2nd block → 512 B → 684 Base64 chars.
    final long = 'x' * 246;
    final longEnc = enc.encryptField(long);
    expect(longEnc.length, 684);
    expect(_decrypt(priv, longEnc), long);
  });

  test('encryptField chunk boundary is 245 bytes', () {
    final (_, pub) = _generateKeyPair();
    final enc = BambuFieldEncryptor(pub);
    // Exactly at the ceiling: still one block.
    expect(enc.encryptField('a' * 245).length, 344);
    // One over: two blocks.
    expect(enc.encryptField('a' * 246).length, 684);
  });
}

String _decrypt(RSAPrivateKey priv, String base64Cipher) {
  final engine = PKCS1Encoding(RSAEngine())
    ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv));
  final cipher = base64.decode(base64Cipher);
  final out = BytesBuilder();
  for (var off = 0; off < cipher.length; off += 256) {
    final block = Uint8List(engine.outputBlockSize);
    final n = engine.processBlock(cipher, off, 256, block, 0);
    out.add(block.sublist(0, n));
  }
  return utf8.decode(out.toBytes());
}

(RSAPrivateKey, RSAPublicKey) _generateKeyPair() {
  final secure = Random.secure();
  final seed =
      Uint8List.fromList(List.generate(32, (_) => secure.nextInt(256)));
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
        FortunaRandom()..seed(KeyParameter(seed))));
  final pair = keyGen.generateKeyPair();
  return (pair.privateKey as RSAPrivateKey, pair.publicKey as RSAPublicKey);
}
