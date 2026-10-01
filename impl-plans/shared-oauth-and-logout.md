# Shared Google authentication and logout

## User decision

The user did not request a separate authentication project or OAuth client for
 each gateway. Configure one shared client through Service gateway and let all
 gateways use it. Preserve explicit product overrides and external JSON credentials.

Current objective: configure the auth client through Service gateway; test auth
for every gateway and role; test the existing JSON credential flows; implement
`auth logout`; share processing as far as practical.

General Google Auth Platform client creation currently requires Console
registration. Service gateway imports and configures the registered client
locally. Do not claim local import creates a client at Google.

## Required behavior

- Client precedence: explicit environment input, intentional product client,
  shared Service client.
- Callback settings belong to the selected client. Product overrides must not
  inherit another client's registered callback.
- Keep role/product token stores and scopes separate.
- Native logout removes local credentials without remote grant revocation.
- Preserve external inline JSON and environment-selected files on logout.
- Clear isolated gcloud provider selection and ADC after successful local logout.
- Preserve OAuth client setup on logout so another login can proceed.
- Preserve existing external credential naming, precedence and normal API access.

## Current evidence, 2026-10-01

- Shared library commits 7b805d5 and 258c3b7: Service client/callback discovery,
  common sync/async logout ownership policy, provider cleanup after native logout.
  `swift test`: 31 tests pass. `swiftlint lint --quiet`: pass.
- Service commit 1953895: auth adapter local logout, all operational roles reuse
  the same adapter. `swift test`: 120 tests pass. SwiftLint exits 0 with warnings.
- Calendar commit 3ca3c59: local logout under existing token lock, default
  credential selection, external JSON/path preservation.
  `swift test`: 137 tests pass. SwiftLint exits 0 with existing warnings.
- OAuth setup skill corrected to a shared Service default in mise-darwin
  b136f87 and installed user-scope copy; validator passes.

These unit tests do not prove browser grants or live API access for every role.

## Remaining work

1. Add logout integration and ownership tests to Gmail, Docs/Sheets/Drive,
   Analytics, Marketing and OCR; pin the shared library and Service SDK where used.
2. Test auth login/status/logout/relogin for every executable role and Marketing
   product selector. Test inline JSON and file credential resolution/API access.
3. Back up the unnecessary per-product defaults created during earlier work and
   remove them from active configuration so the shared Service default is selected.
   Preserve deliberate user overrides and global environment inputs.
4. Enable all requested APIs in the shared Service project through Service gateway.
5. Complete actual native Google login and real API checks for every role, using
   the authorized browser grants. Preserve caller credentials during verification.
6. Correct historical project records to distinguish actual extra resources from
   the requested shared configuration. Do not create additional separate projects.
7. Commit/push remaining changes, bump patch versions and release modified gateways;
   update Homebrew metadata and mise-darwin installations. Service 0.1.5 is already
   published, so its next patch must be 0.1.6. Other prepared versions are unpublished.
