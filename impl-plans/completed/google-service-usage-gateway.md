# Google Service Usage Gateway

**Status**: Complete
**Issue**: Design and implement the Google Service Usage gateway
**Workflow Mode**: `issue-resolution`
**Design References**:

- `design-docs/specs/architecture.md#scope`
- `design-docs/specs/architecture.md#package-boundaries`
- `design-docs/specs/architecture.md#configuration-and-authentication`
- `design-docs/specs/architecture.md#resource-validation-and-aliases`
- `design-docs/specs/architecture.md#rest-data-flow`
- `design-docs/specs/architecture.md#long-running-operations`
- `design-docs/specs/architecture.md#http-and-error-contract`
- `design-docs/specs/architecture.md#reference-mapping-and-intentional-divergences`
- `design-docs/specs/architecture.md#rollout-and-verification`
- `design-docs/specs/architecture.md#risks-and-review-requirements`
- `design-docs/specs/command.md#shared-options`
- `design-docs/specs/command.md#reader`
- `design-docs/specs/command.md#writer`

## Purpose

Replace the SwiftPM scaffold with a reusable, `Sendable`-friendly Service Usage
REST v1 library and two capability-specific command-line products. The reader
must remain non-mutating. The writer must expose only enable, disable, and
batch-enable commands, with internal operation polling. Authentication is an
ephemeral bearer token, and no implementation or test may persist, print, or
diagnostically expose it.

This plan covers local implementation and verification only. It does not perform
a live Google mutation, publish an artifact, commit, or push.

## Source-of-Truth Decisions

- Scope is project API/service activation management only. OAuth setup, OAuth
  clients, end-user scopes, quotas, service identities, folders, and
  organizations remain out of scope.
- Public products are `GoogleServiceGatewayCore`,
  `google-service-gateway-reader`, and `google-service-gateway-writer`.
- The reader exposes `services list`, `services get`, and `operations get`; it
  must reject mutation commands before configuration or transport resolution.
- The writer exposes `services enable`, `services disable`, and
  `services batch-enable`; its only read is internal `operations.get` polling.
- The core owns typed domain behavior and injected dependencies but no argument
  parsing, environment reads, standard streams, process exits, or subprocesses.
- The exact validation, alias, JSON-envelope, error-code, redaction, pagination,
  and polling contracts in the accepted design are mandatory.
- No Cursor adapter is in scope. Reader/writer process adapters are the explicit
  boundary for any future Cursor integration.

## Reference Traceability and Intentional Divergences

| Reference | Behavior to retain | Accepted divergence |
| --- | --- | --- |
| `../mail-gateway/Package.swift` | Public core library plus capability-specific executables and Swift 6 mode. | Provide exactly one core library and two Service Usage executables rather than mail reader/draft/sender products. |
| `../mail-gateway/Sources/MailGatewayCore/MailGatewayCore.swift` | Typed errors, exit codes, configuration values, command results, and service entry points. | Use strongly typed `Equatable`, `Sendable` request/result models, recursive `JSONValue`, and lossless `GatewayJSONCodec`; do not expose heterogeneous dictionaries or process output from core APIs. |
| `../mail-gateway/Sources/MailGatewayCore/MailGatewayCLI.swift` | Argument-to-command dispatch, configuration precedence, stable output, and exit behavior. | Keep parsing, environment access, JSON encoding, streams, and exit status in reader/writer process adapters, outside `GoogleServiceGatewayCore`. |
| `../mail-gateway/Sources/MailGatewayReader/main.swift`, `../mail-gateway/Sources/MailGatewayDraft/main.swift`, `../mail-gateway/Sources/MailGatewaySender/main.swift` | Thin executable entry points. | Each new entry point constructs only its own reader or writer adapter so the reader cannot select mutation behavior. |
| `../mail-gateway/Tests/MailGatewayCoreTests/CommandTests.swift` | Help/version, command acceptance, JSON output, and exit-code contract tests. | Add deterministic injected HTTP, sleeper, clock, cancellation, pagination, operation, and secret-redaction tests. |
| `../mail-gateway/Sources/MailGatewayCore/GmailOAuthSupport.swift` | Reference only for identifying credential-sensitive boundaries. | Do not reuse OAuth bootstrap, refresh, browser, keychain, or token-store behavior; accept only an injected or environment-sourced ephemeral bearer token. |
| `../mail-gateway/README.md` | Executable-boundary and direct-library usage documentation. | Document Service Usage commands and in-process Riela usage without a subprocess or Cursor-specific type. |
| Google Service Usage REST v1 `services` and `operations.get` documentation | Wire paths, request fields, response envelopes, operation union, filters, and batch constraints. | Apply stricter local path/token validation and stable gateway-owned output fields before transport or serialization. |

