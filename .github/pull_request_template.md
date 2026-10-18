## Summary

## Public Client Boundary

- [ ] No secrets, credentials, customer data, production hosts, private topology or certificates.
- [ ] Price, stock, payment and fiscal decisions remain API-side.
- [ ] Money stays exact decimal; sales keep their client UUID and payload hash on retry.
- [ ] The web build stays online only (no manifest, service worker or local sale storage).

## Validation

- [ ] `flutter analyze`
- [ ] `flutter test`
- [ ] `bash scripts/check-web-online-only.sh`
