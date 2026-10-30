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
| NFC-e issue (online, by the API) | yes (Fiscal module) | yes, as soon as the sale synchronizes |
| NFC-e offline contingency (tpEmis 9) signed on the device | no (by design) | yes, only on terminals enabled by the manager (A1 key and CSC in the OS secure storage, own number range) |

The web build is an installable PWA shell (decision U1, 2026-10-30): its service worker caches
only the app shell of the release, so the app opens fast and, without a connection, says that sales
need the network. It never stores sales locally: a closed tab while a sale is in doubt is resolved by
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

## Offline NFC-e (contingency)

- The manager enables the terminal (`POST /pos/terminals/:uuid/fiscal-offline`) and creates its
  offline series. The device then receives its number range and, once and audited, the A1 key and
  the CSC, kept only in the OS secure storage; a disabled terminal wipes them at the next sync.
- After a device sale, if the server already has the sale the NFC-e is issued online by the API;
  otherwise the device signs it in contingency (`tpEmis = 9`, `dhCont`, `xJust`, offline QR Code
  v2) with the next number of its range and queues it after the sale. The server transmits it
  before the deadline. The XML is identical to the API engine and its signature is verified with
  an independent XMLDSig implementation.