## Deliverables

- [x] `Package.swift` declares the accepted library, executable, and test target
  graph in Swift 6 mode.
- [x] `Sources/GoogleServiceGatewayCore/` contains public domain models,
  validation, authentication abstraction, request construction, transport,
  pagination, polling, error mapping, redaction, and service entry points.
- [x] `Sources/GoogleServiceGatewayReader/` contains the reader process adapter
  and thin entry point, with no mutation route.
- [x] `Sources/GoogleServiceGatewayWriter/` contains the writer process adapter
  and thin entry point, with no general list/get route.
- [x] `Tests/GoogleServiceGatewayCoreTests/` contains deterministic core and CLI
  contract coverage with no credentials or network requirement.
- [x] Legacy `AppCore`, `AppCLI`, and `AppCoreTests` paths are removed only after
  equivalent replacement behavior exists.
- [x] `README.md`, `mise.toml`, `.github/workflows/linux-amd64-build.yml`,
  `packaging/homebrew/README.md`, and relevant `scripts/` surfaces name and
  handle both executables.
- [x] Lint, tests, build, CLI smoke checks, and non-publishing packaging checks
  pass, or unavailable tooling is reported explicitly.

## Task Breakdown

### TASK-001: Reshape the SwiftPM Package

**Write Scope**: `Package.swift`, target directories required for initial
scaffolding
**Dependencies**: None
**Parallelizable**: No

**Actions**:

1. Declare library product/target `GoogleServiceGatewayCore` and executable
   products/targets `google-service-gateway-reader` /
   `GoogleServiceGatewayReader` and `google-service-gateway-writer` /
   `GoogleServiceGatewayWriter`.
2. Rename the test target to `GoogleServiceGatewayCoreTests` and give it the
   target dependencies needed to test public core behavior and both process
   adapters without spawning a subprocess.
3. Preserve macOS platform and Swift 6 language-mode settings.
4. Establish thin reader and writer entry points; delay removing scaffold files
   until the replacement targets compile.

**Deliverables**:

- `Package.swift`
- `Sources/GoogleServiceGatewayCore/`
- `Sources/GoogleServiceGatewayReader/`
- `Sources/GoogleServiceGatewayWriter/`
- `Tests/GoogleServiceGatewayCoreTests/`

**Completion Criteria**:

- [x] `swift package describe` lists exactly the accepted public products.
- [x] Both executable targets depend on the core; core depends on neither
  executable.
- [x] Test code can import the modules needed for adapter contract tests.
- [x] No public product retains `AppCore`, `AppCLI`, or the singular executable.

### TASK-002: Implement Public Models, Validation, Authentication, and Safe Errors

**Write Scope**: `Sources/GoogleServiceGatewayCore/` model, validation,
authentication, error, redaction, and version files
**Dependencies**: TASK-001
**Parallelizable**: No

**Actions**:

1. Add recursive public `JSONValue` and typed service, operation, page,
   mutation-result, success-envelope, error-envelope, error-code, and exit-code
   values with accepted `Equatable`, `Sendable`, and lossless
   `GatewayJSONCodec` behavior.
2. Add validation and normalization for project IDs/numbers/resource names,
   service aliases/full names, operation names, page tokens, page sizes, batch
   sizes/duplicates, environment-variable names, and finite positive polling
   durations.
3. Add a `Sendable` access-token provider boundary and CLI-independent project
   request values. Do not add token persistence, refresh, browser, or OAuth
   bootstrap behavior.
4. Implement safe error construction, Google error mapping, recursive sensitive
   key redaction with deterministic collision preservation, exact applicable-
   token scrubbing on error/reporting paths, and diagnostic descriptions that never
   expose headers, bodies, token values, token-variable names, or request URLs
   containing opaque query values.
