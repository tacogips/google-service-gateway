# Patch Version Bump to 0.1.7

**Status**: Implementation Complete (pending workflow review and reconciliation)
**Plan ID**: PLAN-SC5-VERSION
**Depends On**: none (wave 1, runs in parallel with PLAN-SC5-DEPS)
**Design Reference**: `design-docs/specs/architecture.md#cryptography-dependency`

## Purpose

The swift-crypto 5.x move ships as the next patch release. By repository
convention, the version lives in exactly two places, and both must change
together (see commit `a30eb3d`, which touched only these two files for 0.1.6):

- `VERSION`: one line, currently `0.1.6`.
- `Sources/GoogleServiceGatewayCore/Version.swift`: `Version.current`,
  currently `"0.1.6"`.

All five executables print `Version.current` for `--version`, for example
`Sources/GoogleServiceGatewayReader/ReaderAdapter.swift:45`. The tests compare
against `Version.current` rather than a literal
(`Tests/GoogleServiceGatewayCoreTests/RemediationContractTests.swift:219-221`),
so no test edit is needed.

## Non-Goals

- Touching `Package.swift`, `Package.resolved`, or any source other than
  `Version.swift`. PLAN-SC5-DEPS owns the dependency files.
- Editing packaging, Homebrew formulas or casks, the README, or release
  scripts, and creating tags or releases.
- Running `swift build` or `swift test` in this plan. The sibling plan uses
  `.build` concurrently, and the full build belongs to reconciliation.

## Deliverables

- [x] `VERSION` contains exactly `0.1.7`, followed by one trailing newline as
      in the current file.
- [x] `Version.swift` line 2 reads `  public static let current = "0.1.7"`.

## Tasks

### TASK-001: Bump both version sources

**Parallelizable**: Yes, with PLAN-SC5-DEPS.

1. Read both files again, and record their `shasum -a 256` values in the
   Progress Log.
2. Change `0.1.6` to `0.1.7` in both files. Change nothing else: keep the
   indentation, the `Sendable` conformance, and the newline handling.

Pitfalls: do not bump the minor version. Do not add a build-metadata suffix.
Do not change `VERSION` without also changing `Version.swift`. Expect
changes to files outside this plan's writePaths: PLAN-SC5-DEPS edits
`Package.swift`, `Package.resolved` and `.build` concurrently, and
`design-docs/specs/architecture.md` already has an edit from earlier in the
workflow. Never revert, restore, checkout or stash those files.

**Completion Criteria**:

- [x] `cat VERSION` prints `0.1.7`.
- [x] `grep -n 'current = "0.1.7"' Sources/GoogleServiceGatewayCore/Version.swift`
      matches line 2.
- [x] `grep -rn '0\.1\.6' VERSION Sources` returns no matches.
- [x] `swiftlint lint Sources/GoogleServiceGatewayCore/Version.swift` exits 0.
- [x] `git diff --name-only -- VERSION Sources/GoogleServiceGatewayCore/Version.swift`
      lists exactly those two files. Do not use an unscoped `git diff --stat`.

## Invariants

- `VERSION` and `Version.current` stay equal.
- The `Version` enum stays a public, `Sendable` type.

## Verification

| Command | Evidence it must establish |
|---|---|
| `cat VERSION` | Prints `0.1.7`. |
| `grep -n 'current = "0.1.7"' Sources/GoogleServiceGatewayCore/Version.swift` | One match. |
| `swiftlint lint Sources/GoogleServiceGatewayCore/Version.swift` | Exit 0. |

## Progress Log

- 2026-10-27: Plan created.
- 2026-10-27: TASK-001 implemented. Pre-edit SHA-256: `VERSION` 1f2110568627307becae713f8b808f3d9d912d4b2a24ed6a78605f03f7437d3c; `Sources/GoogleServiceGatewayCore/Version.swift` 7646978d55e9415db9d55643bc1ae02b4d61e35ab6f8ddc0405bebb6c21648bf. Both now read 0.1.7; only the literal changed in Version.swift. Completion checks and selected-file SwiftLint are recorded in `tmp/sc5-swift-crypto-5-20261027/PLAN-SC5-VERSION/`. Build and test remain serial reconciliation gates per the accepted plan.
- Verification results: `cat VERSION` exit 0; version grep matched line 2, exit 0; old-version grep found no matches (expected grep exit 1); scoped changed-file listing contained exactly `VERSION` and `Sources/GoogleServiceGatewayCore/Version.swift`, exit 0; exact-byte/newline check exit 0. Logs: `verify-cat.log`, `verify-version-grep.log`, `verify-old-version-grep.log`, `verify-diff-files.log`, `verify-version-bytes-rerun.log` in the plan evidence directory.
- `swiftlint lint Sources/GoogleServiceGatewayCore/Version.swift` exit 0 (`verify-swiftlint.log`). Strict selected-file command `xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/sc5-swift-crypto-5-20261027/PLAN-SC5-VERSION/changed-swift-files.nul` exit 0 (`verify-strict-swiftlint.log`). An initial extra byte-check attempt used a malformed newline assertion and exited 1; the corrected byte check passed (`verify-version-bytes.log`, `verify-version-bytes-rerun.log`). No source change was needed.
