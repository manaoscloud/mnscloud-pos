# Security Policy

Report security issues privately to the MNSCloud maintainers.

Do not open public issues for vulnerabilities involving authentication, tenant isolation, sale or
payment tampering, duplicated sales, fiscal document integrity, cash-session manipulation or
credential leakage.

This repository must not include:

- Tokens, passwords, private keys, certificates, CSC tokens, signing secrets or API credentials.
- Customer data or production tenant examples.
- Private API hosts, internal network addresses or payment provider account details.
- Client-side logic that would bypass the MNSCloud API decisions.

The web client keeps the session and the cart in memory only. Installed apps may store only the
session and offline data issued by the API, encrypted at rest; sensitive decisions stay server-side.
