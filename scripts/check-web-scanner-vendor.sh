#!/usr/bin/env bash
# The web camera scanner falls back to zxing-wasm where the browser has no BarcodeDetector, served
# from web/vendor/zxing-wasm (same origin, never the CDN mobile_scanner would load). Fails when the
# vendored copy no longer matches the version mobile_scanner pins, or the binary its reader expects.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { printf '[check-web-scanner-vendor] %s\n' "$1" >&2; exit 1; }

dir=web/vendor/zxing-wasm
[[ -f $dir/reader.js && -f $dir/zxing_reader.wasm && -f $dir/LICENSE ]] || fail "$dir is incomplete"
[[ -f .dart_tool/package_config.json ]] || fail 'run flutter pub get first'
pkg=$(python3 -I -c '
import json, sys
for p in json.load(open(".dart_tool/package_config.json"))["packages"]:
    if p["name"] == "mobile_scanner":
        print(p["rootUri"].removeprefix("file://"))
')
[[ -n $pkg ]] || fail 'mobile_scanner is not a dependency'
pinned=$(sed -nE "s/^const String zxingWasmVersion = '([^']+)';/\1/p" "$pkg/lib/src/web/web_library_versions.dart")
vendored=$(grep -oE 'zxing-wasm@[0-9.]+' "$dir/reader.js" | head -1 | sed 's/.*@//')
[[ -n $pinned && $pinned == "$vendored" ]] ||
  fail "vendored zxing-wasm $vendored, mobile_scanner pins $pinned: copy dist/iife/reader/index.js and dist/reader/zxing_reader.wasm of zxing-wasm@$pinned"
expected=$(grep -oE 'ZXING_WASM_SHA256=`[0-9a-f]{64}' "$dir/reader.js" | sed 's/.*`//')
actual=$(sha256sum "$dir/zxing_reader.wasm" | cut -d' ' -f1)
[[ $expected == "$actual" ]] || fail 'zxing_reader.wasm does not match the SHA-256 the reader expects'
if [[ -d build/web ]]; then
  cmp -s "$dir/zxing_reader.wasm" build/web/vendor/zxing-wasm/zxing_reader.wasm || fail 'build/web lacks the vendored reader'
fi
printf '[check-web-scanner-vendor] ok (zxing-wasm %s)\n' "$pinned"
