import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:web/web.dart' as web;

/// Same-origin copy of the zxing-wasm reader that mobile_scanner would otherwise load from a CDN
/// (`web/vendor/zxing-wasm`, the version pinned by mobile_scanner). The script id is the one
/// mobile_scanner looks for, so it never adds its own CDN script.
const _zxingDir = 'vendor/zxing-wasm/';
const _zxingScriptId = 'mobile-scanner-zxing-wasm';

/// Camera scanning on the web: the browser's BarcodeDetector where it exists (Chrome/Edge on
/// Android, ChromeOS and macOS) and the bundled zxing-wasm reader elsewhere (Firefox, Safari,
/// desktop Chrome). Nothing is downloaded from a CDN at run time, so the POS keeps its same-origin
/// script policy. Without a camera API a keyboard-wedge reader is used.
Future<bool> cameraScanSupported() async {
  final media = web.window.navigator.getProperty<JSObject?>('mediaDevices'.toJS);
  return web.window.isSecureContext && media != null && media.has('getUserMedia') && globalContext.has('WebAssembly');
}

Future<void>? _prepared;

/// Picks the reader before the scanner starts; fails when the bundled reader cannot be loaded.
Future<void> prepareCameraScanner() => _prepared ??= _prepare().catchError((Object e) {
      _prepared = null;
      throw e;
    });

Future<void> _prepare() async {
  if (globalContext.has('BarcodeDetector')) {
    MobileScannerPlatform.instance.setWebBarcodeReader(WebBarcodeReader.barcodeDetector);
    return;
  }
  final base = web.document.baseURI;
  final dir = Uri.parse(base).resolve(_zxingDir).toString();
  if (web.document.querySelector('script#$_zxingScriptId') == null) {
    final loaded = Completer<void>();
    final script = web.HTMLScriptElement()
      ..id = _zxingScriptId
      ..src = '${dir}reader.js'
      ..onload = ((web.Event _) => loaded.complete()).toJS
      ..onerror = ((web.Event _) => loaded.completeError(StateError('zxing-wasm reader not loaded'))).toJS;
    web.document.head!.appendChild(script);
    try {
      await loaded.future;
    } catch (_) {
      script.remove();
      rethrow;
    }
  }
  // The WebAssembly binary also comes from the POS origin, not from the reader's default CDN.
  final zxing = globalContext.getProperty<JSObject>('ZXingWASM'.toJS);
  final overrides = JSObject()
    ..setProperty('locateFile'.toJS, ((JSString path, JSString prefix) => '$dir${path.toDart}'.toJS).toJS);
  zxing.callMethod<JSAny?>('setZXingModuleOverrides'.toJS, overrides);
  MobileScannerPlatform.instance.setWebBarcodeReader(WebBarcodeReader.zxingWasm);
}
