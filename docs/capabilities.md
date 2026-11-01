# Capabilities

| Capability | Web (online) | Installed apps |
| --- | --- | --- |
| Sign in with the MNSCloud user, choose environment and terminal | yes | yes |
| Open, supply, withdraw and close the cash session | yes | yes |
| Catalog search and barcode lookup with the terminal price | yes | yes |
| Barcode with the camera | yes: the browser's BarcodeDetector, or the bundled zxing-wasm reader (Firefox, Safari, desktop Chrome), served by the POS itself | Android, iOS and macOS; Windows and Linux use a USB/Bluetooth reader |
| Cart with exact decimals, line discount within the terminal limit | yes | yes |
| Cash with change, card (NSU from the terminal), Pix via the tenant gateway | yes | yes |
| Idempotent submit (client UUID + payload hash), recovery of unknown outcomes | yes | yes |
| Sale cancel with reason (open session, no fiscal document in force) | yes | yes |
| Offline sales within a server authorization and later sync | no (by design) | yes: local-first store, signed sync, conflicts flagged on the server |
| Device provisioning (ECDSA P-256 key in the OS secure storage, one device per terminal) | no | yes |
| Background sync while the app is closed (Android WorkManager, iOS BGTask) | no | yes on Android and iOS (about every 15 minutes, with network, decided by the OS); desktop syncs while open |
| Local data encrypted at rest (SQLite3MultipleCiphers, key in the OS secure storage) | nothing stored | yes |
| Reopen the app without the password: operator PIN, online or offline | no (refresh cookie, online) | yes: the POS session stays in the encrypted store; the PIN opens it |
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
- The store is encrypted with SQLite3MultipleCiphers (`PRAGMA key`, bundled by `package:sqlite3`
  through `hooks.user_defines` in `pubspec.yaml`) and a random key kept in the OS secure storage. A
  clear store of an older release is encrypted in place on the first open (the clear copy kept
  meanwhile and clear migration backups are removed). Without encryption in the bundled SQLite the
  app does not open the store and sells online only. A store whose key is gone is set aside
  (`*.unreadable-<time>`), never deleted, and the device is provisioned again.
- **Session and operator PIN.** Installed apps keep the POS session (rotating refresh token,
  operator, tenant) in the encrypted store, and the operator creates a PIN (4 to 8 digits,
  PBKDF2-HMAC-SHA256, only on this device) after signing in. Reopening the app, coming back after 5
  minutes in the background or the lock button ask for the PIN: it is local access, never a sign-in.
  Online, the session is renewed; offline, the provisioned register opens with its local cash
  session and sells within the grant, and the session is renewed (and everything synced) as soon as
  the API answers. Five wrong PINs end the stored session and the PIN; pending sales, the device key
  and the grant stay. A sign-out or a refused renewal does the same.
- **Grant.** Offline sales check the grant validity, limits and, since this release, its operators.
  The API sends the device and its active grant on every catalog page, so a grant revoked in
  MNSCloud reaches the device on its next sync and offline sales stop; a device blocked by the
  server (`DEVICE_REVOKED`, `DEVICE_SUSPENDED`) drops its grant at once.
- The sync loop pushes the operations in order (`/pos/sync/push`, signed, idempotent by operation
  UUID) and follows the catalog (`/pos/sync/bootstrap`, `/pos/sync/changes`, checksum per page). It
  runs every 30 seconds, when the app resumes and on demand; losing only the LAN to the backend
  behaves like being offline.
- **Background sync** (`lib/src/offline/background_sync_io.dart`): Android WorkManager and iOS
  BGTask (`cloud.manaos.mnscloud.pos.sync`, `UIBackgroundModes` `fetch`) run a periodic task that,
  when there are pending operations and the app is not in front, renews the session from the stored
  refresh token and pushes them. The app and the task never sync at the same time: both take one
  lease in the store for the whole sync, because device requests carry a monotonic counter and a
  refresh token is valid once. The OS decides when the task runs (at least 15 minutes apart, only
  with network); desktop apps sync while open.
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
