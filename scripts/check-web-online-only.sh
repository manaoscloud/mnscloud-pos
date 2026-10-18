#!/usr/bin/env bash
# The web POS is online only (D2): no service worker, no web manifest, no install prompt and no
# local persistence of sales. Fails when the source or a built bundle would make it a PWA.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { printf '[check-web-online-only] %s\n' "$1" >&2; exit 1; }

[[ ! -e web/manifest.json ]] || fail 'web/manifest.json must not exist'
! grep -qiE 'rel="manifest"|serviceWorker|flutter_service_worker' web/index.html ||
  fail 'web/index.html must not reference a manifest or a service worker'
! grep -qE 'serviceWorker' web/flutter_bootstrap.js ||
  fail 'web/flutter_bootstrap.js must not register a service worker'
! grep -rqE 'serviceWorker|localStorage|indexedDB|sessionStorage' lib/src/platform/web_session.dart ||
  fail 'the web session must keep sales in memory only'

if [[ -d build/web ]]; then
  [[ ! -e build/web/manifest.json ]] || fail 'built bundle carries manifest.json'
  # Flutter still emits an unregistering stub; the release drops it (nothing registers it).
  rm -f build/web/flutter_service_worker.js
  ! grep -qE 'serviceWorkerVersion: *"' build/web/flutter_bootstrap.js ||
    fail 'flutter_bootstrap.js registers a service worker'
fi
printf '[check-web-online-only] ok\n'
