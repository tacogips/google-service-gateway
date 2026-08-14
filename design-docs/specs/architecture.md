# Architecture

## Status

Approved for implementation

## Scope

`google-service-gateway` manages whether Google APIs are enabled for one Google
Cloud project through the Google Service Usage REST v1 API, Google API keys
through API Keys API v2, and end-user OAuth runtime credentials through Google's
documented OAuth endpoints. General OAuth client and consent-screen setup is an
assisted Console workflow because Google exposes no supported public mutation
API for those resources. See `oauth-and-api-keys.md` for that hard provider
boundary. The package does not manage quotas, service identities, organizations,
or folders. No live mutation is required for development or verification.

The package has four public products:

- `GoogleServiceGatewayCore`, a reusable Swift library for in-process Riela
  nodes and other Swift callers.
- `google-service-gateway-reader`, a non-mutating executable for listing and
  getting services, inspecting long-running operations, and reading API-key
  metadata.
- `google-service-gateway-writer`, an executable for Service Usage and API-key
  mutations, plus the explicitly sensitive API-key-string retrieval command.
- `google-service-gateway-auth`, an executable for OAuth setup assistance,
  secure client import, scope resolution, PKCE login, refresh, and revocation.

The reader must never construct or send a mutation request. The writer does not
duplicate general service-list or service-get commands; callers use the reader
or the core library for those operations.

## Package Boundaries

- `Sources/GoogleServiceGatewayCore/` owns public request and response models,
  validation, alias resolution, REST request construction, transport and
  sleeper protocols, error mapping, pagination, and operation polling.
- `Sources/GoogleServiceGatewayReader/` owns only process concerns: argument and
  environment parsing, reader capability selection, JSON encoding, standard
  streams, and exit status.
- `Sources/GoogleServiceGatewayWriter/` owns the corresponding writer process
  adapter and cannot expose unsupported commands.
- `Sources/GoogleServiceGatewayAuth/` owns interactive loopback login, browser
  launch, OAuth process commands, and secure-store selection.
- `Tests/GoogleServiceGatewayCoreTests/` uses injected transports, sleepers,
  and clocks; it does not require credentials or network access.

Public core values are strongly typed `Equatable` and `Sendable`. Values that
do not contain provider-defined JSON may also be `Codable`; values containing
`JSONValue` use `GatewayJSONCodec` for lossless serialization. Public service
entry points are safe to move across Swift concurrency boundaries. The core
returns values and throws typed errors; it does not print, call `exit`, read
global process state, or spawn subprocesses.

## Configuration and Authentication

Service Usage and API Keys API requests need a management bearer access token.
Service list, get, enable, disable, batch-enable, and API-key list/create
requests also need a project; resource-name and operation requests derive their
project from the resource:

- Project precedence is explicit `--project`, then
  `GOOGLE_SERVICE_GATEWAY_PROJECT`, then `GOOGLE_CLOUD_PROJECT`.
- If `--access-token-env` is present, the token must exist in that named
  environment variable. Otherwise the CLI reads
  `GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN`. The flag selects an
  environment-variable name; it never accepts a token value.
- Library callers inject a `Sendable` access-token provider. Each service
  request carries its project value, while an operation-get request carries only
  its operation name.

The reader `operations get` command does not resolve or validate project
configuration. An explicit `--project` on that command is rejected as
`INVALID_ARGUMENT` because silently accepting an unused value could conceal a
caller mistake. Ambient `GOOGLE_SERVICE_GATEWAY_PROJECT` and
`GOOGLE_CLOUD_PROJECT` values are not read and do not affect the command.

