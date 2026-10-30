{{flutter_js}}
{{flutter_build_config}}

// No Flutter service worker: the release appends the MNSCloud app-shell worker (runtime-kit
// flutter-pwa.py). Sales are never cached or stored in the browser.
_flutter.loader.load();
