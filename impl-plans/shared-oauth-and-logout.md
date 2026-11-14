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

## Updated evidence

All nine products now share the common logout ownership policy. Every executable
role supports local logout. Marketing product/role combinations without an
implemented OAuth profile reject explicitly. Shared callback imports containing
an empty object preserve native receiver defaults (shared commit 2833101).

Full suites pass: shared 35, Service 120, Calendar 137, Gmail 157 XCTest plus
178 Swift Testing, Docs/Sheets/Drive 180, Analytics 304, Marketing 126, OCR 37.
SwiftLint ran in all modified packages and exited 0 (existing warnings remain).

CLI fixture verification passed 168 checks over all 28 executable composition
roots: gcloud login, status, refresh, native local logout, login again, revoke.
The fake gcloud process exercises CLI plumbing; it does not prove Google consent.

Service gateway enabled and verified all 17 required APIs in shared project
`tacogips-service-auth-261001`. Eight extra product default client files created
by earlier work were privately backed up and retired. Global environment sources
were preserved. See `design-docs/shared-auth-verification-2026-10-01.json`.

## Live verification completed

Real shared-client browser login, native/file/inline JSON API access, external-file
logout preservation, local logout with missing-token status, and native login
again pass for 16 roles: Calendar reader/writer; Gmail reader/draft/sender/threads/
message-box; Docs, Sheets and Drive reader/writer; Analytics reader/writer/admin.
Nine temporary verification resources were moved to Trash. Global credential
environment settings remain unchanged. Marketing Google Ads reader/writer/admin/
deleter native login, external JSON status, logout and login again also pass. Ads
API requests need a developer token absent from the resolved Marketing kinko
environment. The existing Bitwarden passkey allows Google identity verification.

## Current live audit

Every one of the 28 executable roots completed native Google login, external
JSON file and inline JSON readiness checks, native local logout with missing
credentials, and native login again. Marketing additionally covers all ten
supported product/role profiles, including the compatibility binary. Live read
API requests pass for Calendar, Gmail, Docs/Sheets/Drive, Analytics, Service
reader, OCR and Marketing Search Console/AdSense/AdMob reader/Analytics Data.

Google Ads API verification needs a developer token absent from the resolved
Marketing kinko environment. AdMob writer currently exposes preview only. These
are explicit API limits; native OAuth and external credential handling pass.
No destructive Cloud, billing or ad mutations were used for auth verification.
Configured Web/public HTTPS callbacks have fixture coverage; no deployed HTTPS
callback or live registered Web-client grant is claimed.

Historical records clearly mark extra per-product projects as the earlier
implementation mistake. The shared Service configuration is authoritative.

## Remaining delivery work

Publish the rebuilt patch releases and signed Calendar Casks, update Homebrew
metadata, and update/verify the mise-darwin installations. Service is 0.1.6;
Calendar 0.1.9; Gmail 0.1.17; Docs 0.3.6; Analytics 0.1.5; Marketing and OCR 0.1.4.
