# google-service-gateway

A SwiftPM library and two capability-specific command line gateways for the
Google Service Usage REST v1 API.

## Development

```bash
mise install
mise run build
mise run test
swift run google-service-gateway-reader --help
swift run google-service-gateway-writer --help
```

The package uses Swift Package Manager with:

- Library target: `GoogleServiceGatewayCore`
- Reader executable: `google-service-gateway-reader` (list, get, operation get)
- Writer executable: `google-service-gateway-writer` (enable, disable, batch enable)

The reader never sends mutations. The writer only reads operations while polling
its own mutations. Both commands emit stable JSON on success and error; help
and version are the only plain-text output.

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

Operational output is one JSON object: successes use `ok`, `command`, and
`data`; failures use `ok`, the recognized `command`, and `error`. Exit statuses
are 0 for success, 1 for unexpected/cancelled, 2 for invalid arguments, 3 for
configuration/authentication setup, 4 for provider/transport errors, 5 for an
operation failure, and 6 for an operation timeout.

Swift callers can import `GoogleServiceGatewayCore`, inject a `Sendable`
`GatewayHTTPTransport` and `AccessTokenProvider`, and call the async client
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
mise run homebrew:formula -- 0.1.0
```

Use `scripts/render-homebrew-formula.sh --dry-run 0.1.0` for validated,
non-writing renderer output. The default release source is
`tacogips/google-service-gateway`.

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
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
mise run homebrew:cask -- 0.1.0
```

Use `scripts/render-homebrew-cask.sh --dry-run 0.1.0` for validated,
non-writing renderer output.

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
