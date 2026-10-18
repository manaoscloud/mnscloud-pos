# Capabilities

| Capability | Web (online) | Installed apps |
| --- | --- | --- |
| Sign in with the MNSCloud user, choose environment and terminal | yes | yes |
| Open, supply, withdraw and close the cash session | yes | yes |
| Catalog search and barcode lookup with the terminal price | yes | yes |
| Cart with exact decimals, line discount within the terminal limit | yes | yes |
| Cash with change, card (NSU from the terminal), Pix via the tenant gateway | yes | yes |
| Idempotent submit (client UUID + payload hash), recovery of unknown outcomes | yes | yes |
| Sale cancel with reason (open session, no fiscal document in force) | yes | yes |
| Offline sales within a server authorization and later sync | no (by design) | yes: local-first store, signed sync, conflicts flagged on the server |
| Device provisioning (ECDSA P-256 key in the OS secure storage, one device per terminal) | no | yes |
| Background sync while the app is closed (WorkManager / BGTaskScheduler) | no | validate (foreground timer and app resume today) |
| NFC-e issue and offline contingency | later phase (P5/P6) | later phase (P5/P6) |

The web build never stores sales locally: a closed tab while a sale is in doubt is resolved by
reading the sale back from the API (`GET /pos/sales/{uuid}`).

## Installed apps (local-first)

- A terminal enabled for offline operation is provisioned once, online, from the app ("Enable on
  this device"); the device key never leaves the OS secure storage. The manager issues the offline
  grant (operators, limits, validity) in MNSCloud.
- Cash events and sales are written to the local SQLite store together with their sync operation
  in one transaction (WAL, synchronous FULL); a failed write shows an error and nothing as saved.
- The sync loop pushes the operations in order (`/pos/sync/push`, signed, idempotent by operation
  UUID) and follows the catalog (`/pos/sync/bootstrap`, `/pos/sync/changes`, checksum per page). It
  runs every 30 seconds, when the app resumes and on demand; losing only the LAN to the backend
  behaves like being offline.
- Pix needs the tenant gateway, so installed devices take cash and cards (NSU from the terminal).
- Native builds are compiled in CI for Linux, Windows, Android, macOS and iOS; real-device
  validation of each platform is still to be recorded.
