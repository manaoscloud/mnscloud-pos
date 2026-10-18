import 'p256.dart';
import 'store.dart';

/// Web build: online only, nothing is stored on the device.
class DeviceHost {
  DeviceHost._();
  OfflineStore get store => throw UnsupportedError('No local store on the web.');
  String get platform => 'web';
  Future<P256Key?> loadKey() async => null;
  Future<void> saveKey(P256Key key) async {}
  Future<void> deleteKey() async {}
}

Future<DeviceHost?> openDeviceHost() async => null;
