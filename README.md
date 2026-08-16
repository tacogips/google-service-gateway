# google-service-gateway

A SwiftPM library and five capability-specific command-line gateways for
Google Service Usage REST v1, Cloud Billing API v1, API Keys API v2, and Google
OAuth 2.0.

## Development

```bash
mise install
mise run build
mise run test
swift run google-service-gateway-reader --help
swift run google-service-gateway-writer --help
swift run google-service-gateway-admin --help
swift run google-service-gateway-deleter --help
swift run google-service-gateway-auth --help
```

The package uses Swift Package Manager with:

- Library target: `GoogleServiceGatewayCore`
- Reader executable: `google-service-gateway-reader` (list, get, operation get)
- Writer executable: `google-service-gateway-writer` (project creation, service
  mutations, and non-deleting API-key mutations)
- Admin executable: `google-service-gateway-admin` (signed, expiring, single-use
  Cloud Billing link/unlink plans)
- Deleter executable: `google-service-gateway-deleter` (project and API-key
  delete/undelete operations)
- Auth executable: `google-service-gateway-auth` (client import, PKCE login,
  refresh, revoke, scopes, and Google Auth Platform setup assistance)

The reader never sends mutations. The writer, admin, and deleter only read
provider state needed to validate or poll their own mutations. Every gateway emits stable JSON on success
and error; help and version are the only plain-text output.

## Usage

Set an ephemeral token in the process environment. The token is never persisted
or printed. Project selection is `--project`, then `GOOGLE_SERVICE_GATEWAY_PROJECT`,
then `GOOGLE_CLOUD_PROJECT`.

```bash
GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  swift run google-service-gateway-reader services list --project my-project --state enabled --all-pages

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  swift run google-service-gateway-writer services disable --project my-project --service gmail --check-usage
```

`gcloud` is optional. A service-account credential JSON can be supplied through
a named environment variable. The gateway signs and exchanges a short-lived
OAuth assertion without printing the credential or private key:

```bash
google-service-gateway-reader iam permissions test \
  --project my-project \
  --permission serviceusage.services.enable \
  --permission apikeys.keys.create \
  --service-account-env GOOGLE_APPLICATION_CREDENTIALS_JSON
```

The reader, writer, admin, and deleter accept `--service-account-env NAME`.
OpenSSL must be available for local RSA signing. The IAM permission test reports
separate `grantedPermissions` and `missingPermissions` arrays.

Aliases are `calendar`, `drive`, `gmail`, `sheets`, and `docs`; complete
`*.googleapis.com` service names and project numbers are also accepted. Use
`--access-token-env NAME` to select a different environment variable name.

The reader supports `services list`, `services get --service SERVICE`, and
`operations get --operation operations/NAME`. List defaults to one page of 50
services; `--state all` omits the provider filter, and `--all-pages` cannot be
combined with `--page-token`.

The writer supports `services enable`, `services disable`, and `services
batch-enable`. Mutations wait for their long-running operation by default with
a one-second interval and 120-second timeout. `--no-wait` conflicts with
`--poll-interval` and `--timeout`. Disable preserves dependents by default and
skips recent-usage checks unless `--disable-dependents` or `--check-usage` is
explicitly selected.

## Project bootstrap

The writer can create a GCP project with Cloud Resource Manager v3, enable up
to 20 APIs, and return the exact
Google Auth Platform Console handoffs needed to finish user OAuth setup:

```bash
GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-writer projects create \
  --project-id my-google-gateway-123 \
  --display-name "My Google Gateway" \
  --parent organizations/123456789 \
  --label environment=production \
  --service calendar \
  --service gmail \
  --scope calendar.readonly \
  --scope gmail.send
```

`--parent`, labels, services, and OAuth scopes are optional. Project creation is
asynchronous and is polled before service setup. `--no-wait` is therefore
rejected when services are requested. The caller needs
`resourcemanager.projects.create` on the selected parent.
Service accounts must specify `--parent organizations/NUMBER` or
`--parent folders/NUMBER`; Google rejects parentless project creation by a
service account.

Billing discovery belongs to the reader. Billing association belongs only to
the admin executable and uses a signed, credential-bound plan followed by an
exactly confirmed apply. Store the plan JSON output in a regular file; apply
also requires an absolute owner-controlled state directory for replay records:

```bash
google-service-gateway-reader billing accounts list
google-service-gateway-reader billing projects get --project my-google-gateway-123

google-service-gateway-admin billing projects link plan \
  --project my-google-gateway-123 \
  --billing-account billingAccounts/ABCDEF-123456-789012 > billing-plan.json

google-service-gateway-admin billing projects link apply \
  --plan billing-plan.json \
  --state-dir /absolute/private/admin-state \
  --confirm-project projects/my-google-gateway-123 \
  --confirm-billing-account billingAccounts/ABCDEF-123456-789012
```

The HMAC key is read from `GOOGLE_SERVICE_GATEWAY_ADMIN_PLAN_KEY` by default and
must contain at least 32 UTF-8 bytes. Use `--plan-key-env NAME` to select another
environment variable; never place the key itself in command arguments.

Project deletion and recovery are isolated in the deleter executable:

```bash
google-service-gateway-deleter projects delete --project my-google-gateway-123
google-service-gateway-deleter projects undelete --project my-google-gateway-123
```

Google does not provide a supported public API for creating a general desktop
OAuth client. Complete that one Console step using the returned
`oauthClientSetup.consoleUrl`, download the client JSON, and bind it to the
created project while importing it:

