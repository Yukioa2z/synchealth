# Security

SyncHealth handles medical data. Treat `health.db`, Apple export files, raw
payloads, app queue files, receiver logs and backups as sensitive even when
they contain no account password.

## Supported code

Security fixes are made on the current `main` branch. There are no maintained
release branches yet.

## Deployment baseline

- Keep `synchealth-server` bound to `127.0.0.1` unless you understand the
  network exposure.
- Put the receiver behind HTTPS and use a random token of at least 32
  characters.
- Never put the token in source, an Xcode build setting, a URL query string or
  a repository. The iOS app stores it in Keychain.
- Keep `~/.synchealth` and backups out of cloud-sync or source-control systems
  you would not trust with a medical record.
- The token authenticates writes; this project does not provide multi-user
  authorization, revocation lists, rate limiting or an audit service.

## Reporting a vulnerability

Please use the repository's private GitHub Security Advisory flow rather than a
public issue. Do not attach real health exports, receiver tokens, queue files,
database files, endpoints or screenshots containing health data. A synthetic
payload and the smallest reproducible description are enough.
