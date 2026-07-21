#!/usr/bin/env bash
# sync.sh — pull-rebase, stage only touched files by explicit name, commit, push
# with bounded retry-on-reject. Designed to be called from detect-and-map.sh
# (or manually) and to NEVER hang or hard-crash the calling process.
#
# Usage: sync.sh <slug> [file1 file2 ...]
#   - <slug> is used for the commit message and, when no explicit files are
#     given, to scope `git status --porcelain` to projects/<slug>/ and index/.
#   - Any additional args are treated as explicit repo-relative file paths to
#     stage (never a bare `-A`/`.`).
set -euo pipefail

CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${HOME}/.claude-memory}"
MAX_PUSH_ATTEMPTS=3

log() {
  printf '[sync.sh] %s\n' "$*" >&2
}

if [[ $# -lt 1 ]]; then
  log "usage: sync.sh <slug> [file ...]"
  exit 0
fi

SLUG="$1"
shift || true
EXPLICIT_FILES=("$@")

if [[ ! -d "${CLAUDE_MEMORY_DIR}/.git" ]]; then
  log "no git repo at ${CLAUDE_MEMORY_DIR}, skipping sync"
  exit 0
fi

cd "${CLAUDE_MEMORY_DIR}"

if ! git pull --rebase --autostash 2>/tmp/claude-memory-sync-pull.err; then
  log "git pull --rebase --autostash failed, continuing to attempt local commit only: $(cat /tmp/claude-memory-sync-pull.err 2>/dev/null || true)"
fi

FILES_TO_ADD=()
if [[ "${#EXPLICIT_FILES[@]}" -gt 0 ]]; then
  FILES_TO_ADD=("${EXPLICIT_FILES[@]}")
else
  while IFS= read -r porcelain_line; do
    [[ -z "${porcelain_line}" ]] && continue
    # porcelain format: "XY path" — path starts at column 4.
    rel_path="${porcelain_line:3}"
    case "${rel_path}" in
      "projects/${SLUG}/"*|"index/"*)
        FILES_TO_ADD+=("${rel_path}")
        ;;
    esac
  done < <(git status --porcelain)
fi

if [[ "${#FILES_TO_ADD[@]}" -eq 0 ]]; then
  log "nothing to stage for slug=${SLUG}"
  exit 0
fi

for f in "${FILES_TO_ADD[@]}"; do
  if [[ -e "${f}" ]]; then
    git add -- "${f}"
  fi
done

if git diff --cached --quiet; then
  log "nothing staged after filtering, skipping commit"
  exit 0
fi

HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown-host)"
TIMESTAMP_VALUE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

git commit -m "map: ${SLUG} @ ${HOSTNAME_VALUE} ${TIMESTAMP_VALUE}"

attempt=1
delay=2
while [[ "${attempt}" -le "${MAX_PUSH_ATTEMPTS}" ]]; do
  if git push 2>/tmp/claude-memory-sync-push.err; then
    log "push succeeded on attempt ${attempt}"
    exit 0
  fi

  log "push attempt ${attempt} failed: $(cat /tmp/claude-memory-sync-push.err 2>/dev/null || true)"

  if [[ "${attempt}" -eq "${MAX_PUSH_ATTEMPTS}" ]]; then
    log "giving up after ${MAX_PUSH_ATTEMPTS} attempts, local commit preserved"
    exit 0
  fi

  sleep "${delay}"
  delay=$((delay * 2))

  if ! git pull --rebase --autostash 2>/tmp/claude-memory-sync-pull.err; then
    log "retry pull --rebase failed: $(cat /tmp/claude-memory-sync-pull.err 2>/dev/null || true)"
  fi

  attempt=$((attempt + 1))
done
