#!/usr/bin/env bash
# sync-sessions.sh — sync Claude Code session transcripts through a
# cloud-synced folder (Google Drive), keyed by the stable project slug.
#
# Usage:
#   sync-sessions.sh push [options]   # Stop hook: local  -> Drive
#   sync-sessions.sh pull [options]   # SessionStart hook: Drive -> local
#
# Options (all optional; in hook mode they come from the stdin JSON):
#   --cwd DIR             project directory (default: stdin .cwd, else $PWD)
#   --session-id ID       current session id (never overwritten by pull)
#   --transcript PATH     current transcript path (its dirname is the local
#                         Claude project folder — the most reliable source)
#   --foreground          do the work now instead of detaching
#
# Contract (same as the other hooks): never block, never fail loudly, always
# exit 0. Silent no-op if CLAUDE_SESSIONS_DIR is unset or does not exist.
# Never deletes anything at the destination. See docs/ARCHITECTURE.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${HOME}/.claude-memory}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-${HOME}/.claude/projects}"
LOCAL_ENV_FILE="${CLAUDE_MEMORY_LOCAL_ENV:-${CLAUDE_MEMORY_DIR}/config/local.env}"
LOG_FILE="${CLAUDE_SESSION_SYNC_LOG:-/tmp/claude-memory-sync-sessions.log}"
LOCK_ROOT="${TMPDIR:-/tmp}"
LOCK_STALE_SECONDS=900
LOCK_WAIT_SECONDS="${CLAUDE_SESSION_SYNC_LOCK_WAIT:-60}"
HOST_NAME="$(hostname 2>/dev/null | cut -d. -f1)"
HOST_NAME="${HOST_NAME:-unknown-host}"

log() {
  printf '%s [sync-sessions.sh] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"${LOG_FILE}" 2>/dev/null || true
}

rotate_log() {
  local size
  size="$(file_size "${LOG_FILE}")"
  if [[ "${size}" -gt 1048576 ]]; then
    mv -f "${LOG_FILE}" "${LOG_FILE}.1" 2>/dev/null || true
  fi
}

file_size() {
  [[ -f "$1" ]] || { echo 0; return; }
  stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || wc -c <"$1" | tr -d ' '
}

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# --- args -----------------------------------------------------------------
MODE="${1:-}"
case "${MODE}" in
  push|pull) shift ;;
  *) log "invalid mode '${MODE}' (expected push|pull)"; exit 0 ;;
esac

ARG_CWD=""
ARG_SESSION_ID=""
ARG_TRANSCRIPT=""
FOREGROUND="${CLAUDE_SESSION_SYNC_FOREGROUND:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) ARG_CWD="${2:-}"; shift 2 || shift ;;
    --session-id) ARG_SESSION_ID="${2:-}"; shift 2 || shift ;;
    --transcript) ARG_TRANSCRIPT="${2:-}"; shift 2 || shift ;;
    --foreground) FOREGROUND=1; shift ;;
    *) shift ;;
  esac
done

# --- config: env var wins, else per-machine local.env (parsed, never sourced)
read_local_env_value() {
  local key="$1" line value
  [[ -f "${LOCAL_ENV_FILE}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "${LOCAL_ENV_FILE}" 2>/dev/null | tail -n 1 || true)"
  [[ -n "${line}" ]] || return 0
  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  case "${value}" in
    "~") value="${HOME}" ;;
    "~/"*) value="${HOME}/${value#\~/}" ;;
  esac
  printf '%s' "${value}"
}

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-}"
if [[ -z "${SESSIONS_DIR}" ]]; then
  SESSIONS_DIR="$(read_local_env_value CLAUDE_SESSIONS_DIR)"
fi

if [[ -z "${SESSIONS_DIR}" ]]; then
  exit 0
fi
if [[ ! -d "${SESSIONS_DIR}" ]]; then
  log "CLAUDE_SESSIONS_DIR '${SESSIONS_DIR}' does not exist (Drive not mounted?), skipping ${MODE}"
  exit 0
fi

# --- hook payload (stdin JSON) ----------------------------------------------
# Prints cwd, session_id, transcript_path — one per line, empty if absent.
parse_payload() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r '(.cwd // ""), (.session_id // ""), (.transcript_path // "")' 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for k in ("cwd", "session_id", "transcript_path"):
        v = d.get(k)
        print(v if isinstance(v, str) else "")
except Exception:
    pass
' 2>/dev/null || true
  fi
}

INPUT=""
if [[ ! -t 0 ]]; then
  INPUT="$(cat 2>/dev/null || true)"
fi

CWD="${ARG_CWD}"
SESSION_ID="${ARG_SESSION_ID}"
TRANSCRIPT="${ARG_TRANSCRIPT}"
if [[ -n "${INPUT}" ]]; then
  P_CWD="" P_SID="" P_TRANSCRIPT=""
  { IFS= read -r P_CWD; IFS= read -r P_SID; IFS= read -r P_TRANSCRIPT; } < <(parse_payload "${INPUT}") || true
  [[ -n "${CWD}" ]] || CWD="${P_CWD}"
  [[ -n "${SESSION_ID}" ]] || SESSION_ID="${P_SID}"
  [[ -n "${TRANSCRIPT}" ]] || TRANSCRIPT="${P_TRANSCRIPT}"
