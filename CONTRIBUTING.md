# Contributing

Thanks for contributing to MNSCloud POS.

Contributions must preserve the public client boundary:

- Use Pull Requests.
- Keep examples generic and public-safe.
- Do not add secrets, customer data, production URLs, internal topology, certificates or private
  business rules.
- Keep pricing, discount limits, stock, payment confirmation, fiscal rules and authorization
  API-side.

Before opening a PR:

```bash
flutter analyze
flutter test
bash scripts/check-web-online-only.sh
```
