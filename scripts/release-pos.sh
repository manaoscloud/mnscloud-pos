#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

find_runtime_kit() {
  local candidate
  for candidate in \
    "${MNSCLOUD_RUNTIME_KIT_DIR:-}" \
    "${ROOT_DIR}/../mnscloud-runtime-kit" \
    "/opt/mnscloud/runtime-kit" \
    "/opt/mnscloud/repos/mnscloud-runtime-kit"; do
    [[ -n "$candidate" && -r "${candidate}/lib/release.sh" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

cd "$ROOT_DIR"
RUNTIME_KIT_DIR="$(find_runtime_kit)" || {
  printf '[mnscloud-pos] ERROR: mnscloud-runtime-kit lib/release.sh not found\n' >&2
  exit 1
}

# shellcheck source=/opt/mnscloud/runtime-kit/lib/release.sh
source "${RUNTIME_KIT_DIR}/lib/release.sh"

# Static web release artifact consumed by mnscloud-webapps (APP_SOURCE=release). It is built with
# the default same-origin API base (/api/v1) and a portable root base href; the hosting runtime
# rewrites <base href> to its own path.
export MNSCLOUD_RUNTIME_KIT_DIR="$RUNTIME_KIT_DIR"
# Installable PWA shell (decision U1): MNSCloud app-shell service worker, never the API or sales.
pwa_generate='python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" generate --build-dir build/web --app pos'
pwa_validate='python3 "$MNSCLOUD_RUNTIME_KIT_DIR/scripts/flutter-pwa.py" validate --build-dir build/web --base-href /'
package_web_artifact='"$MNSCLOUD_RUNTIME_KIT_DIR/scripts/package-static-artifact.sh" --source-dir build/web --name "mnscloud-pos-web-v$(tr -d "[:space:]" < VERSION).tar.gz"'

mrtk_release_prepare \
  --product mnscloud-pos \
  --repository manaoscloud/mnscloud-pos \
  --minimum-version 1.0.0 \
  --sync-pubspec \
  --add-path lib/src/version/app_build_info.dart \
  --validate "grep -q '^version:' pubspec.yaml" \
  --validate "bash scripts/sync-app-build-info.sh" \
  --validate "flutter pub get" \
  --validate "flutter build web --release --base-href / --no-web-resources-cdn" \
  --validate "grep -qF '<base href=\"/\">' build/web/index.html" \
  --validate "$pwa_generate" \
  --validate "$pwa_validate" \
  --validate "bash scripts/check-web-no-offline-sales.sh" \
  --validate "$package_web_artifact" \
  --asset-glob "releases/mnscloud-pos-web-v*.tar.gz*" \
  "$@"