fi
[[ -n "${CWD}" ]] || CWD="$(pwd)"

# Detach so the hook returns immediately. stdin was already consumed above,
# so the background worker receives everything as explicit arguments (a
# plain `cmd &` in the hook command would get /dev/null as stdin).
if [[ "${FOREGROUND}" != "1" ]]; then
  nohup "${SCRIPT_PATH}" "${MODE}" --foreground \
    --cwd "${CWD}" --session-id "${SESSION_ID}" --transcript "${TRANSCRIPT}" \
    </dev/null >>"${LOG_FILE}" 2>&1 &
  disown 2>/dev/null || true
  exit 0
fi

rotate_log

# --- local Claude project folder ----------------------------------------------
# Claude Code stores transcripts in ~/.claude/projects/<encoded cwd>/, where
# the encoding replaces every non-[A-Za-z0-9] character with "-" (so
# /Users/a/dev/x -> -Users-a-dev-x and D:\dow\X -> D--dow-X). Names longer
# than 200 chars are truncated and suffixed with a hash we cannot reproduce,
# so we prefer dirname(transcript_path) and only fall back to the encoding.
encode_project_dir_name() {
  if command -v python3 >/dev/null 2>&1; then
    # Count UTF-16 code units like the JS implementation does.
    python3 -c '
import sys
out = []
for ch in sys.argv[1]:
    if ch.isascii() and ch.isalnum():
        out.append(ch)
    else:
        out.append("-" * (2 if ord(ch) > 0xFFFF else 1))
print("".join(out), end="")
' "$1"
  else
    printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'
  fi
}

LOCAL_DIR=""
if [[ -n "${TRANSCRIPT}" ]]; then
  LOCAL_DIR="$(dirname "${TRANSCRIPT}")"
else
  ENCODED="$(encode_project_dir_name "${CWD}")"
  if [[ "${#ENCODED}" -le 200 ]]; then
    LOCAL_DIR="${CLAUDE_PROJECTS_DIR}/${ENCODED}"
  else
    PREFIX="${ENCODED:0:200}"
    MATCHES=()
    for candidate in "${CLAUDE_PROJECTS_DIR}/${PREFIX}"*; do
      [[ -d "${candidate}" ]] && MATCHES+=("${candidate}")
    done
    if [[ "${#MATCHES[@]}" -eq 1 ]]; then
      LOCAL_DIR="${MATCHES[0]}"
    else
      log "cannot resolve long project dir for '${CWD}' (${#MATCHES[@]} candidates), skipping"
      exit 0
    fi
  fi
fi

if ! CANONICAL_PATH="$(cd "${CWD}" 2>/dev/null && pwd -P)"; then
  log "cannot resolve cwd '${CWD}', skipping ${MODE}"
  exit 0
fi

SLUG="$("${SCRIPT_DIR}/slug.sh" "${CANONICAL_PATH}" 2>/dev/null || true)"
if [[ -z "${SLUG}" ]]; then
  log "could not derive slug for ${CANONICAL_PATH}, skipping ${MODE}"
  exit 0
fi

REMOTE_DIR="${SESSIONS_DIR}/${SLUG}"

