import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../fiscal/fiscal_device.dart';
import 'p256.dart';
import 'sqlite_store.dart';
import 'store.dart';

const _keyName = 'mnscloud_pos_device_key';
const _dbKeyName = 'mnscloud_pos_db_key';

/// Readable while the device is locked after its first unlock, so the background sync (iOS
/// BGTask, Android WorkManager) can open the store and sign its requests. Items written by older
/// releases with the default accessibility are moved on first read ([_SecureKeys]).
const _secureOptions = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
);

class _SecureKeys {
  const _SecureKeys();

  static const _legacy = FlutterSecureStorage();

  Future<String?> read(String key) async {
    final value = await _secureOptions.read(key: key);
    if (value != null || !(Platform.isIOS || Platform.isMacOS)) return value;
    final old = await _legacy.read(key: key);
    if (old != null) {
      await _legacy.delete(key: key);
      await _secureOptions.write(key: key, value: old);
    }
    return old;
  }

  Future<void> write(String key, String value) => _secureOptions.write(key: key, value: value);

  Future<void> delete(String key) async {
    await _secureOptions.delete(key: key);
    if (Platform.isIOS || Platform.isMacOS) await _legacy.delete(key: key);
  }
}

/// Installed app: encrypted SQLite store in the application support directory, and the device
/// private key and the store key in the OS secure storage (Keychain, Android Keystore, Windows
/// DPAPI, libsecret).
class DeviceHost implements FiscalSecrets {
  DeviceHost._(this.store, this._secure);

  /// A host over [store] with the secure storage of the platform (tests mock it).
  @visibleForTesting
  factory DeviceHost.over(OfflineStore store) => DeviceHost._(store, const _SecureKeys());

  final OfflineStore store;
  final _SecureKeys _secure;

  String get platform => Platform.operatingSystem;

  Future<P256Key?> loadKey() async {
    final value = await _secure.read(_keyName);
    return value == null ? null : P256Key.fromPrivateBase64(value);
  }

  Future<void> saveKey(P256Key key) => _secure.write(_keyName, key.privateBase64);

  Future<void> deleteKey() => _secure.delete(_keyName);

  @override
  Future<String?> readSecret(String name) => _secure.read('mnscloud_pos_$name');

  @override
  Future<void> writeSecret(String name, String? value) =>
      value == null ? _secure.delete('mnscloud_pos_$name') : _secure.write('mnscloud_pos_$name', value);
}

/// Opens the encrypted store. Throws when the bundled SQLite cannot encrypt: the app then sells
/// online only instead of keeping sales in clear.
Future<DeviceHost?> openDeviceHost() async {
  if (!SqliteOfflineStore.encryptionAvailable) {
    throw StateError('The bundled SQLite has no encryption (SQLite3MultipleCiphers).');
  }
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  final path = p.join(dir.path, 'mnscloud-pos.db');
  const secure = _SecureKeys();
  var key = await secure.read(_dbKeyName);
  if (key == null) {
    final file = File(path);
    if (file.existsSync() && !SqliteOfflineStore.isPlain(path)) {
      // Encrypted with a key the secure storage no longer has (restored backup, wiped keychain):
      // kept aside, never deleted, and the device must be provisioned again.
      file.renameSync('$path.unreadable-${DateTime.now().millisecondsSinceEpoch}');
    }
    final random = Random.secure();
    key = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await secure.write(_dbKeyName, key);
  }
  final store = SqliteOfflineStore.open(path, key: key);
  return DeviceHost._(store, secure);
}