Management bearer tokens exist in memory only for request authorization.
OAuth client secrets and refresh tokens are stored through
`SecureCredentialStore`, whose production macOS implementation uses Keychain.
Gateway-owned routine models never return secrets, and secrets are never placed
in URLs, descriptions, help, or diagnostic output. Only explicitly sensitive
`oauth token`, `oauth refresh`, and `api-keys get-key-string` results emit a
credential value.
Provider-defined values in successful 2xx payloads are preserved without token
scrubbing, including values that happen to equal the active token; redaction is
reserved for data promoted into error and diagnostic paths. Authentication
errors report only sanitized status and configuration context. OAuth bootstrap,
refresh, revocation, and persistence are isolated in the auth capability.

Production CLIs use `https://serviceusage.googleapis.com`,
`https://apikeys.googleapis.com`, Google's documented OAuth authorization/token
endpoints, and `https://oauth2.googleapis.com/revoke`. Custom provider URLs are
available only through explicit core construction so tests can inject synthetic
transports; they are not CLI options.

## Resource Validation and Aliases

Project, service, and environment-variable identifiers are ASCII and are not
trimmed; leading, trailing, or embedded whitespace is invalid. Operation names
and page tokens follow their separate opaque policies below. The project input
accepts either a bare project ID or number, or the resource form
`projects/<id-or-number>`. A project ID must match
`^[a-z][a-z0-9-]{4,28}[a-z0-9]$` (6 through 30 characters). A project number
must match `^[1-9][0-9]{0,29}$`. Normalization produces exactly
`projects/<id-or-number>`. Empty components, query or fragment characters,
percent escapes, dot segments, additional slashes, and resource types other
than lowercase `projects` are rejected before transport execution. Examples:
`my-project-1`, `123456789`, and `projects/my-project-1` are valid;
`projects//123`, `folders/123`, `../project`, and `project%2Fother` are invalid.

Service aliases and full names are normalized to lowercase but are not trimmed.
These aliases resolve before validation:

| Alias | Service ID |
| --- | --- |
| `calendar` | `calendar-json.googleapis.com` |
| `drive` | `drive.googleapis.com` |
| `gmail` | `gmail.googleapis.com` |
| `sheets` | `sheets.googleapis.com` |
| `docs` | `docs.googleapis.com` |

Otherwise, the input must be at most 253 ASCII characters and match the DNS
label grammar
`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.googleapis\.com$`.
This requires complete `.googleapis.com` names with labels of at most 63
characters and rejects slashes, percent escapes, whitespace, queries,
fragments, empty labels, and labels that begin or end with a hyphen.
`gmail.googleapis.com` and `private.example.googleapis.com` are valid;
`gmail`, `-gmail.googleapis.com`, and `gmail.googleapis.com/other` are invalid.

An access-token environment-variable name must match
`^[A-Za-z_][A-Za-z0-9_]{0,127}$`; examples are `TOKEN` and
`GOOGLE_SERVICE_GATEWAY_ACCESS_TOKEN`. Names containing `=`, whitespace, a
hyphen, or more than 128 characters are invalid.

An operation name follows the Service Usage v1 `operations.get` resource
template `{name=operations/*}`. It must contain the literal `operations/`
prefix and exactly one non-empty suffix segment. The server assigns that suffix,
so the gateway treats it as opaque and imposes no undocumented character or
length limit. A suffix containing `/`, `?`, `#`, an ASCII control character, or
DEL is invalid because it would change URL structure; a literal `%` is data,
not a pre-encoded escape. The validated suffix is percent-encoded exactly once
as one path segment. `operations/acf.123-xyz` and `operations/a:b@c` are valid;
`/operations/123`, `operations/`, `operations/one/two`, and
`operations/one?view=full` are invalid. Deterministic tests cover punctuation,
non-ASCII and longer-than-256-byte opaque suffixes, literal percent signs, and
every rejected delimiter class so both server-returned names and reader input
use the same contract.

Page tokens are opaque rather than interpreted. They must contain 1 through
4096 UTF-8 bytes and no ASCII control or DEL character, and are encoded only as
query values with `URLComponents`. The same contract is applied to every
non-empty provider-returned `nextPageToken` before it is returned or forwarded;
an invalid returned token is a `MALFORMED_RESPONSE`, while an empty returned
token is normalized to exhaustion. Paths are formed only from validated
components; no input is concatenated into an unvalidated URL.

