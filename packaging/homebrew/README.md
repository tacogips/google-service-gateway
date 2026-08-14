# Homebrew Packaging

This project ships two Homebrew release paths:

- Formula: unsigned tarballs containing `bin/google-service-gateway-reader` and
  `bin/google-service-gateway-writer`.
- Cask: signed, notarized, and stapled macOS DMGs containing both command line
  gateways.

Swift formula archives are macOS-only by default. Add Linux archives only after
the project has a reviewed Swift Linux build and runtime contract.

## Formula

Build release archives:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
```

The command writes archives and checksums under `dist/homebrew/`:

```text
dist/homebrew/google-service-gateway-<version>-darwin-arm64.tar.gz
dist/homebrew/google-service-gateway-<version>-darwin-arm64.tar.gz.sha256
dist/homebrew/google-service-gateway-<version>-darwin-x64.tar.gz
dist/homebrew/google-service-gateway-<version>-darwin-x64.tar.gz.sha256
```

Publish those assets to the GitHub release named `v<version>`, then render the
formula into a tap checkout:

```bash
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula/google-service-gateway.rb
```

The renderer defaults to releases from `tacogips/google-service-gateway` and
validates every Ruby-interpolated version, URL, checksum, and product token.
Pass `--dry-run` before the version to emit validated Ruby without writing an
output file.

## Cask

Build signed and notarized DMGs on macOS:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64
```

This writes:

```text
dist/homebrew-cask/google-service-gateway-<version>-darwin-arm64.dmg
dist/homebrew-cask/google-service-gateway-<version>-darwin-arm64.dmg.sha256
dist/homebrew-cask/google-service-gateway-<version>-darwin-x64.dmg
dist/homebrew-cask/google-service-gateway-<version>-darwin-x64.dmg.sha256
```

Render the Cask:

```bash
scripts/render-homebrew-cask.sh <version> ../homebrew-tap/Casks/google-service-gateway.rb
```

The Cask renderer applies the same interpolation validation and supports the
same non-writing `--dry-run` mode.

For a tagged release, the local wrapper verifies the tag, builds DMGs, uploads
release assets, and renders the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  scripts/release-homebrew-cask-local.sh v<version>
```

## Verification

From the tap checkout:

```bash
ruby -c Formula/google-service-gateway.rb
brew audit --strict google-service-gateway || brew audit --strict --formula google-service-gateway
brew fetch --cask user/tap/google-service-gateway
HOMEBREW_NO_GITHUB_API=1 brew audit --cask user/tap/google-service-gateway
```

If online audit fails due local GitHub credentials or rate limits, run the
non-online audit and record the limitation.
