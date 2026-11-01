import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../offline/store.dart';

/// Local unlock of an installed POS (docs/capabilities.md): the PIN of the operator who signed in
/// on this device. It opens the app after it was closed or stayed in the background, online or
/// offline, without the password; it is local access, not a sign-in, and never renews the session
/// by itself. Kept only as a PBKDF2-HMAC-SHA256 hash in the encrypted store; [maxFailures] wrong
/// PINs in a row end the stored session (pending sales stay and sync after the next sign-in).
class OperatorPin {
  OperatorPin(this.store, {this.iterations = 60000});

  final OfflineStore store;
  final int iterations;

  static const maxFailures = 5;
  static const minLength = 4;
  static const maxLength = 8;

  /// Background time after which the app asks for the PIN again.
  static const idle = Duration(minutes: 5);

  static const _pin = 'pin.hash';
  static const _owner = 'pin.user';
  static const _failures = 'pin.failures';

  static bool valid(String pin) => RegExp('^[0-9]{$minLength,$maxLength}\$').hasMatch(pin);

  /// The PIN set by [userUuid] (a PIN of another operator does not count).
  bool isSetFor(String userUuid) => store.meta(_pin) != null && store.meta(_owner) == userUuid;

  void set(String userUuid, String pin) {
    if (!valid(pin)) throw ArgumentError('PIN must have $minLength to $maxLength digits.');
    final random = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
    final hash = pbkdf2(utf8.encode(pin), salt, iterations);
    store.setMeta(_pin, 'pbkdf2-sha256\$$iterations\$${base64Encode(salt)}\$${base64Encode(hash)}');
    store.setMeta(_owner, userUuid);
    store.setMeta(_failures, null);
  }

  /// Null when the PIN is right; otherwise the attempts left (0: the stored session must end).
  int? verify(String pin) {
    final parts = store.meta(_pin)?.split('\$') ?? const [];
    if (parts.length == 4 && parts[0] == 'pbkdf2-sha256') {
      final rounds = int.tryParse(parts[1]) ?? iterations;
      final hash = pbkdf2(utf8.encode(pin), base64Decode(parts[2]), rounds);
      if (_same(hash, base64Decode(parts[3]))) {
        store.setMeta(_failures, null);
        return null;
      }
    }
    final failures = (int.tryParse(store.meta(_failures) ?? '') ?? 0) + 1;
    store.setMeta(_failures, '$failures');
    return max(0, maxFailures - failures);
  }

  void clear() {
    for (final key in [_pin, _owner, _failures]) {
      store.setMeta(key, null);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// PBKDF2-HMAC-SHA256 with one 32-byte block (RFC 8018).
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var block = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final result = Uint8List.fromList(block);
  for (var i = 1; i < iterations; i++) {
    block = hmac.convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return result;
}
