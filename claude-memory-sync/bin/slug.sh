#!/usr/bin/env bash
# slug.sh — derive a stable, cross-machine project slug for a given directory.
#
# Usage: slug.sh [path]        (defaults to current directory)
# Stdout: the slug (single line, no trailing data)
#
# Rules (see docs/ARCHITECTURE.md):
#   1. If the dir is inside a git repo with an `origin` remote, slug is
#      derived from that remote: host/owner/repo, lowercased, "/" -> "_".
#   2. Otherwise: local_<folder-name>_<hash8-of-canonical-path>, and the
#      caller is expected to mark meta.json with "local-only": true.
set -euo pipefail

TARGET_DIR="${1:-$(pwd)}"

if ! command -v realpath >/dev/null 2>&1; then
  # macOS ships realpath via coreutils sometimes missing; fall back to python3.
  realpath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
fi

CANONICAL_PATH="$(realpath "${TARGET_DIR}")"

derive_from_remote() {
  local remote_url="$1"
  local normalized="${remote_url}"

  # git@host:owner/repo.git -> host/owner/repo
  if [[ "${normalized}" =~ ^git@([^:]+):(.+)$ ]]; then
    normalized="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  # ssh://git@host/owner/repo.git -> host/owner/repo
  normalized="${normalized#ssh://git@}"
  normalized="${normalized#ssh://}"

  # https://host/owner/repo.git -> host/owner/repo
  normalized="${normalized#https://}"
  normalized="${normalized#http://}"

  # Strip trailing .git
  normalized="${normalized%.git}"
  # Strip trailing slash
  normalized="${normalized%/}"

  # Lowercase, then replace "/" with "_"
  normalized="$(printf '%s' "${normalized}" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "${normalized}" | tr '/' '_'
}

main() {
  local git_dir=""
  if git_dir="$(cd "${CANONICAL_PATH}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
    local remote_url=""
    remote_url="$(cd "${git_dir}" && git remote get-url origin 2>/dev/null || true)"
    if [[ -n "${remote_url}" ]]; then
      derive_from_remote "${remote_url}"
      return 0
    fi
  fi

  # No git remote: local-only slug.
  local folder_name
  folder_name="$(basename "${CANONICAL_PATH}")"
  local hash8
  hash8="$(printf '%s' "${CANONICAL_PATH}" | shasum -a 256 2>/dev/null | cut -c1-8 || true)"
  if [[ -z "${hash8}" ]]; then
    hash8="$(printf '%s' "${CANONICAL_PATH}" | sha256sum | cut -c1-8)"
  fi
  printf 'local_%s_%s' "${folder_name}" "${hash8}"
}

main
