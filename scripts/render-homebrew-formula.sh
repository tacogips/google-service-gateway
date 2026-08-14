#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
artifact_name="google-service-gateway"
reader_product="google-service-gateway-reader"
writer_product="google-service-gateway-writer"

usage() {
  cat <<EOF
Usage:
  scripts/render-homebrew-formula.sh [--dry-run] <version> [output-file]

Reads archive checksums from:
  dist/homebrew/$artifact_name-<version>-<target>.tar.gz.sha256

Environment:
  RELEASE_DIR       Directory containing archives and .sha256 files.
  RELEASE_BASE_URL  Release URL base. Defaults to GitHub v<version>.

Example:
  scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
  scripts/render-homebrew-formula.sh 0.1.0 Formula/$artifact_name.rb

This renderer expects Swift macOS release archives. Linux archives are
unsupported until the project defines a reviewed Swift Linux build contract.
EOF
}

validate_version() {
  local version="$1"
  if [[ "$version" == *..* || ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z][0-9A-Za-z.+-]*)?$ ]]; then
    printf 'unsafe formula version: %s\n' "$version" >&2
    return 1
  fi
}

validate_release_base_url() {
  local value="$1"
  if [[ ! "$value" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~:/?\&=%+,@-]*)?$ ]]; then
    printf 'unsafe formula release URL: %s\n' "$value" >&2
    return 1
  fi
}

validate_sha256() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    printf 'unsafe formula SHA-256: %s\n' "$value" >&2
    return 1
  fi
}

validate_ruby_token() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    printf 'unsafe formula %s: %s\n' "$label" "$value" >&2
    return 1
  fi
}

sha_for_target() {
  local version target release_dir sha_file
  version="$1"
  target="$2"
  release_dir="$3"
  sha_file="$release_dir/$artifact_name-$version-$target.tar.gz.sha256"

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
class GoogleServiceGateway < Formula
  desc "Google Service Usage reader and writer command-line gateways"
  homepage "https://github.com/tacogips/google-service-gateway"
  license "MIT"

  livecheck do
    url :stable
    strategy :github_latest
  end

  on_macos do
    if Hardware::CPU.arm?
      url "$release_base_url/$artifact_name-$version-darwin-arm64.tar.gz", tag: "v$version"
      sha256 "$darwin_arm64_sha"
    else
      url "$release_base_url/$artifact_name-$version-darwin-x64.tar.gz", tag: "v$version"
      sha256 "$darwin_x64_sha"
    end
  end

  def install
    bin.install "bin/$reader_product"
    bin.install "bin/$writer_product"
  end

  test do
    assert_match "$version", shell_output("#{bin}/$reader_product --version")
    assert_match "$version", shell_output("#{bin}/$writer_product --version")
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
  output="${2:-$repo_root/Formula/$artifact_name.rb}"
  release_dir="${RELEASE_DIR:-$repo_root/dist/homebrew}"
  release_base_url="${RELEASE_BASE_URL:-https://github.com/tacogips/google-service-gateway/releases/download/v$version}"

  validate_version "$version"
  validate_release_base_url "$release_base_url"
  validate_ruby_token artifact-name "$artifact_name"
  validate_ruby_token reader-product "$reader_product"
  validate_ruby_token writer-product "$writer_product"

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
