# MNSCloud POS Skill

Use this repository for the public Flutter point-of-sale client (web online + installed apps).

## Rules

- Treat this app as a public API client of `/api/v1/pos/*`.
- Do not place secrets, customer data, production domains, certificates or private policies in the
  repository.
- Keep price, discount, stock, payment confirmation and fiscal decisions in the MNSCloud API.
- Exact decimals, client UUIDs and canonical payload hashes for every sale; retries reuse them.
- The web build never becomes a PWA.

## Validation

```bash
flutter analyze
flutter test
bash scripts/check-web-online-only.sh
```
