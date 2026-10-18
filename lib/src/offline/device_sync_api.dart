import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../api/api_client.dart';
import 'p256.dart';
import 'store.dart';
import 'sync_engine.dart';

/// Signed `/pos/sync/*` transport: every request carries the device id, a monotonic counter
/// (persisted before sending), the time and an ECDSA P-256 signature of the exact request.
class DeviceSyncApi implements SyncTransport {
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