5. Retain the repository version behavior under the renamed core module.

**Completion Criteria**:

- [x] Alias resolution exactly covers calendar, drive, gmail, sheets, and docs,
  while validated full `*.googleapis.com` names remain accepted.
- [x] Invalid resource/path inputs fail before transport execution.
- [x] Public core values compile under Swift 6 concurrency checking.
- [x] Error codes, optional-field omission, exit codes, and redaction match
  `design-docs/specs/architecture.md#stable-error-data`.
- [x] No core type reads process globals, prints, exits, or spawns a subprocess.

### TASK-003: Implement Injected HTTP and Read Operations

**Write Scope**: `Sources/GoogleServiceGatewayCore/` request, transport, client,
and pagination files
**Dependencies**: TASK-002
**Parallelizable**: No

**Actions**:

1. Define async `Sendable` request/response transport values and a production
   URL-session transport with a fixed CLI base URL of
   `https://serviceusage.googleapis.com`.
2. Construct list, get, and operation-get URLs only from validated components;
   encode page tokens as query values and opaque operation suffixes exactly once
   as one path segment.
3. Attach the bearer token only as an authorization header and decode only 2xx
   responses into the expected typed models.
4. Implement list filtering and pagination exactly as designed: omit the state
   filter for `all`, map enabled/disabled to the provider filter, default page
   size to 50 within the 1...200 range, return one page by default, and forward
   an opaque page token only as a query value.
5. Implement all-pages reads that preserve server order, follow returned tokens
   until exhaustion, and reject a repeated non-empty token.
6. Validate provider response invariants and map malformed or non-2xx responses
   to the accepted stable errors.
7. Correlate every service resource name with the requested project and, for
   service get, the requested normalized service ID.

**Completion Criteria**:

- [x] `services list`, `services get`, and `operations get` are available as
  public in-process core APIs.
- [x] Full outbound requests are assertable through an injected transport.
- [x] List requests apply the exact state filter, page-size default/bounds, and
  opaque page-token query behavior from the accepted design.
- [x] Pagination reports exact `pagesFetched` and `nextPageToken` semantics.
- [x] Operations-get requires no project value.
- [x] No live network access is required by tests.

### TASK-004: Implement Mutations and Long-Running Operation Polling

**Write Scope**: `Sources/GoogleServiceGatewayCore/` mutation and polling files
**Dependencies**: TASK-003
**Parallelizable**: No

**Actions**:

1. Construct enable, disable, and batch-enable POST requests with exact Service
   Usage v1 body fields and no automatic mutation retry.
2. Apply the accepted defaults and bounds: wait enabled, one-second interval,
   120-second polling timeout, 1...20 distinct batch services,
   `disableDependentServices: false`, and usage check `SKIP`.
3. Add injected monotonic clock and async sleeper boundaries.
4. Implement the accepted initial-operation completion rule, no-wait behavior,
   deadline checks, shortened final sleep, cancellation checks, operation-get
   polling, in-flight request semantics, and terminal failure mapping.
5. Return normalized requested service IDs and explicit disable/wait policy in
   stable mutation results without returning secrets.

**Completion Criteria**:

- [x] All three mutations return immediately for valid `--no-wait` incomplete
  operations and still surface an already-completed operation error.
- [x] No poll begins at or after the monotonic deadline.
- [x] An incomplete operation at the deadline yields `OPERATION_TIMEOUT` with
  its operation name; cancellation yields `CANCELLED`.
- [x] Poll GET failures surface directly and mutation POSTs are never retried.
- [x] Disable-dependent and usage-check choices match the request and output.

### TASK-005: Implement the Reader Process Adapter

**Write Scope**: `Sources/GoogleServiceGatewayReader/`
**Dependencies**: TASK-002, TASK-003
**Parallelizable**: Yes, with TASK-006 after both tasks' dependencies are met

**Actions**:

1. Parse shared options and only `services list`, `services get`, and
   `operations get`, including their required `--service` and `--operation`
   values.
2. Parse `services list` controls explicitly: state
   (`--state enabled|disabled|all`), page size (`--page-size 1...200`),
   `--page-token`, and `--all-pages`; use one page and page size 50 by default,
   omit the filter for state `all`, and reject `--page-token` combined with
   `--all-pages`.