## REST Data Flow

The core maps capabilities to Service Usage v1:

| Capability | Request |
| --- | --- |
| list services | `GET /v1/{parent}/services` |
| get service | `GET /v1/{parent}/services/{service}` |
| get operation | `GET /v1/{operation-name}` |
| enable service | `POST /v1/{parent}/services/{service}:enable` |
| disable service | `POST /v1/{parent}/services/{service}:disable` |
| batch enable | `POST /v1/{parent}/services:batchEnable` |

List accepts only `ENABLED`, `DISABLED`, or no state filter. Page size is 1
through 200 and defaults to 50. The page-oriented core API preserves the
server's `nextPageToken`; a separate all-pages API follows tokens until empty,
preserves server order, and rejects a repeated token to prevent an infinite
loop.

Every returned service resource name must identify the requested project.
`services.get` additionally requires the returned service ID to match the
requested normalized service. A list entry or get response with a different
project or service is rejected as `MALFORMED_RESPONSE` rather than relabeled as
the requested resource.

Batch enable requires 1 through 20 distinct resolved service IDs. Alias and
full-name duplicates are rejected after normalization instead of silently
changing caller intent. Google documents the request as atomic: any service
failure fails the batch.

Disable defaults to `disableDependentServices: false`. Dependents are disabled
only when the caller explicitly opts in. The optional usage check is explicit:
`SKIP` is the default and `CHECK` asks Google to reject disabling a service or
its dependents when recent use is detected. These choices are represented in
the request and echoed in the non-secret command result.

## Long-Running Operations

Enable, disable, and batch enable return a Google long-running `Operation`.
Waiting is enabled by default. The caller may disable waiting or set a positive
poll interval and timeout. Defaults are a 1-second interval and 120-second
timeout.

Polling uses an injected monotonic clock and async sleeper. When waiting remains
enabled after the initial mutation response has decoded to a valid incomplete
operation, the polling deadline is captured once as
`current monotonic time + timeout`:

1. Decode and validate the initial operation, including its name and result
   union.
2. Apply the same completion rule to every initial or polled operation: when
   `done` is true, an `error` throws `OPERATION_FAILED`; otherwise return the
   completed operation. This rule runs before the no-wait policy.
3. If the valid initial operation is incomplete and waiting is disabled, return
   it without reading the clock or sleeping.
4. Check task cancellation, read the monotonic clock once, and derive the
   deadline from that reading.
5. At each iteration, check cancellation and read the clock. If the current
   time is equal to or later than the deadline, throw `OPERATION_TIMEOUT`
   without sleeping or issuing another request.
6. Sleep for the smaller of the configured poll interval and the positive time
   remaining until the deadline.
7. After sleep, check cancellation and the clock again. If the deadline has
   been reached, throw `OPERATION_TIMEOUT` without issuing `operations.get`.
8. Request `operations.get`, decode and validate the returned operation, require
   its name to equal the requested operation name exactly, apply the completion
   rule, and repeat only when it remains incomplete. A substituted name is a
   `MALFORMED_RESPONSE` and is never followed.

Consequently, a timeout shorter than the poll interval sleeps only until the
deadline and issues no poll request. No poll request starts at or after the
deadline. A request started before the deadline may finish after it; a completed
response is returned, while an incomplete response reaches the deadline check
at the next iteration. Transport request timeouts and task cancellation remain
separate from the polling deadline. `OPERATION_TIMEOUT` contains the operation
name so a caller can inspect it later with the reader and never implies
cancellation.

The core does not automatically retry mutation requests. This avoids obscuring
whether Google accepted a mutation. Polling GET failures are surfaced with
their mapped error rather than hidden by an unbounded retry policy.

## HTTP and Error Contract

