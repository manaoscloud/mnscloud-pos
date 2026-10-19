import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mobile_scanner/mobile_scanner.dart';

/// The web build scans only with the browser's own BarcodeDetector (Chrome/Edge on Android and
/// ChromeOS, Safari where enabled): no reader library is downloaded from a CDN at run time, so
/// the POS keeps its same-origin script policy. Elsewhere a keyboard-wedge reader is used.
Future<bool> cameraScanSupported() async => globalContext.has('BarcodeDetector');

/// Pins the web reader to the native BarcodeDetector (never the CDN-loaded ZXing fallbacks).
void prepareCameraScanner() =>
    MobileScannerPlatform.instance.setWebBarcodeReader(WebBarcodeReader.barcodeDetector);