3. Apply project precedence and token-environment selection exactly as designed;
   skip ambient project resolution for `operations get` and reject an explicit
   project there.
4. Reject all mutation and unknown commands before project, token, or transport
   resolution.
5. Encode one stable JSON success object to stdout or one stable error object to
   stderr; preserve plain-text help/version exceptions and fixed exit statuses.
6. Keep `main.swift` limited to process inputs, adapter invocation, stream
   writes, and exit.

**Completion Criteria**:

- [x] Reader help lists no mutation capability.
- [x] Reader mutation attempts execute zero transport requests and do not
  inspect token/project configuration.
- [x] Reader list defaults, state mapping, pagination flags, bounds, and
  `--page-token`/`--all-pages` conflict match the accepted command design.
- [x] Reader results match the accepted command names and exact data envelopes.
- [x] Reader adapter behavior is testable without launching a child process.

### TASK-006: Implement the Writer Process Adapter

**Write Scope**: `Sources/GoogleServiceGatewayWriter/`
**Dependencies**: TASK-002, TASK-004
**Parallelizable**: Yes, with TASK-005 after both tasks' dependencies are met

**Actions**:

1. Parse shared options and only `services enable`, `services disable`, and
   `services batch-enable`.
2. Parse no-wait, poll interval, timeout, repeated service, disable-dependent,
   and usage-check options with the accepted conflicts and bounds.
3. Reject general list/get and operation-administration commands before
   transport execution.
4. Produce the same stable stdout/stderr/error/exit contract as the reader and
   keep the entry point thin.

**Completion Criteria**:

- [x] Writer help documents only supported mutations and polling controls.
- [x] Writer read-command attempts execute zero transport requests.
- [x] `--no-wait` rejects explicit polling options.
- [x] Writer envelopes include resolved requested services and explicit policy
  fields without secrets.

### TASK-007: Add Deterministic Core and CLI Contract Tests

**Write Scope**: `Tests/GoogleServiceGatewayCoreTests/`
**Dependencies**: TASK-002 through TASK-006
**Parallelizable**: Yes, with TASK-008 only

**Actions**:

1. Add reusable recording transport, scripted sleeper, monotonic clock, token
   provider, response fixtures, and stdout/stderr adapter harnesses.
2. Cover every accepted validation grammar, alias, full service name, encoded
   operation suffix, opaque page token, exact URL, HTTP method, header, body,
   response decoding, and error mapping.
3. Cover core list behavior for the default page size of 50, explicit 1 and 200
   boundaries, invalid sizes, enabled/disabled filters, omitted `all` filter,
   opaque page-token forwarding, one-page/all-page behavior, empty pages,
   page-token preservation, and repeated-token rejection.
4. Cover mutation request bodies, batch constraints/atomic request shape,
   disable defaults/opt-ins, no-wait, initially complete operations, successful
   polling, provider operation failure, timeout boundaries, cancellation, poll
   GET failure, and no mutation retry.
5. Inject a recognizable token into successful provider-defined values and
   assert faithful preservation; inject it independently into provider-error,
   malformed-response, diagnostic, and unexpected-error paths and assert its
   absence from error output, descriptions, headers shown in diagnostics, and
   persisted files.
6. Cover reader mutation rejection, writer read rejection, help/version,
   configuration precedence, operation-get project isolation, pretty output,
   command names, optional-field omission, and exit status.
7. Add reader-adapter tests for parsing every list option, one-page and page-size
   defaults, state `all` filter omission, exact request forwarding, all-pages
   output semantics, all page-size bounds, and rejection of `--page-token`
   combined with `--all-pages` before transport execution.

**Completion Criteria**:

- [x] Tests use no real credentials, network, wall-clock sleeps, or live Google
  mutations.
- [x] Boundary tests prove no poll starts at/after the deadline and define the
  accepted behavior for an in-flight poll crossing the deadline.
- [x] Tests prove Swift task cancellation is distinct from timeout.
- [x] Tests prove the reader cannot reach a mutation transport path.
- [x] Adapter tests trace every accepted reader list flag, default, bound, and
  conflict to exact transport and JSON behavior.