```bash
google-service-gateway-auth clients import \
  --project my-google-gateway-123 \
  --profile personal \
  --file client_secret.json

google-service-gateway-auth consent setup \
  --project my-google-gateway-123 \
  --profile personal \
  --scope calendar.readonly \
  --scope gmail.send

google-service-gateway-auth oauth login --profile personal
google-service-gateway-auth oauth token --profile personal
```

The import and login commands reject a downloaded OAuth client whose embedded
project ID does not match the configured project. Client secrets and refresh
tokens remain in macOS Keychain. Only the explicit `oauth token` command prints
an access token.

## OAuth login and credentials

Google does not expose a supported public API for creating general OAuth
clients or editing the general consent screen. The auth gateway gives a
project-specific Console handoff, imports Google's downloaded desktop-client
JSON into macOS Keychain, and then owns the complete PKCE authorization-code,
refresh, and revocation flow without `gcloud`.

```bash
google-service-gateway-auth clients setup --project my-project
google-service-gateway-auth consent setup --project my-project \
  --profile personal \
  --scope calendar.readonly

# After creating a Desktop client and downloading its JSON:
google-service-gateway-auth clients import \
  --profile personal \
  --file client_secret.json

google-service-gateway-auth oauth login \
  --profile personal \
  --scope calendar.readonly

google-service-gateway-auth oauth token --profile personal
google-service-gateway-auth oauth revoke --profile personal
```

Reader and writer commands can use the stored profile directly and refresh it
when necessary:

```bash
google-service-gateway-reader services list \
  --project my-project \
  --oauth-profile personal

google-service-gateway-writer services enable \
  --project my-project \
  --service calendar \
  --oauth-profile personal
```

`oauth login` opens the system browser and receives the callback on a random
`127.0.0.1` port. It validates CSRF state and uses PKCE S256. Client secrets and
refresh tokens are stored in macOS Keychain. Login output contains metadata but
not tokens; only the explicit `oauth token` and `oauth refresh` commands emit an
access token.

When consent setup includes `--profile`, the resolved scope set is stored as
non-secret profile configuration in Keychain. `oauth login` uses it when no
`--scope` flags are supplied. Inspect or remove it with `consent get` and
`consent delete`.

Scope aliases can be inspected with:

```bash
google-service-gateway-auth scopes list
google-service-gateway-auth scopes list --service calendar
```

## API keys

The reader lists and gets API-key metadata. The writer creates restricted keys,
updates restrictions, and retrieves a key string only through an explicit
sensitive command. The deleter owns delete/undelete. API Keys API must be
enabled and the management access token needs the corresponding
`apikeys.keys.*` permissions.

```bash
GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-writer api-keys create \
  --project my-project \
  --display-name calendar-local \
  --api-target calendar \
  --allowed-ip 192.0.2.1

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-reader api-keys list --project my-project

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-writer api-keys get-key-string \
  --key projects/123456789/locations/global/keys/KEY_ID

GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
  google-service-gateway-deleter api-keys delete \
  --key projects/123456789/locations/global/keys/KEY_ID
```

Unrestricted key creation is rejected locally. API restrictions are mandatory,
and IP, browser-referrer, and iOS bundle restrictions are mutually exclusive in
the CLI, matching Google's API-key resource model.

API keys are not user-authorization credentials. Gmail requires OAuth user
consent (or administrator-configured Workspace domain-wide delegation), Google
Ads requires OAuth plus an approved Ads developer token, and an API key cannot
open a private spreadsheet. The explicit `api-keys get-key-string` and
`oauth token` commands provide the corresponding handoff values to downstream
tools.

Operational output is one JSON object: successes use `ok`, `command`, and
`data`; failures use `ok`, the recognized `command`, and `error`. Exit statuses
are 0 for success, 1 for unexpected/cancelled, 2 for invalid arguments, 3 for
configuration/authentication setup, 4 for provider/transport errors, 5 for an
operation failure, and 6 for an operation timeout.

Swift callers can import `GoogleServiceGatewayCore`, inject a `Sendable`
`GatewayHTTPTransport`, `AccessTokenProvider`, and `SecureCredentialStore`, and call the async clients
directly without a subprocess. To preserve arbitrary provider JSON number
lexemes in `config`, operation metadata, responses, or error details, serialize
gateway results with `GatewayJSONCodec.encode(...)` rather than a bare
`JSONEncoder`; models containing provider-defined `JSONValue` intentionally do
not conform to Foundation `Codable`, because it cannot preserve arbitrary JSON
numeric lexemes. The gateway rejects duplicate JSON object keys and validates
provider-returned pagination tokens before returning or forwarding them.
Successful provider-defined JSON and opaque page-token strings are preserved
without credential scrubbing. Sensitive-key redaction and exact scrubbing of
every access token used by a mutation are applied only when provider or
transport data is promoted into an error envelope or diagnostic.

## Riela Nodes

The sibling Riela package imports `GoogleServiceGatewayCore` directly and
provides the version 1 built-ins `riela/google-service-gateway-read` and
`riela/google-service-gateway-write`. The add-ons retain the reader/writer
capability boundary and require an explicit access-token environment binding;
they do not spawn these CLI executables. See
[`design-docs/specs/riela-integration.md`](design-docs/specs/riela-integration.md)
for the operation, input, output, and credential contract.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.1
```

Use `scripts/render-homebrew-formula.sh --dry-run 0.1.1` for validated,
non-writing renderer output. The default release source is
`tacogips/google-service-gateway`.

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.1
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install google-service-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.1
```

Use `scripts/render-homebrew-cask.sh --dry-run 0.1.1` for validated,
non-writing renderer output.

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.1
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
