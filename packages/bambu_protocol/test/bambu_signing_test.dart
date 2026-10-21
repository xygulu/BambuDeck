// Pins the Bambu command-signing envelope (bambu_signing.dart) - wire shape
// per ClusterM/open-bamboo-networking §10.4, tested against a generated key
// so no real key material lives in the repo.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bambu_protocol/bambu_protocol.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// Generates a throwaway RSA-2048 key for round-trip tests.
(RSAPrivateKey, RSAPublicKey) generateKeyPair() {
  final secure = Random.secure();
  final seed = Uint8List.fromList(
      List.generate(32, (_) => secure.nextInt(256)));
  final generator = RSAKeyGenerator()
    ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
        FortunaRandom()..seed(KeyParameter(seed))));
  final pair = generator.generateKeyPair();
  return (pair.privateKey as RSAPrivateKey, pair.publicKey as RSAPublicKey);
}

void main() {
  final (privateKey, publicKey) = generateKeyPair();
  final signer = BambuCommandSigner(privateKey);

  test('wrapSigned emits the documented header envelope', () {
    final wire = signer
        .wrapSigned({'sequence_id': '20001', 'command': 'pause'});
    expect(wire.startsWith('{"header":{'), isTrue);

    final parsed = json.decode(wire) as Map<String, dynamic>;
    final header = parsed['header'] as Map<String, dynamic>;
    expect(header['cert_id'], kSigningCertId);
    expect(header['sign_alg'], 'RSA_SHA256');
    expect(header['sign_ver'], 'v1.0');
    expect((parsed['print'] as Map)['command'], 'pause');
  });

  test('payload_len counts the exact signed byte string', () {
    final printNode = {'sequence_id': '20002', 'command': 'stop'};
    final wire = signer.wrapSigned(printNode);
    final printText = json.encode(printNode);
    final header = (json.decode(wire)
        as Map<String, dynamic>)['header'] as Map<String, dynamic>;
    expect(header['payload_len'], '{"print":$printText}'.length);
    // The wire's print section is byte-identical to what was signed.
    expect(wire, endsWith(',"print":$printText}'));
  });

  test('signature verifies as standard RSA-SHA256', () {
    final printNode = {'sequence_id': '20003', 'command': 'resume'};
    final wire = signer.wrapSigned(printNode);
    final header = (json.decode(wire)
        as Map<String, dynamic>)['header'] as Map<String, dynamic>;
    final signature =
        base64.decode(header['sign_string'] as String);
    final printText = json.encode(printNode);
    final signed = utf8.encode('{"print":$printText}');
    expect(header['payload_len'], signed.length);
    // Both the derived and the original public key must verify.
    expect(signer.verify(signed, signature), isTrue,
        reason: 'verify with the key derived from the private key');
    expect(signer.verify(signed, signature, withKey: publicKey), isTrue,
        reason: 'verify with the generator-original public key');
    // One flipped bit must not.
    final tampered = Uint8List.fromList(signed)..[5] ^= 0x01;
    expect(signer.verify(tampered, signature), isFalse,
        reason: 'tampered message must not verify');
  });

  test('cert_id is serial-hex + RFC4514 issuer with no separator', () {
    expect(RegExp(r'^[0-9a-f]{32}CN=').hasMatch(kSigningCertId), isTrue);
  });

  test('signed project_file wire carries exactly ONE print envelope', () {
    // Regression: printProjectFile once shipped
    // {"print":{"print":{...}}} - the firmware never saw a command name and
    // dropped the frame silently (换盘 无响应 2026-10-21).
    final envelope = buildProjectFilePayload(
        sequenceId: '20006', url: 'ftp:///cache/x.3mf');
    final wire = signer.wrapSigned(envelope['print'] as Map<String, dynamic>);
    final parsed = json.decode(wire) as Map<String, dynamic>;
    final print = parsed['print'] as Map<String, dynamic>;
    expect(print['command'], 'project_file');
    expect(print.containsKey('print'), isFalse);
  });

  test('project_file payload carries AMS mapping when a slot is picked',
      () {
    final payload = buildProjectFilePayload(
        sequenceId: '20004',
        url: 'ftp:///cache/x.3mf',
        md5: 'abc',
        amsSlot: 2);
    final print = payload['print'] as Map<String, dynamic>;
    expect(print['use_ams'], isTrue);
    expect(print['ams_mapping'], [2]);
    expect(print['ams_mapping2'], [
      {'ams_id': 0, 'slot_id': 2}
    ]);

    final plain = buildProjectFilePayload(
        sequenceId: '20005', url: 'ftp:///cache/x.3mf')['print']
        as Map<String, dynamic>;
    expect(plain['use_ams'], isFalse);
    expect(plain.containsKey('ams_mapping'), isFalse);
    expect(plain.containsKey('ams_mapping2'), isFalse);
  });
}