- [x] Tests prove the token is absent across success, error, and diagnostic
  output paths.

### TASK-008: Update User Documentation, Automation, and Packaging Metadata

**Write Scope**: `README.md`, `mise.toml`,
`.github/workflows/linux-amd64-build.yml`, `packaging/homebrew/README.md`,
`scripts/build-homebrew-release.sh`, `scripts/render-homebrew-formula.sh`,
`scripts/build-homebrew-cask-release.sh`, `scripts/render-homebrew-cask.sh`, and
`scripts/release-homebrew-cask-local.sh` when product-name assumptions apply
**Dependencies**: TASK-001
**Parallelizable**: Yes, with TASK-002 through TASK-007 because write scopes are
disjoint; reconcile final command examples after TASK-005 and TASK-006

**Actions**:

1. Document direct core-library usage for Riela nodes, both executable
   capability boundaries, all commands/options, alias/project forms,
   authentication precedence, disable semantics, polling/no-wait behavior,
   stable JSON, exit codes, and secret-handling guidance.
2. Replace the singular mise run task with explicit reader/writer tasks while
   preserving build, test, lint, and release tasks.
3. Make Linux CI build both accepted executable products.
4. Make formula archives stage both binaries and rendered formulae install and
   version-check both binaries.
5. Make cask DMGs stage, sign, and expose both binaries and rendered casks link
   both binaries; keep notarization credentials and values out of output.
6. Update release documentation and local-release messaging without publishing
   or mutating the sibling tap during this issue.

**Completion Criteria**:

- [x] No active documentation, task, CI workflow, formula builder/renderer, or
  cask builder/renderer expects the removed singular executable.
- [x] Formula and cask dry-run plans name both reader and writer artifacts.
- [x] README examples never pass a token as a literal CLI argument or print it.
- [x] No signing, notarization, release upload, tap mutation, commit, or push is
  performed for verification.

### TASK-009: Integrate, Verify, and Close the Plan

**Write Scope**: Narrow fixes in prior task scopes plus this plan's progress log
**Dependencies**: TASK-001 through TASK-008
**Parallelizable**: No

**Actions**:

1. Remove remaining scaffold paths and stale singular-product references only
   after replacements compile and tests cover equivalent help/version behavior.
2. Run formatting/diff checks, SwiftLint when available, the full test suite,
   full build, CLI help/version smoke checks, and non-publishing package checks.
3. Review the diff specifically for token literals, credential values, machine-
   local paths, unrelated edits, accidental live endpoints in tests, and files
   over 1000 lines that should be split by responsibility.
4. Record exact command results and any unavailable tooling in the progress log.
5. Mark the plan complete and move it to `impl-plans/completed/` only after every
   completion criterion is satisfied.

**Completion Criteria**:

- [x] All verification commands pass or unavailable tooling is explicitly
  reported with a safe fallback result.
- [x] Acceptance criteria are traceable to tests or inspected deliverables.
- [x] No live mutation, publication, commit, or push occurred.
- [x] The working tree contains no unrelated changes introduced by this work.

## Dependencies

```text
TASK-001
├── TASK-002
│   └── TASK-003
│       ├── TASK-004
│       │   └── TASK-006
│       └── TASK-005
└── TASK-008

TASK-002..TASK-006 ──> TASK-007
TASK-001..TASK-008 ──> TASK-009
```

External dependencies are Swift 6/SwiftPM, Foundation networking support,
SwiftLint when available, and the accepted Google Service Usage REST v1
contract. Production credentials and live Google access are not dependencies.

## Parallel Execution Rules

- TASK-005 and TASK-006 may run in parallel only after their respective core
  dependencies are stable; their write scopes are separate executable folders.
- TASK-008 may run alongside core, CLI, or test work after TASK-001 because it
  owns documentation, automation, and packaging files only.
- TASK-007 may run alongside TASK-008 after the core and adapters stabilize.
- TASK-002, TASK-003, and TASK-004 must remain sequential because they share the
  core source directory and build on the same public contracts.
- TASK-001 and TASK-009 are integration tasks and must run alone.

## Verification

Run the narrowest relevant tests while completing each task, then run the full
sequence from the repository root:

```bash
git diff --check
swiftlint
swift test
swift build
swift run google-service-gateway-reader --help
swift run google-service-gateway-reader --version
swift run google-service-gateway-writer --help
swift run google-service-gateway-writer --version
scripts/build-homebrew-release.sh --dry-run darwin-arm64 darwin-x64
scripts/build-homebrew-cask-release.sh --dry-run darwin-arm64 darwin-x64
rg -n 'AppCore|AppCLI|swift run google-service-gateway([^[:alnum:]-]|$)|bin/google-service-gateway([^[:alnum:]-]|$)' Package.swift Sources Tests README.md mise.toml packaging scripts .github
git status --short
```

Use `mise run lint`, `mise run test`, and `mise run build` when the repository is
trusted by mise; direct `swiftlint`, `swift test`, and `swift build` are the
fallbacks. A missing `swiftlint` executable must be reported rather than hidden.
Generated formula/cask syntax or install checks must use temporary output and
must not mutate `../homebrew-tap`.

## Overall Completion Criteria

- [x] All accepted products, commands, library APIs, aliases, project forms,
  disable controls, and default polling behavior exist.
- [x] Reader and writer capability boundaries are enforced before transport or
  secret/configuration resolution.
- [x] Public core APIs are importable, strongly typed, and Swift 6
  `Sendable`-friendly without a subprocess.
- [x] HTTP construction, error mapping, pagination, polling, cancellation, and
  secret redaction have deterministic injected-dependency tests.
- [x] Stable JSON/exit contracts and optional-field behavior match the accepted
  design.
- [x] README, mise, CI, formula, and cask surfaces consistently support both
  executables.
- [x] `git diff --check`, SwiftLint when available, `swift test`, `swift build`,
  CLI smoke checks, and safe packaging dry runs succeed.
- [x] No live Google mutation, credential persistence/exposure, publication,
  commit, or push occurs.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Bearer token appears in a provider error, parse error, or diagnostic description. | Keep tokens out of gateway-owned models/URLs, structurally redact request material, scrub every token used by a mutation from promoted operation errors, scrub the applicable token on other error/reporting paths, and separately prove successful provider-defined opaque values remain faithful. |
| Foundation URL behavior double-encodes or structurally interprets opaque operation names/page tokens. | Validate components first, encode the operation suffix exactly once, use query items for page tokens, and assert complete outbound URLs with punctuation, percent, non-ASCII, and long inputs. |
| Polling misses deadline/cancellation boundaries or starts an extra request. | Inject clock/sleeper/transport, script equality and shortened-sleep boundaries, assert request counts/order, and test in-flight behavior separately from polling timeout. |
| Mutation retry duplicates an accepted side effect. | Do not automatically retry mutation POSTs; surface ambiguous transport failures. |
| Reader accidentally gains write capability through shared dispatch. | Use separate adapter command enums/routers and assert rejection before configuration/token/transport access. |
| Swift 6 rejects protocol existentials or mutable test doubles as non-Sendable. | Prefer immutable value requests/results and actor or synchronized test doubles; compile early under Swift 6 and add concurrency-focused tests. |
| Stable JSON drifts because provider-defined objects leak into gateway-owned fields. | Isolate provider data in `JSONValue` fields and use typed gateway envelopes with exact encoding tests. |
| Packaging continues to stage the removed singular executable. | Treat both binaries as one artifact set and dry-run formula/cask builders plus inspect rendered install declarations. |
| Large cross-cutting Swift files become difficult to review. | Split files by models, validation, transport, client, polling, errors, and CLI responsibility; keep every Swift file below 1000 lines. |

## Progress Log Expectations

- Append one dated entry whenever a task starts, completes, becomes blocked, or
  changes scope.
- Each completion entry must name the task, changed file paths, verification
  commands, and their exact status.
- Record unavailable tools and safe fallbacks explicitly.
- Record review findings and follow-up fixes without rewriting prior entries.
- Do not mark the plan complete while any checkbox, high/mid review finding, or
  required verification remains unresolved.

## Progress Log

