import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'p256.dart';
import 'sqlite_store.dart';
import 'store.dart';

const _keyName = 'mnscloud_pos_device_key';

/// Installed app: SQLite store in the application support directory and the device private key
/// in the OS secure storage (Keychain, Android Keystore, Windows DPAPI, libsecret).
class DeviceHost {
  DeviceHost._(this.store, this._secure);

  final OfflineStore store;
  final FlutterSecureStorage _secure;

  String get platform => Platform.operatingSystem;

  Future<P256Key?> loadKey() async {
    final value = await _secure.read(key: _keyName);
    return value == null ? null : P256Key.fromPrivateBase64(value);
  }

  Future<void> saveKey(P256Key key) => _secure.write(key: _keyName, value: key.privateBase64);

  Future<void> deleteKey() => _secure.delete(key: _keyName);
}

Future<DeviceHost?> openDeviceHost() async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final store = SqliteOfflineStore.open(p.join(dir.path, 'mnscloud-pos.db'));
  return DeviceHost._(store, const FlutterSecureStorage());
}
