import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../api/api_client.dart';
import '../fiscal/fiscal_device.dart';
import 'p256.dart';
import 'store.dart';
import 'sync_engine.dart';

/// Signed `/pos/sync/*` transport: every request carries the device id, a monotonic counter
/// (persisted before sending), the time and an ECDSA P-256 signature of the exact request. It is
/// sent in the device's own scope ([deviceScope]), whatever tenant or shop the screen shows.
class DeviceSyncApi implements SyncTransport, FiscalTransport {
  DeviceSyncApi(this.client, this.store, this.key, this.deviceUuid, {this.appVersion});

  final ApiClient client;
  final OfflineStore store;
  final P256Key key;
  final String deviceUuid;
  final String? appVersion;

  Map<String, String> _sign(String method, Uri uri, String body) {
    final counter = '${store.nextCounter()}';
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final path = deviceSignedPath(uri) ?? uri.path;
    final message = deviceSignatureMessage(method, path, timestamp, counter, sha256.convert(utf8.encode(body)).toString());
    return {
      'X-Device-Id': deviceUuid,
      'X-Device-Counter': counter,
      'X-Device-Timestamp': timestamp,
      'X-Device-Signature': key.sign(message),
      'X-App-Version': ?appVersion,
      ...deviceScope(store),
    };
  }

  Future<Map<String, dynamic>> _call(String method, String path, {Map<String, String>? query, Object? body}) async {
    final data = await client.signed(method, path,
        query: query, body: body, headers: (uri, text) => _sign(method, uri, text));
    return (data as Map).cast<String, dynamic>();
  }

  @override
  Future<Map<String, dynamic>> bootstrap(String? cursor) =>
      _call('GET', 'pos/sync/bootstrap', query: cursor == null ? null : {'cursor': cursor});

  @override
  Future<Map<String, dynamic>> changes(String cursor) => _call('GET', 'pos/sync/changes', query: {'cursor': cursor});

  @override
  Future<Map<String, dynamic>> push(List<Map<String, dynamic>> entries) =>
      _call('POST', 'pos/sync/push', body: {'operations': entries});

  /// Offline NFC-e configuration; `credentials` releases the A1 key and the CSC (audited).
  @override
  Future<Map<String, dynamic>> fiscalConfig({bool credentials = false}) =>
      _call('GET', 'pos/sync/fiscal', query: credentials ? {'credentials': '1'} : null);

  @override
  Future<Map<String, dynamic>> allocateRange(String environment) =>
      _call('POST', 'pos/sync/fiscal/ranges', body: {'environment': environment});
}

/// Tenant and customer shop of the provisioned device: the tenant stored when the device was
/// provisioned or attached, and the terminal's shop from the device row (null: the internal
/// operation, sent without an account). Rows of servers older than the account field keep the
/// session's headers.
Map<String, String> deviceScope(OfflineStore store) {
  final environment = store.meta('device_environment');
  final raw = store.meta('device');
  final row = raw == null ? null : jsonDecode(raw);
  return {
    'X-Environment-UUID': ?environment,
    if (row is Map && row.containsKey('CommerceAccountUUID'))
      'X-Commerce-Account-UUID': row['CommerceAccountUUID']?.toString() ?? '',
  };
}

/// Registers this installation for a terminal: a new key pair, the public key and a proof of
/// possession. Returns the API device row.
Future<Map<String, dynamic>> provisionDevice(
  ApiClient client, {
  required P256Key key,
  required String terminalUuid,
  required String name,
  required String platform,
  String? appVersion,
}) async {
  final timestamp = DateTime.now().toUtc().toIso8601String();
  final data = await client.post('pos/devices', {
    'terminalUUID': terminalUuid,
    'name': name,
    'platform': platform,
    'publicKey': key.spkiBase64,
    'timestamp': timestamp,
    'proof': key.sign(deviceProvisionMessage(terminalUuid, timestamp)),
    'appVersion': appVersion,
  });
  return (data as Map).cast<String, dynamic>();
}