- 2026-08-14: Closed TASK-001 through TASK-009 after the final integration
  gate. Riela now resolves Kaiba `115e80514565b510d2a9a2b53db00291887669ec`
  and `anydoc-swift` v0.1.3 commit
  `d957c08372786b7062553e83fe9c29880fdee7a4`; its four focused
  `GoogleServiceGatewayAddonTests` linked and passed directly with the release
  XCFramework and no stub, Cargo, or `PKG_CONFIG_PATH`. In this repository,
  `swift package describe`, `swift test` (54 tests), `swift build`, reader and
  writer help/version smoke tests, Formula and Cask build-plan dry runs,
  `bash -n scripts/*.sh`, stale-product searches, Swift file-size checks, and
  `git diff --check` passed. Direct SwiftLint remains unavailable, and the
  project-managed invocation remains blocked because `mise.toml` is untrusted;
  trust state was not changed. All acceptance criteria are now checked and the
  plan is ready for `impl-plans/completed/`. No live Google call, credential
  use, publication, signing, notarization, tap mutation, commit, or push was
  performed.

- 2026-08-14: Integrated the public core library into the sibling Riela
  checkout at `../riela`. Added the version 1 built-ins
  `riela/google-service-gateway-read` and
  `riela/google-service-gateway-write`, capability-tier operation validation,
  explicit access-token environment binding, Riela deadline-bounded mutation
  polling, typed result translation, an injected client seam, catalog tests,
  and four focused resolver tests. Added
  `design-docs/specs/riela-integration.md` as the node contract. Gateway
  verification passed `swift test` (54 tests), `swift build`, and
  `git diff --check`. Riela verification passed `swift build --target RielaCLI`,
  `swift build --target RielaCLITests`, four focused gateway add-on tests, the
  focused catalog test, and `git diff --check`. The focused tests used a
  removed-after-use link-only stub for Riela's unrelated `anydoc_ffi` symbols
  because Cargo and the native library are unavailable. SwiftLint is also
  unavailable. No live Google calls or credentials were used.

- 2026-08-14: Addressed all three medium findings from Riela implementation
  review session `google-service-gateway-implementation-review-session-726`:
  removed the `nextPageToken` error-redaction exemption, rejected substituted
  names in polled `operations.get` responses without following them, and used a
  mutation-call-local collection to scrub every acquired rotating token from
  operation failure, timeout, and cancellation names without changing success
  output. Independent regressions passed as part of 54 passing `swift test`
  tests; `swift build`, reader/writer help and version, representative offline
  error envelopes, tracked and untracked-text diff checks, and Swift file-size
  checks passed. Direct SwiftLint was unavailable, and mise was not trusted or
  invoked. No live calls, credentials, publication, commits, or pushes were
  performed.

- 2026-08-14: Addressed every medium finding from Riela implementation review
  session `google-service-gateway-implementation-review-session-4`: preserved
  successful provider JSON without token scrubbing, limited active-token
  redaction to error/reporting paths, made recursive redaction collisions
  deterministic and lossless, correlated service response names to requested
  projects/services, expanded independent pagination/validation/request/error/
  CLI regression coverage, and corrected both Homebrew release skills to verify
  reader and writer executables. Direct `swift test` passed 48 tests and direct
  `swift build` passed; both CLI help/version and pre-transport error-envelope
  checks passed; `git diff --check` including 14 untracked text files, `bash -n`,
  Formula/Cask build-plan dry runs, and generated Ruby syntax/safety assertions
  passed. `mise` tasks were not run because the repository is untrusted, and
  SwiftLint was unavailable. No credentials, live Google calls, signed or
  notarized builds, publication, commits, or pushes were used.

- 2026-08-14: Plan created from the Step 3 accepted architecture and command
  designs; no Step 5 feedback exists yet.
- 2026-08-14: Addressed Step 5 finding at the plan header by replacing
  file-level design references with section-anchored links covering scope,
  boundaries, configuration, validation, REST flow, polling, HTTP/error
  contracts, reference divergences, rollout, risks, and reader/writer commands.
- 2026-08-14: Addressed Step 5 reader-list coverage finding by expanding
  TASK-003, TASK-005, and TASK-007 with explicit state filtering, page-size
  defaults and bounds, opaque page-token forwarding, one-page/all-pages
  behavior, option conflicts, and adapter-level transport/JSON tests.