The injected async transport accepts a value request containing method, URL,
headers, and optional body and returns status, headers, and bytes. Tests can
assert the complete outbound request without network access. The bearer header
and request body must be redacted from diagnostic descriptions.

Success requires an HTTP 2xx response and decodable expected JSON. Successful
provider-defined JSON is decoded without redaction so opaque strings and JSON
number lexemes remain faithful. Non-2xx responses decode Google's error
envelope when possible and preserve only safe fields: HTTP status, Google
status/code, message, and structured details that do not contain request
headers. Error categories distinguish invalid input,
missing configuration/authentication, permission/authentication failure, rate
limiting, failed precondition, not found, provider/server response,
malformed response, operation failure, timeout, and cancellation.

Operational CLI success is one JSON object on stdout. CLI failure is one JSON
object on stderr and no stdout. `--help` and `--version` are the only plain-text
stdout exceptions. Both JSON forms use stable `GatewayJSONCodec` envelopes.
The success envelope always contains `ok: true`, a stable command name, and
command-specific `data`; the error envelope always contains `ok: false`, the
command name when parsing reached one, and `error`:

```json
{"ok":true,"command":"services.get","data":{"project":"projects/123","service":{"name":"projects/123/services/gmail.googleapis.com","parent":"projects/123","serviceId":"gmail.googleapis.com","state":"ENABLED","config":{"name":"gmail.googleapis.com","title":"Gmail API"}}}}
```

```json
{"ok":false,"command":"services.get","error":{"code":"INVALID_ARGUMENT","message":"--service is required"}}
```

### Stable Success Data

All service commands use the same service object:

```json
{
  "name": "projects/123/services/gmail.googleapis.com",
  "parent": "projects/123",
  "serviceId": "gmail.googleapis.com",
  "state": "ENABLED",
  "config": {"name": "gmail.googleapis.com", "title": "Gmail API"}
}
```

`name`, `parent`, `serviceId`, and `state` are required. `state` is one of
`STATE_UNSPECIFIED`, `DISABLED`, or `ENABLED`. `config` is a JSON object and is
required even when empty. Its nested fields are provider-defined and may grow;
they are preserved losslessly as a public `JSONValue` object. Gateway-owned
fields outside `config` are the stable contract.

Command `data` objects are exact at the gateway-owned level:

- `services.list`: `project` string, `services` array, `pagesFetched` integer,
  and optional `nextPageToken` string. A single-page response sets
  `pagesFetched` to `1` and includes `nextPageToken` only when Google returns a
  non-empty token. An all-pages response reports the number of fetched pages
  and always omits `nextPageToken` after successful exhaustion. An empty first
  page still reports `pagesFetched: 1`.
- `services.get`: `project` string and `service` object.
- `operations.get`: `operation` object.
- `services.enable`: `project`, one-element `requestedServices`, `waited`, and
  `operation`.
- `services.disable`: `project`, one-element `requestedServices`, `waited`,
  `disableDependentServices`, `checkUsage` (`SKIP` or `CHECK`), and `operation`.
- `services.batch-enable`: `project`, ordered `requestedServices`, `waited`, and
  `operation`.

An operation object always contains `name` and normalized `done`. It optionally
contains provider-defined JSON objects `metadata` and `response`, or an `error`
object with required integer `code`, required string `message`, and optional
provider-defined JSON array `details`. When Google omits `done`, it normalizes
to `false`. If `done` is false, `response` and `error` are omitted. If `done` is
true, at most one of `response` and `error` is present. Provider-defined values
use the public recursive `JSONValue` representation: object, array, string,
number, boolean, or null. This makes arbitrary Google metadata `Equatable` and
`Sendable` without making its keys part of the gateway's stability promise.
Because Foundation's generic `JSONEncoder` and `JSONDecoder` cannot preserve an
arbitrary JSON number lexeme, `GatewayJSONCodec` is the required lossless
serialization boundary for values containing `JSONValue`. The codec rejects
duplicate object keys at every nesting depth instead of applying last-key-wins
semantics to ambiguous provider data.

