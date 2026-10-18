# AGENTS.md

MNSCloud POS (PDV/TPV) is a public Flutter client for the MNSCloud point of sale: the web version
(online only, served by mnscloud-webapps at `/pos/`) and installed apps (Android, iOS, Windows,
macOS, Linux) that will also sell offline within a server-issued authorization.

## Public Client Boundary

- Do not commit secrets, credentials, customer data, production domains, private IPs, certificates,
  CSC tokens, gateway keys, tenant-specific policies or internal topology.
- The API is the source of truth for prices, discounts, stock, payments, fiscal documents and
  authorization. The client never decides alone that a sale is paid or fiscally valid.
- Money is exact decimal (`Money`), never `double`.
- Every sale carries a client-generated UUID and a SHA-256 hash of its canonical JSON. A lost answer
  is resolved by reading the sale back and resending the same payload, never a new UUID.
- The web build is online only: no web manifest, no service worker, no local storage of sales
  (`scripts/check-web-online-only.sh`).
- Pix is confirmed only by the gateway on the server; cards only with the terminal NSU. Store no card
  data beyond brand and last four digits.

## Development

- Run `flutter analyze`, `flutter test` and `bash scripts/check-web-online-only.sh`.
- Keep UI touch-first, keyboard/barcode-scanner friendly and accessible.
- Releases are cut by `.github/workflows/auto-release.yml` (`scripts/release-pos.sh`).
