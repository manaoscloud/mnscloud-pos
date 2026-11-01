// Installed Android and iOS apps schedule the background sync; the web and desktop have none (the
// desktop app syncs while it is open, every 30 seconds and on resume).
export 'background_sync_stub.dart' if (dart.library.ffi) 'background_sync_io.dart';
