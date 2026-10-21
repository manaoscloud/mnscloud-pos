# MNSCloud POS

Public Flutter client for the MNSCloud point of sale (PDV / POS / TPV).

- **Web** — online only, served by `mnscloud-webapps` at `/pos/` with the same-origin API
  (`/api/v1`). No PWA, no service worker, nothing persisted in the browser.
- **Installed apps** — Android, iOS, Windows, macOS and Linux. Online today; offline sales within a
  server-issued authorization are delivered in a later phase.

The app talks only to `/api/v1/user/*` and `/api/v1/pos/*`. Terminals, price lists, stock, payments
and fiscal documents are configured and decided by the MNSCloud API; the tenant must hold the
`module.pos.*` entitlement. See [docs/capabilities.md](docs/capabilities.md).

## Development

```bash
flutter pub get
flutter analyze
flutter test
bash scripts/check-web-online-only.sh
flutter run -d linux --dart-define=POS_API_BASE_URL=https://api.example.test/api/v1
```

Releases: every push to `main` runs `Auto Release` (`scripts/release-pos.sh`), which publishes the
static web artifact `mnscloud-pos-web-vX.Y.Z.tar.gz` consumed by `mnscloud-webapps`.

## New version notice

On the web build an open POS detects a newer release without a refresh:
`lib/src/version/app_update_controller.dart` reads `build.json` (written by `mnscloud-webapps` next
to `index.html` of the active release) on start, every ~5 min while visible and when the page
becomes visible or online again, and compares it with `appBuildInfo.version`, stamped from
`pubspec.yaml` at release by `scripts/sync-app-build-info.sh`. A different version is accepted after
two reads 45 s apart and shown as a card (`Update now` / `Later`, 4 h per version, kept in memory
only). The card never appears during a sale (cart, payments or a sale awaiting confirmation): the
cart lives in memory and a reload would lose it. The POS session survives the reload (refresh
cookie). Installed apps do not run the detector.

Critical updates: a release that fixes a serious problem sets `minimumVersion` in
`web/update-policy.json` (usually to its own version, in the same PR). `mnscloud-webapps` copies it
into `build.json`; pages running below it get an "important update" notice without the postpone
action, still only between sales. Keep it `null` for regular releases.