`waited` reflects caller policy, not operation duration: it is `true` whenever
waiting was enabled, including when the initial response was already complete,
and `false` for `--no-wait`. Requested services are resolved full service IDs
in caller order. Tokens, authorization headers, and the name of a custom token
environment variable never appear in gateway-owned success fields;
provider-defined successful payload values are not scrubbed or reinterpreted.

### Stable Error Data

The complete gateway error-code set and mapping is:

| Error code | Source | Exit |
| --- | --- | --- |
| `UNEXPECTED_ERROR` | uncategorized local failure | 1 |
| `CANCELLED` | Swift task cancellation | 1 |
| `INVALID_ARGUMENT` | CLI parsing or local value validation | 2 |
| `CONFIGURATION_ERROR` | missing or invalid project configuration | 3 |
| `AUTH_REQUIRED` | selected/default token environment variable is absent or empty | 3 |
| `AUTHENTICATION_FAILED` | HTTP 401 or Google `UNAUTHENTICATED` | 4 |
| `PERMISSION_DENIED` | HTTP 403 or Google `PERMISSION_DENIED` | 4 |
| `NOT_FOUND` | HTTP 404 or Google `NOT_FOUND` | 4 |
| `FAILED_PRECONDITION` | Google `FAILED_PRECONDITION` | 4 |
| `RATE_LIMITED` | HTTP 429 or Google `RESOURCE_EXHAUSTED` | 4 |
| `PROVIDER_ERROR` | any other non-2xx provider response | 4 |
| `MALFORMED_RESPONSE` | successful HTTP response cannot decode or violates required invariants | 4 |
| `OPERATION_FAILED` | completed operation contains `error` | 5 |
| `OPERATION_TIMEOUT` | monotonic polling deadline reached | 6 |

Provider status takes precedence over generic HTTP mapping when it gives a more
specific row above. Every error contains required `code` and safe `message`.
Optional `httpStatus`, `googleCode`, `googleStatus`, `operationName`, and
provider-defined `details` fields are included only when available and safe.
`details` uses `JSONValue` and must pass recursive redaction before encoding.
For each object key, redaction lowercases the key and removes non-alphanumeric
characters; any normalized key containing `authorization`, `token`,
`credential`, or `secret` is sensitive. This covers snake case, camel case, and
variants such as `access_token`, `accessToken`, `refreshToken`, `id_token`,
`Authorization`, `credentialData`, and `clientSecret`. A sensitive value is
replaced with `"<redacted>"` without traversing or stringifying it.

If two recursively redacted keys collide, all fields are preserved under
deterministic `#2`, `#3`, and later suffixes rather than overwriting a field in
dictionary iteration order.

As a final error-path guard, every serialized provider error message, Google
status message, error-detail string, error-detail object key, operation name,
typed transport-error string, and unexpected-error message is scrubbed by
replacing every exact occurrence of each applicable non-empty access-token
value with `"<redacted>"`. A mutation retains only its call-local set of tokens
long enough to scrub operation names promoted into failure, timeout, or
cancellation errors; successful operation output remains untouched. Tests
inject recognizable tokens and require their absence from error envelopes and
diagnostic descriptions. Raw headers, request bodies, URLs containing query
values, tokens, selected token-variable names, and underlying error
descriptions that may contain requests are never serialized on those paths.

Optional fields are omitted consistently rather than encoded sometimes as
`null`. Required provider `null` values inside `config`, `metadata`, `response`,
or `details` remain JSON null. Key order is not part of the contract. Pretty
printing changes only whitespace. Exit status is `0` for success; all failure
statuses are fixed by the table above.

## Reference Mapping and Intentional Divergences

The sibling `../mail-gateway` package is a structural and behavioral reference,
with the following concrete mapping:

