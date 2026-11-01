import 'package:flutter/foundation.dart';

import 'app_build_info.dart';

/// `X-Mns-Client-Platform` of this build: `web`, or the OS of the installed app. Read from
/// [defaultTargetPlatform], never `dart:io`, so the web build stays free of it.
String clientPlatform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux || TargetPlatform.fuchsia => 'linux',
  };
}

/// Identity headers sent on every API call; the API answers 426 `CLIENT_VERSION_UNSUPPORTED` to an
/// installed app below the minimum version of its platform.
Map<String, String> clientIdentityHeaders() => {
      'X-Mns-Client': '${appBuildInfo.product}/${appBuildInfo.version}',
      'X-Mns-Client-Platform': clientPlatform(),
    };

/// Minimum versions per platform published by `GET /public/clients/pos/policy`.
class ClientVersionPolicy {
  const ClientVersionPolicy({this.latest, this.minimum = const {}});

  final String? latest;
  final Map<String, String> minimum;

  /// Parses the `data` of the policy answer; null when it is not a policy of [product].
  static ClientVersionPolicy? fromJson(Object? data, {String product = 'mnscloud-pos'}) {
    if (data is! Map || data['product'] != product) return null;
    final minimum = <String, String>{};
    final raw = data['minimum'];
    if (raw is Map) {
      raw.forEach((platform, value) {
        if (value != null && value.toString().trim().isNotEmpty) minimum['$platform'] = value.toString().trim();
      });
    }
    final latest = data['latest']?.toString().trim();
    return ClientVersionPolicy(latest: latest == null || latest.isEmpty ? null : latest, minimum: minimum);
  }
}