- 2026-08-14: Implemented the SwiftPM product graph, public core models,
  validation, injected transport/token/clock/sleeper boundaries, REST client,
  reader and writer adapters, deterministic core/adapter tests, documentation,
  mise tasks, Homebrew scripts, and Linux build workflow. Verification status
  is recorded with the Step 6 result; remaining failures, if any, must be fixed
  before this plan is moved to `impl-plans/completed/`.
- 2026-08-14: Step 6 self-review found token-detail redaction, cancellation,
  error-envelope, validation, JSON-number, documentation, and deterministic
  polling-test gaps. Deliverable completion marks were reset pending these fixes
  and independent review.
- 2026-08-14: Addressed Step 6 self-review findings: token-aware recursive
  redaction, typed cancellation, command-bearing error envelopes, ASCII token
  environment validation, decimal JSON numbers, stricter reader option routing,
  expanded CLI documentation, and deterministic mutation/polling/error tests.
  Deliverables remain unchecked until independent review and final verification.
- 2026-08-14: Verification after the self-review fixes passed: `swift test`
  (21 deterministic tests), `swift build`, `git diff --check`, shell syntax
  checks, executable help smoke checks, and formula/cask dry runs. Direct
  `swiftlint` is unavailable and `mise exec -- swiftlint` is blocked because
  this repository's mise configuration is untrusted; no trust-state mutation
  was performed.
- 2026-08-14: Addressed the follow-up self-review findings in
  `Sources/GoogleServiceGatewayCore/Client.swift`,
  `Sources/GoogleServiceGatewayCore/Models.swift`, reader/writer adapters, and
  `Tests/GoogleServiceGatewayCoreTests/GatewayTests.swift`: mutation polling
  options are now validated before every POST, and provider JSON number lexemes
  are parsed and re-emitted exactly. Added zero-request invalid-option tests
  plus 50-digit integer, high-precision decimal, exponent, and CLI response
  round-trip coverage. The `swift test` output passed with 23 deterministic
  tests (the shell wrapper timed out after the passing output); deliverables
  remain unchecked pending independent review and final verification.
- 2026-08-14: Addressed the next self-review findings: successful responses
  now parse before recursively scrubbing the active token, preserving opaque
  page tokens; the JSON codec now writes a structural JSON tree without a
  regex sentinel, validates number lexemes, and uses explicit gateway result
  representations. Added escaped quote/backslash token tests for core and CLI,
  marker-like string and nested-number round trips, invalid-number rejection,
  and standard `JSONEncoder` non-lossy failure coverage. Deliverables remain
  unchecked pending independent review and final verification.
- 2026-08-14: Verification after the latest remediation: `swift test` output
  passed with 26 deterministic tests and `swift build` completed (both shell
  wrappers timed out after their successful output); `git diff --check` passed.
  Direct `swiftlint` remains unavailable and `mise exec -- swiftlint` remains
  blocked because this repository's mise configuration is untrusted; no
  trust-state mutation was performed.
- 2026-08-14: Resolved the public-Codable review conflict by making the
  lossless `GatewayJSONCodec` contract explicit for every value containing
  provider-defined `JSONValue`; Foundation's generic encoder/decoder cannot
  preserve arbitrary numeric lexemes. Removed misleading `Codable` conformances
  from those values and added result/error exact-number codec tests.
- 2026-08-14: Addressed every high- and medium-severity finding from independent
  Riela review session `google-service-gateway-implementation-review-session-2`.
  Transport-thrown typed errors and every provider string are token-scrubbed;
  returned page tokens, operation object roots, and duplicate JSON keys are
  validated; the accepted-plan matrix now has 40 deterministic tests; release
  defaults and renderer interpolation are hardened; and Riela runtime/temporary
  state is ignored without deleting local data. Verification passed `swift
  test`, `swift build`, both executables' help/version and non-network error
  envelopes, `bash -n`, Formula/Cask build and renderer dry runs, adversarial
  version/URL/SHA rejection, rendered Ruby syntax, tracked plus untracked text
  whitespace checks, and the 1000-line Swift limit. Direct SwiftLint remains
  unavailable, and the project-managed invocation remains blocked because
  `mise.toml` is untrusted; trust state was not changed. The low-severity
  gitleaks permission finding was intentionally left unchanged, and no live
  Google call, credential use, signed/notarized build, publish, commit, or push
  was performed.
