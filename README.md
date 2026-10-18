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
