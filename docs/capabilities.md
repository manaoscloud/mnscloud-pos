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
| Offline sales within a server authorization and later sync | no (by design) | later phase (P4) |
| NFC-e issue and offline contingency | later phase (P5/P6) | later phase (P5/P6) |

The web build never stores sales locally: a closed tab while a sale is in doubt is resolved by
reading the sale back from the API (`GET /pos/sales/{uuid}`).