| Reference path | Reference flow | Gateway decision |
| --- | --- | --- |
| `../mail-gateway/Package.swift` | Declares a reusable core product and capability-specific executable targets. | Keep one public core library and separate reader, writer, and auth products. |
| `../mail-gateway/Sources/MailGatewayCore/MailGatewayCore.swift` | Defines shared exit codes, errors, command results, configuration, and service entry points. | Preserve typed errors and result consistency, but expose strongly typed `Equatable`, `Sendable` domain values and `GatewayJSONCodec` output instead of string output and heterogeneous dictionaries. |
| `../mail-gateway/Sources/MailGatewayCore/MailGatewayCLI.swift` | Parses arguments, selects a CLI mode, loads process configuration, invokes services, and builds stdout/stderr results inside the public core target. | Intentionally keep argument/environment parsing, help, JSON encoding, standard streams, and exit behavior in process adapters. Riela callers receive domain values and typed errors without importing a CLI facade or process state. |
| `../mail-gateway/Sources/MailGatewayReader/main.swift`, `MailGatewayDraft/main.swift`, and `MailGatewaySender/main.swift` | Thin entry points choose a mode, invoke the shared CLI facade, write its stdout/stderr, and exit with its status. | Keep entry points equally thin, but each executable can construct only its reader or writer adapter, preventing the reader binary from selecting a mutation mode. |
| `../mail-gateway/Tests/MailGatewayCoreTests/CommandTests.swift` | Verifies mode-specific help, version, command acceptance, JSON output, and exit behavior. | Retain equivalent contract tests and add injected HTTP, clock, and sleeper coverage for URL construction, pagination, mutation polling, and timeout boundaries. |
| `../mail-gateway/Sources/MailGatewayCore/GmailOAuthSupport.swift` | Loads, refreshes, and can persist OAuth credentials and token stores. | Implement Google PKCE and token endpoints directly, behind injectable stores and transports, with macOS Keychain as the production store. |
| `../mail-gateway/README.md` | Documents executable boundaries and direct Swift library use. | Document all three executables plus in-process `GoogleServiceGatewayCore` use for Riela nodes. |

The command adapter flow is `arguments/environment -> reader or writer adapter
-> typed core request -> transport/poller -> typed core result or error ->
stable JSON and exit status`. Only the middle core request/result segment is
available to in-process Riela callers. This differs intentionally from
`MailGatewayCLI`, whose public core module owns the full process flow.

There is no Cursor CLI behavior or Cursor reference adapter in the accepted
scope. If a Cursor-facing surface is added later, it must translate Cursor
inputs and outputs in a process adapter beside the reader/writer adapters; it
must not add Cursor types, subprocess execution, or global process state to
`GoogleServiceGatewayCore`. The current reader/writer split is therefore the
explicit Cursor isolation boundary rather than an implicit compatibility
promise.

The authoritative external protocol references are the Google Service Usage
REST v1 documentation for
[`services`](https://docs.cloud.google.com/service-usage/docs/reference/rest/v1/services)
and
[`operations.get`](https://docs.cloud.google.com/service-usage/docs/reference/rest/v1/operations/get).

## Rollout and Verification

Implementation replaces the scaffold `AppCore`, `AppCLI`, and `AppCoreTests`
targets after equivalent version/help and error behavior exists in the new
targets. Documentation and Homebrew metadata must name all three executables; this
issue does not publish artifacts, commit, or push.

Verification is local and non-mutating:

```bash
mise run lint
swiftlint
swift test
swift build
swift run google-service-gateway-reader --help
swift run google-service-gateway-writer --help
swift run google-service-gateway-auth --help
```

Run `swiftlint` directly only when available and report unavailable tooling.

## Risks and Review Requirements

This is high-risk work requiring adversarial review because it handles bearer
tokens and externally mutates project service state. Review must explicitly
test secret redaction, path and alias validation, reader mutation rejection,
batch limits, dependent-disable opt-in, error decoding, repeated pagination
tokens, timeout boundaries, cancellation, and Swift 6 `Sendable` correctness.
