// Installed apps open the local store and the OS secure storage; the web has neither.
export 'device_host_stub.dart' if (dart.library.ffi) 'device_host_io.dart';
