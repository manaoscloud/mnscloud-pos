#!/usr/bin/env bash
# The web POS is an installable PWA shell (decision U1, 2026-10-30) but sells online only: no sale,
# cart or session is ever stored in the browser, and the service worker caches only the app shell
# of the release (never /api). Offline sales exist only in the installed apps. Fails when the
# source or a built bundle would keep sales in the browser.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { printf '[check-web-no-offline-sales] %s\n' "$1" >&2; exit 1; }

! grep -rqE 'serviceWorker|localStorage|indexedDB|sessionStorage|caches\.' lib/src/platform/web_session.dart ||
  fail 'the web session must keep sales, cart and session in memory only'
# Only the PWA bridge may talk to the browser install/update APIs; nothing else stores data.
! grep -rlE 'localStorage|indexedDB|sessionStorage|caches\.' lib --include='*.dart' | grep -v '^lib/src/platform/pwa_web.dart$' |
  grep -q . || fail 'browser storage is not allowed in the web POS (lib/)'

if [[ -d build/web ]]; then
  # The MNSCloud service worker never precaches or serves the API (runtime-kit flutter-pwa.py
  # validate checks the full PWA contract; this keeps the POS rule explicit).
  [[ -f build/web/sw.js ]] || fail 'build/web/sw.js missing: run flutter-pwa.py generate'
  ! grep -E '^const PRECACHE = ' build/web/sw.js | grep -q 'api/' || fail 'sw.js precaches the API'
fi
printf '[check-web-no-offline-sales] ok\n'
