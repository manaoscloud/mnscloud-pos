import 'dart:io';

/// Camera barcode scanning on installed apps: the native scanners of Android, iOS and macOS.
/// Windows and Linux counters use a keyboard-wedge (USB/Bluetooth) reader.
Future<bool> cameraScanSupported() async => Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

/// Nothing to configure outside the web.
void prepareCameraScanner() {}
