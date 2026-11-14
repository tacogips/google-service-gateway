#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="google-service-gateway"
reader_product="google-service-gateway-reader"
writer_product="google-service-gateway-writer"
admin_product="google-service-gateway-admin"
deleter_product="google-service-gateway-deleter"
auth_product="google-service-gateway-auth"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-cask.sh [--dry-run] <version> [output-file]

Reads archive checksums from:
  dist/homebrew-cask/$artifact_name-<version>-<target>.dmg.sha256

Environment:
  CASK_RELEASE_DIR       Directory containing archives and .sha256 files.
  CASK_RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Example:
  scripts/build-homebrew-cask-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-cask.sh 0.1.0 ../homebrew-tap/Casks/$artifact_name.rb

This renderer expects signed, notarized, and stapled macOS .dmg artifacts.
EOF
}

validate_version() {
  local version="$1"
  if [[ "$version" == *..* || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe cask version: %s\n' "$version" >&2
    return 1
  fi
}

validate_release_base_url() {
  local value="$1"
  if [[ ! "$value" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~:/?\&=%+,@-]*)?$ ]]; then
    printf 'unsafe cask release URL: %s\n' "$value" >&2
    return 1
  fi
}

validate_sha256() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    printf 'unsafe cask SHA-256: %s\n' "$value" >&2
    return 1
  fi
}

validate_ruby_token() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printf 'unsafe cask %s: %s\n' "$label" "$value" >&2
    return 1
  fi
}

sha_for_target() {
  local version target release_dir sha_file
  version="$1"
  target="$2"
  release_dir="$3"
  sha_file="$release_dir/$artifact_name-$version-$target.dmg.sha256"

  if [[ ! -f "$sha_file" ]]; then
    printf 'missing checksum file: %s\n' "$sha_file" >&2
    return 1
  fi

  local sha
  sha="$(awk 'NR == 1 { print $1 }' "$sha_file")"
  validate_sha256 "$sha" || return 1
  printf '%s\n' "$sha"
}

render() {
  local version="$1" release_base_url="$2" darwin_arm64_sha="$3" darwin_x64_sha="$4"
  cat <<EOF
cask "google-service-gateway" do
  version "$version"
  arch arm: "darwin-arm64", intel: "darwin-x64"

  sha256 arm: "$darwin_arm64_sha",
         intel: "$darwin_x64_sha"

  url "$release_base_url/$artifact_name-#{version}-#{arch}.dmg",
      verified: "github.com/tacogips/google-service-gateway/releases/download/"
  name "google-service-gateway"
  desc "Google Service Usage, Cloud Billing, API-key, and OAuth command-line gateways"
  homepage "https://github.com/tacogips/google-service-gateway"

  livecheck do
    url :url
    strategy :github_latest
  end

  binary "$reader_product"
  binary "$writer_product"
  binary "$admin_product"
  binary "$deleter_product"
  binary "$auth_product"

  caveats do
    <<~EOS
      This cask installs the signed and notarized macOS command line tool.
      Homebrew links all five gateway executables into the native Homebrew prefix.
    EOS
  end
end
EOF
}

main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    return
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local dry_run=false
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
    shift
  fi
  if [[ "${1:-}" == "" ]]; then
    usage
    return 2
  fi

  local version output release_dir release_base_url
  version="$1"
  output="${2:-$repo_root/Casks/$artifact_name.rb}"
  release_dir="${CASK_RELEASE_DIR:-$repo_root/dist/homebrew-cask}"
  release_base_url="${CASK_RELEASE_BASE_URL:-https://github.com/tacogips/google-service-gateway/releases/download/v$version}"

  validate_version "$version"
  validate_release_base_url "$release_base_url"
  validate_ruby_token artifact-name "$artifact_name"
  validate_ruby_token reader-product "$reader_product"
  validate_ruby_token writer-product "$writer_product"
  validate_ruby_token admin-product "$admin_product"
  validate_ruby_token deleter-product "$deleter_product"
  validate_ruby_token auth-product "$auth_product"

  local darwin_arm64_sha darwin_x64_sha
  darwin_arm64_sha="$(sha_for_target "$version" darwin-arm64 "$release_dir")"
  darwin_x64_sha="$(sha_for_target "$version" darwin-x64 "$release_dir")"

  if [[ "$dry_run" == true ]]; then
    render "$version" "$release_base_url" "$darwin_arm64_sha" "$darwin_x64_sha"
    return
  fi

  mkdir -p "$(dirname "$output")"
  render "$version" "$release_base_url" "$darwin_arm64_sha" "$darwin_x64_sha" > "$output"

  printf 'rendered %s\n' "$output"
}

main "$@"
