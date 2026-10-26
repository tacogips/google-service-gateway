# Patch Version Bump to 0.1.7

**Status**: In Progress
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

- [ ] `VERSION` contains exactly `0.1.7`, followed by one trailing newline as
      in the current file.
- [ ] `Version.swift` line 2 reads `  public static let current = "0.1.7"`.

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

- [ ] `cat VERSION` prints `0.1.7`.
- [ ] `grep -n 'current = "0.1.7"' Sources/GoogleServiceGatewayCore/Version.swift`
      matches line 2.
- [ ] `grep -rn '0\.1\.6' VERSION Sources` returns no matches.
- [ ] `swiftlint lint Sources/GoogleServiceGatewayCore/Version.swift` exits 0.
- [ ] `git diff --name-only -- VERSION Sources/GoogleServiceGatewayCore/Version.swift`
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