# --- per-slug lock (local, never on the Drive) ----------------------------
LOCK_DIR="${LOCK_ROOT%/}/claude-session-sync-${SLUG}.lock"
# We already run detached, so wait a bit for a concurrent run instead of
# skipping: otherwise the push after a session's last turn could be lost.
acquire_lock() {
  local attempt=0 mtime age
  while [[ "${attempt}" -lt "${LOCK_WAIT_SECONDS}" ]]; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      return 0
    fi
    mtime="$(file_mtime "${LOCK_DIR}")"
    if [[ "${mtime}" -gt 0 ]]; then
      age=$(( $(date +%s) - mtime ))
      if [[ "${age}" -gt "${LOCK_STALE_SECONDS}" ]]; then
        log "removing stale lock ${LOCK_DIR} (age ${age}s)"
        rmdir "${LOCK_DIR}" 2>/dev/null || true
        attempt=$((attempt + 1))
        continue
      fi
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

if ! acquire_lock; then
  log "${MODE} for ${SLUG}: lock busy for ${LOCK_WAIT_SECONDS}s, skipping"
  exit 0
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

# --- copy primitives -----------------------------------------------------------
# Atomic: copy to a hidden temp file in the destination dir, then rename.
atomic_copy() {
  local src="$1" dst="$2" dst_dir tmp
  dst_dir="$(dirname "${dst}")"
  mkdir -p "${dst_dir}" 2>/dev/null || return 1
  tmp="${dst_dir}/.$(basename "${dst}").sync-tmp.$$"
  if cp -p "${src}" "${tmp}" 2>/dev/null && mv -f "${tmp}" "${dst}" 2>/dev/null; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null || true
  return 1
}

# True if file $1 is a byte-prefix of file $2 (sizes already known).
# (macOS `cmp -n` is unreliable, hence head -c.)
is_prefix_of() {
  local small="$1" big="$2" small_size="$3"
  head -c "${small_size}" "${big}" 2>/dev/null | cmp -s - "${small}"
}

COPIED=0
CONFLICTS=0

# Decide and perform one file sync. Transcripts are append-only, so a
# destination that is a strict prefix of the source is a safe fast-forward;
# anything else is either "destination ahead" (skip) or divergence.
sync_file() {
  local src="$1" dst="$2" rel="$3" src_size dst_size
  if [[ ! -e "${dst}" ]]; then
    atomic_copy "${src}" "${dst}" && COPIED=$((COPIED + 1)) || log "copy failed: ${rel}"
    return 0
  fi
  src_size="$(file_size "${src}")"
  dst_size="$(file_size "${dst}")"

  if [[ "${rel}" == *.jsonl ]]; then
    if [[ "${src_size}" -eq "${dst_size}" ]]; then
      return 0
    fi
    if [[ "${src_size}" -gt "${dst_size}" ]]; then
      if is_prefix_of "${dst}" "${src}" "${dst_size}"; then
        atomic_copy "${src}" "${dst}" && COPIED=$((COPIED + 1)) || log "copy failed: ${rel}"
      else
        handle_conflict "${src}" "${rel}"
      fi
      return 0
    fi
    # src smaller: destination ahead (fine) or diverged.
    if ! is_prefix_of "${src}" "${dst}" "${src_size}"; then
      handle_conflict "${src}" "${rel}"
    fi
    return 0
  fi

  # Non-transcript files (tool-results, metadata): copy if content differs
  # and the source is newer.
  if [[ "${src_size}" -eq "${dst_size}" ]] && cmp -s "${src}" "${dst}"; then
    return 0
  fi
  if [[ "$(file_mtime "${src}")" -gt "$(file_mtime "${dst}")" ]]; then
    atomic_copy "${src}" "${dst}" && COPIED=$((COPIED + 1)) || log "copy failed: ${rel}"
  fi
}

# push: keep the divergent local copy in the Drive under
# _conflicts/<host>/ so nothing is lost. One snapshot per host and file,
# refreshed only when its size changes (Stop fires every turn; a timestamped
# copy per turn would flood the Drive). pull: leave local untouched, log.
handle_conflict() {
  local src="$1" rel="$2"
  CONFLICTS=$((CONFLICTS + 1))
  if [[ "${MODE}" == "push" ]]; then
    local conflict_dst="${REMOTE_DIR}/_conflicts/${HOST_NAME}/${rel}"
    if [[ "$(file_size "${src}")" -ne "$(file_size "${conflict_dst}")" ]]; then
      atomic_copy "${src}" "${conflict_dst}" || true
    fi
    log "CONFLICT ${SLUG}/${rel}: local and Drive diverged; local copy kept at ${conflict_dst}"
  else
    log "CONFLICT ${SLUG}/${rel}: Drive and local diverged; kept local copy untouched"
  fi
}

# Sync every <id>.jsonl in $1 plus its sibling <id>/ directory (subagents,
# tool-results, ...) into $2. memory/ and anything else is never touched
# (native memory is synced through git by mirror-native-memory.sh).
sync_tree() {
  local from="$1" to="$2" skip_id="$3" f id rel sub
  for f in "${from}"/*.jsonl; do
    [[ -f "${f}" ]] || continue
    id="$(basename "${f}" .jsonl)"
    if [[ -n "${skip_id}" && "${id}" == "${skip_id}" ]]; then
      continue
    fi
    sync_file "${f}" "${to}/${id}.jsonl" "${id}.jsonl"
    if [[ -d "${from}/${id}" ]]; then
      while IFS= read -r sub; do
        [[ -n "${sub}" ]] || continue
        rel="${sub#"${from}"/}"
        case "$(basename "${sub}")" in .*.sync-tmp.*) continue ;; esac
        sync_file "${sub}" "${to}/${rel}" "${rel}"
      done < <(find "${from}/${id}" -type f 2>/dev/null)
    fi
  done
}

case "${MODE}" in
  push)
    [[ -d "${LOCAL_DIR}" ]] || exit 0
    mkdir -p "${REMOTE_DIR}" 2>/dev/null || { log "cannot create ${REMOTE_DIR}"; exit 0; }
    sync_tree "${LOCAL_DIR}" "${REMOTE_DIR}" ""
    ;;
  pull)
    [[ -d "${REMOTE_DIR}" ]] || exit 0
    mkdir -p "${LOCAL_DIR}" 2>/dev/null || { log "cannot create ${LOCAL_DIR}"; exit 0; }
    sync_tree "${REMOTE_DIR}" "${LOCAL_DIR}" "${SESSION_ID}"
    ;;
esac

if [[ "${COPIED}" -gt 0 || "${CONFLICTS}" -gt 0 ]]; then
  log "${MODE} slug=${SLUG} local=${LOCAL_DIR} copied=${COPIED} conflicts=${CONFLICTS}"
fi
exit 0
