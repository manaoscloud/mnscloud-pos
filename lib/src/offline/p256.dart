import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// ECDSA P-256 device key. The API verifies IEEE P1363 signatures (r || s, 64 bytes) with the
/// DER SPKI public key, so this class produces exactly those encodings. Signing is deterministic
/// (RFC 6979), so no random nonce can leak the key.
class P256Key {
  P256Key._(this._private, this._public);

  static final ECDomainParameters _curve = ECCurve_secp256r1();

  final ECPrivateKey _private;
  final ECPublicKey _public;

  static P256Key generate([Random? random]) {
    final source = random ?? Random.secure();
    final seed = Uint8List.fromList(List<int>.generate(32, (_) => source.nextInt(256)));
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(_curve),
        FortunaRandom()..seed(KeyParameter(seed)),
      ));
    final pair = generator.generateKeyPair();
    return P256Key._(pair.privateKey, pair.publicKey);
  }

  /// Restores a key from its private scalar (32 bytes, base64), as kept in the OS secure store.
  static P256Key fromPrivateBase64(String value) {
    final d = _decodeBigInt(base64Decode(value));
    final q = _curve.G * d;
    return P256Key._(ECPrivateKey(d, _curve), ECPublicKey(q, _curve));
  }

  /// Private scalar (32 bytes, base64): store it only in the OS secure storage.
  String get privateBase64 => base64Encode(_encodeBigInt(_private.d!, 32));

  /// DER SubjectPublicKeyInfo (id-ecPublicKey, prime256v1, uncompressed point), base64.
  String get spkiBase64 => base64Encode(spki);

  Uint8List get spki {
    final point = _public.Q!.getEncoded(false); // 0x04 || X || Y (65 bytes)
    const header = <int>[
      0x30, 0x59, // SEQUENCE (89)
      0x30, 0x13, // SEQUENCE (19)
      0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, // 1.2.840.10045.2.1 ecPublicKey
      0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // 1.2.840.10045.3.1.7 P-256
      0x03, 0x42, 0x00, // BIT STRING (66), no unused bits
    ];
    return Uint8List.fromList([...header, ...point]);
  }

  /// SHA-256 (hex) of the SPKI bytes: the fingerprint the API stores.
  String get fingerprint => sha256.convert(spki).toString();

  /// Signature of [message] (UTF-8) as base64 r || s.
  String sign(String message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(_private));
    final signature = signer.generateSignature(Uint8List.fromList(utf8.encode(message))) as ECSignature;
    return base64Encode([..._encodeBigInt(signature.r, 32), ..._encodeBigInt(signature.s, 32)]);
  }

  /// Verifies a base64 r || s signature (used by the tests and by self-checks).
  bool verify(String message, String signatureBase64) {
    final bytes = base64Decode(signatureBase64);
    if (bytes.length != 64) return false;
    final signature = ECSignature(_decodeBigInt(bytes.sublist(0, 32)), _decodeBigInt(bytes.sublist(32)));
    final verifier = ECDSASigner(SHA256Digest())..init(false, PublicKeyParameter<ECPublicKey>(_public));
    return verifier.verifySignature(Uint8List.fromList(utf8.encode(message)), signature);
  }

  static Uint8List _encodeBigInt(BigInt value, int length) {
    final bytes = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return bytes;
  }

  static BigInt _decodeBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }
}

/// Canonical message of a signed device request; identical to the API helper
/// (helpers/deviceSignature.ts).
String deviceSignatureMessage(String method, String path, String timestamp, String counter, String bodySha256) =>
    ['MNSCLOUD-DEVICE-V1', method.toUpperCase(), path, timestamp, counter, bodySha256].join('\n');

String deviceProvisionMessage(String terminalUuid, String timestamp) =>
    ['MNSCLOUD-DEVICE-PROVISION-V1', terminalUuid.replaceAll('-', '').toUpperCase(), timestamp].join('\n');

/// Route path from `/pos/` with the query string (independent of the /api/v1 prefix).
String? deviceSignedPath(Uri uri) {
  final index = uri.path.indexOf('/pos/');
  if (index < 0) return null;
  return '${uri.path.substring(index)}${uri.hasQuery ? '?${uri.query}' : ''}';
}
