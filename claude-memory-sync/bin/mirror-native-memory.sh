#!/usr/bin/env bash
# mirror-native-memory.sh — Stop hook entry point. Mirrors Claude Code's
# NATIVE per-project memory (~/.claude/projects/<hash>/memory/*.md) into
# ~/.claude-memory so it becomes available/synced across machines, the same
# way Graphify graphs already are.
#
# Contract: this script MUST NEVER block session end and MUST NEVER fail
# loudly. Missing native memory for a project is the common case (most
# sessions never accumulate any) — that is NOT an error, just a silent no-op.
#
# cwd resolution:
#   Claude Code's Stop hook passes a JSON payload on stdin with a `.cwd`
#   field (confirmed by the existing save-to-obsidian.sh hook in this same
#   settings.json, which reads `.cwd` via jq from stdin). We read stdin the
#   same way. If stdin is empty/not JSON/jq is unavailable, we fall back to
#   $PWD as a best-effort — NOTE: this fallback is a real limitation, since
#   the Stop hook process's PWD is not guaranteed to be the session's actual
#   project directory (it depends on how Claude Code launches the hook
#   command). Prefer the stdin `.cwd` path whenever available.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${HOME}/.claude-memory}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
LOG_PREFIX="[mirror-native-memory.sh]"

log() {
  printf '%s %s\n' "${LOG_PREFIX}" "$*" >&2
}

# --- resolve cwd -------------------------------------------------------
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT="$(cat 2>/dev/null || true)"
fi

CWD=""
if [[ -n "${INPUT}" ]] && command -v jq >/dev/null 2>&1; then
  CWD="$(printf '%s' "${INPUT}" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi

if [[ -z "${CWD}" ]]; then
  # Fallback — see header note: this is a best-effort guess, not guaranteed
  # to match the actual session project directory.
  CWD="$(pwd)"
fi

if ! CANONICAL_PATH="$(cd "${CWD}" 2>/dev/null && pwd -P)"; then
  log "cannot resolve cwd '${CWD}', exiting quietly"
  exit 0
fi

# --- derive the Claude Code project-hash dir ----------------------------
# Observed pattern: /Users/foo/Proj/bar -> -Users-foo-Proj-bar
# (leading "/" also becomes "-", giving the leading dash seen in real dirs).
HASH_DIR_NAME="$(printf '%s' "${CANONICAL_PATH}" | tr '/' '-')"
if [[ "${HASH_DIR_NAME}" != -* ]]; then
  HASH_DIR_NAME="-${HASH_DIR_NAME}"
fi

NATIVE_MEMORY_DIR="${CLAUDE_PROJECTS_DIR}/${HASH_DIR_NAME}/memory"

# --- no native memory yet: silent, non-verbose exit ----------------------
if [[ ! -d "${NATIVE_MEMORY_DIR}" ]]; then
  exit 0
fi

# Empty dir also counts as "nothing to mirror".
if [[ -z "$(find "${NATIVE_MEMORY_DIR}" -mindepth 1 -print -quit 2>/dev/null || true)" ]]; then
  exit 0
fi

# --- derive slug + prepare destination -----------------------------------
SLUG="$("${SCRIPT_DIR}/slug.sh" "${CANONICAL_PATH}" 2>/dev/null || true)"
if [[ -z "${SLUG}" ]]; then
  log "could not derive slug for ${CANONICAL_PATH}, exiting quietly"
  exit 0
fi

PROJECT_DIR="${CLAUDE_MEMORY_DIR}/projects/${SLUG}"
DEST_DIR="${PROJECT_DIR}/native-memory"

mkdir -p "${DEST_DIR}" 2>/dev/null || {
  log "cannot create ${DEST_DIR}, exiting quietly"
  exit 0
}

# --- copy, never touching notes.md (which lives one level up, outside
# native-memory/, and is manual/editorial content) -------------------------
copy_native_memory() {
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude 'notes.md' "${NATIVE_MEMORY_DIR}/" "${DEST_DIR}/" 2>/dev/null
  else
    # cp -R fallback: notes.md cannot live inside NATIVE_MEMORY_DIR by
    # construction (it is a project-level file, not a native-memory file),
    # so a plain recursive copy is safe here too.
    cp -R "${NATIVE_MEMORY_DIR}/." "${DEST_DIR}/" 2>/dev/null
  fi
}

copy_native_memory || {
  log "copy from ${NATIVE_MEMORY_DIR} to ${DEST_DIR} failed, exiting quietly"
  exit 0
}

log "mirrored native memory for slug=${SLUG} (${NATIVE_MEMORY_DIR} -> ${DEST_DIR})"

# --- build the explicit file list for sync.sh (never `git add -A`) -------
SYNC_FILES=()
while IFS= read -r rel_path; do
  [[ -z "${rel_path}" ]] && continue
  SYNC_FILES+=("projects/${SLUG}/native-memory/${rel_path}")
done < <(cd "${DEST_DIR}" 2>/dev/null && find . -type f -print 2>/dev/null | sed 's#^\./##')

if [[ "${#SYNC_FILES[@]}" -eq 0 ]]; then
  exit 0
fi

# --- sync in background: never block session end -------------------------
nohup "${SCRIPT_DIR}/sync.sh" "${SLUG}" "${SYNC_FILES[@]}" \
  >/tmp/claude-memory-sync-from-mirror-native.log 2>&1 &
disown 2>/dev/null || true

exit 0
