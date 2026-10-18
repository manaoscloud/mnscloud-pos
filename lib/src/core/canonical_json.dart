import 'dart:convert';

import 'package:crypto/crypto.dart';

/// JSON with sorted keys, so the same sale always yields the same text and hash.
String canonicalJson(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return jsonEncode(sort(value));
}

/// SHA-256 (hex) of the canonical JSON; the server stores it to tell an identical resend from a
/// conflicting reuse of the same sale UUID.
String payloadHash(Object? value) => sha256.convert(utf8.encode(canonicalJson(value))).toString();
