import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mnscloud_pos/src/offline/p256.dart';

void main() {
  test('device key signs r||s that verifies only for the exact message', () {
    final key = P256Key.generate();
    final message = deviceSignatureMessage('post', '/pos/sync/push', '2026-10-18T10:00:00.000Z', '7', 'a' * 64);
    final signature = key.sign(message);
    expect(base64Decode(signature), hasLength(64));
    expect(key.verify(message, signature), isTrue);
    expect(key.verify('$message ', signature), isFalse);
    expect(P256Key.generate().verify(message, signature), isFalse);
  });

  test('key survives the secure-store round trip with the same SPKI and fingerprint', () {
    final key = P256Key.generate();
    final restored = P256Key.fromPrivateBase64(key.privateBase64);
    expect(restored.spkiBase64, key.spkiBase64);
    expect(restored.fingerprint, key.fingerprint);
    expect(key.spki, hasLength(91));
    expect(key.spki.sublist(0, 2), [0x30, 0x59]);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key.fingerprint), isTrue);
    final message = deviceProvisionMessage('2b0c9c3a-4f6c-4d64-9f15-1e27ad2f6a1b', '2026-10-18T10:00:00.000Z');
    expect(message.split('\n')[1], '2B0C9C3A4F6C4D649F151E27AD2F6A1B');
    expect(restored.verify(message, key.sign(message)), isTrue);
  });

  test('signed path drops the API prefix and keeps the query', () {
    expect(deviceSignedPath(Uri.parse('https://example.test/api/v1/pos/sync/changes?cursor=abc')),
        '/pos/sync/changes?cursor=abc');
    expect(deviceSignedPath(Uri.parse('https://example.test/api/v1/pos/sync/push')), '/pos/sync/push');
    expect(deviceSignedPath(Uri.parse('https://example.test/api/v1/user/me')), isNull);
  });
}
