#!/usr/bin/env bash
# detect-and-map.sh — SessionStart hook entry point. Maps the current project
# into ~/.claude-memory via `graphify`, then syncs the memory repo.
#
# Contract: this script MUST NEVER block the Claude Code session and MUST
# NEVER fail loudly. Any missing prerequisite or transient error is logged
# and swallowed; the worst outcome is "nothing happened this time".
set -uo pipefail
# Note: intentionally NOT using `set -e` at the top level — this script
# handles its own errors per-step so a single failure can't abort the whole
# flow before the lock is released. Individual helper invocations still rely
# on their own internal `set -e` where isolated in subshells.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${HOME}/.claude-memory}"
LOG_PREFIX="[detect-and-map.sh]"

log() {
  printf '%s %s\n' "${LOG_PREFIX}" "$*" >&2
}

# Resolve cwd -> canonical path.
TARGET_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if ! CANONICAL_PATH="$(cd "${TARGET_DIR}" 2>/dev/null && pwd -P)"; then
  log "cannot resolve project directory '${TARGET_DIR}', exiting quietly"
  exit 0
fi

SLUG="$("${SCRIPT_DIR}/slug.sh" "${CANONICAL_PATH}" 2>/dev/null || true)"
if [[ -z "${SLUG}" ]]; then
  log "could not derive slug for ${CANONICAL_PATH}, exiting quietly"
  exit 0
fi

PROJECTS_INDEX="${CLAUDE_MEMORY_DIR}/index/projects.json"
PROJECT_DIR="${CLAUDE_MEMORY_DIR}/projects/${SLUG}"
LOCK_FILE="${PROJECT_DIR}/.lock"
# Short-lived, granular lock protecting only the shared index/projects.json
# read-modify-write. Distinct from (and narrower than) the per-slug lock
# above: this one is held only for the duration of a single index update,
# never across the graphify call, so concurrent sessions for DIFFERENT
# projects never wait on each other for long.
INDEX_LOCK_DIR="${CLAUDE_MEMORY_DIR}/index/.index.lock"

# Attempts an atomic mkdir-based lock on ${INDEX_LOCK_DIR} (mkdir is atomic
# on all POSIX filesystems we target — same primitive as the per-slug
# mkdir-lock fallback below). Retries a few times with a short sleep since
# contention here should be rare and brief; on failure, returns 1 and the
# caller is expected to skip the index update rather than block the session.
acquire_index_lock() {
  mkdir -p "$(dirname "${INDEX_LOCK_DIR}")" 2>/dev/null || true
  local attempt=0
  while [[ ${attempt} -lt 5 ]]; do
    if mkdir "${INDEX_LOCK_DIR}" 2>/dev/null; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.15
  done
  return 1
}

release_index_lock() {
  rmdir "${INDEX_LOCK_DIR}" 2>/dev/null || true
}

# --- current content hash (git HEAD, else aggregate mtime hash) -----------
compute_content_hash() {
  local dir="$1"
  local git_head=""
  if git_head="$(cd "${dir}" 2>/dev/null && git rev-parse HEAD 2>/dev/null)"; then
    printf 'git:%s' "${git_head}"
    return 0
  fi

  # No git repo (or no commits yet): aggregate mtimes of tracked-ish files.
  # Best-effort, bounded depth to avoid scanning huge trees.
  local aggregate
  aggregate="$(find "${dir}" -maxdepth 6 -type f -not -path '*/.git/*' -print0 2>/dev/null \
    | xargs -0 stat -f '%m %N' 2>/dev/null \
    | sort \
    | shasum -a 256 2>/dev/null | cut -c1-16)"
  if [[ -z "${aggregate}" ]]; then
    aggregate="unknown"
  fi
  printf 'mtime:%s' "${aggregate}"
}

CURRENT_HASH="$(compute_content_hash "${CANONICAL_PATH}")"

# --- fast path: already mapped at this hash? -------------------------------
# Uses python3 if present (it is the standard prerequisite for this whole
# toolkit); if python3 is unavailable even for this read-only check, we fall
# through to the full flow, and the prerequisite check below will record a
# "pending" status and exit cleanly.
if command -v python3 >/dev/null 2>&1 && [[ -f "${PROJECTS_INDEX}" ]]; then
  ALREADY_CURRENT="$(python3 - "${PROJECTS_INDEX}" "${SLUG}" "${CURRENT_HASH}" <<'PYEOF' 2>/dev/null || true
import json
import sys

index_path, slug, current_hash = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(index_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    print("no")
    sys.exit(0)

for project in data.get("projects", []):
    if project.get("slug") == slug:
        if project.get("last_content_hash") == current_hash and project.get("status") == "mapped":
            print("yes")
            sys.exit(0)
        break
print("no")
PYEOF
)"
  if [[ "${ALREADY_CURRENT}" == "yes" ]]; then
    log "slug=${SLUG} already mapped at current hash, nothing to do"
    exit 0
  fi
fi

# --- per-slug non-blocking lock --------------------------------------------
mkdir -p "${PROJECT_DIR}" 2>/dev/null || true

exec 9>"${LOCK_FILE}" || { log "cannot open lock file ${LOCK_FILE}, exiting quietly"; exit 0; }
if ! flock -n 9 2>/dev/null; then
  # flock may be unavailable (macOS has no flock by default); fall back to a
  # simple mkdir-based lock in that case.
  if command -v flock >/dev/null 2>&1; then
    log "slug=${SLUG} already locked by another process, exiting immediately"
    exit 0
  fi
fi

MKDIR_LOCK_USED=0
if ! command -v flock >/dev/null 2>&1; then
  exec 9>&- 2>/dev/null || true
  if ! mkdir "${LOCK_FILE}.d" 2>/dev/null; then
    log "slug=${SLUG} already locked (mkdir-lock) by another process, exiting immediately"
    exit 0
  fi
  MKDIR_LOCK_USED=1
fi

cleanup_lock() {
  if [[ "${MKDIR_LOCK_USED}" -eq 1 ]]; then
    rmdir "${LOCK_FILE}.d" 2>/dev/null || true
  else
    exec 9>&- 2>/dev/null || true
    rm -f "${LOCK_FILE}" 2>/dev/null || true
  fi
}
trap cleanup_lock EXIT INT TERM

# --- prerequisite checks ----------------------------------------------------
write_pending_status() {
  local reason="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    log "pending: ${reason} (and python3 unavailable to persist status)"
    return 0
  fi
  if ! acquire_index_lock; then
    log "could not acquire index lock after retries, skipping pending-status index update this time"
    return 0
  fi
  python3 - "${PROJECTS_INDEX}" "${SLUG}" "${CANONICAL_PATH}" "${reason}" <<'PYEOF' 2>/dev/null || true
import json
import os
import sys

index_path, slug, path, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(os.path.dirname(index_path), exist_ok=True)

try:
    with open(index_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {"projects": []}

data.setdefault("projects", [])
found = False
for project in data["projects"]:
    if project.get("slug") == slug:
        project["status"] = "pending"
        project["pending_reason"] = reason
        project["path_by_host"] = path
        found = True
        break
if not found:
    data["projects"].append({
        "slug": slug,
        "path_by_host": path,
        "status": "pending",
        "pending_reason": reason,
    })

tmp_path = index_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp_path, index_path)
PYEOF
  release_index_lock
}

check_prerequisites() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found"
    return 1
  fi
  local py_major py_minor
  py_major="$(python3 -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo 0)"
  py_minor="$(python3 -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo 0)"
  if [[ "${py_major}" -lt 3 ]] || { [[ "${py_major}" -eq 3 ]] && [[ "${py_minor}" -lt 10 ]]; }; then
    echo "python3 >= 3.10 required, found ${py_major}.${py_minor}"
    return 1
  fi
  if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found"
    return 1
  fi
  if ! command -v graphify >/dev/null 2>&1; then
    echo "graphify not found"
    return 1
  fi
  return 0
}

PREREQ_ERROR=""
if ! PREREQ_ERROR="$(check_prerequisites)"; then
  write_pending_status "${PREREQ_ERROR}"
  log "prerequisites missing (${PREREQ_ERROR}), recorded pending status, exiting quietly"
  exit 0
fi

# --- run graphify into a temp dir ------------------------------------------
TMP_OUT_DIR="$(mktemp -d 2>/dev/null || true)"
if [[ -z "${TMP_OUT_DIR}" ]]; then
  log "mktemp failed, exiting quietly"
  exit 0
fi
cleanup_tmp() {
  rm -rf "${TMP_OUT_DIR}" 2>/dev/null || true
}
trap 'cleanup_tmp; cleanup_lock' EXIT INT TERM

if ! (cd "${CANONICAL_PATH}" && graphify --output "${TMP_OUT_DIR}" >/tmp/claude-memory-graphify.log 2>&1); then
  write_pending_status "graphify run failed, see /tmp/claude-memory-graphify.log"
  log "graphify failed for slug=${SLUG}, recorded pending status, exiting quietly"
  exit 0
fi

if [[ ! -f "${TMP_OUT_DIR}/graph.json" ]] || [[ ! -f "${TMP_OUT_DIR}/GRAPH_REPORT.md" ]]; then
  write_pending_status "graphify did not produce expected output files"
  log "graphify output incomplete for slug=${SLUG}, recorded pending status, exiting quietly"
  exit 0
fi

mkdir -p "${PROJECT_DIR}"
cp "${TMP_OUT_DIR}/graph.json" "${PROJECT_DIR}/graph.json"
cp "${TMP_OUT_DIR}/GRAPH_REPORT.md" "${PROJECT_DIR}/GRAPH_REPORT.md"
# graph.html (if produced) is intentionally discarded — never versioned.

# --- update meta.json and index/projects.json ------------------------------
HOSTNAME_VALUE="$(hostname 2>/dev/null || echo unknown-host)"
TIMESTAMP_VALUE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IS_LOCAL_ONLY="false"
if [[ "${SLUG}" == local_* ]]; then
  IS_LOCAL_ONLY="true"
fi

# meta.json is per-slug state, already protected by this script's outer
# per-slug lock (flock/mkdir-lock on ${LOCK_FILE} above) — no extra locking
# needed for this write.
python3 - "${PROJECT_DIR}/meta.json" "${SLUG}" "${CANONICAL_PATH}" \
  "${HOSTNAME_VALUE}" "${TIMESTAMP_VALUE}" "${CURRENT_HASH}" "${IS_LOCAL_ONLY}" <<'PYEOF' || true
import json
import os
import sys

(meta_path, slug, path, host, timestamp,
 content_hash, is_local_only) = sys.argv[1:8]
is_local_only = is_local_only == "true"

os.makedirs(os.path.dirname(meta_path), exist_ok=True)

try:
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
except (OSError, json.JSONDecodeError):
    meta = {}

meta["slug"] = slug
meta["last_mapped_at"] = timestamp
meta["last_content_hash"] = content_hash
meta.setdefault("hosts", {})
meta["hosts"][host] = {"path": path, "last_mapped_at": timestamp}
if is_local_only:
    meta["local-only"] = True

meta_tmp = meta_path + ".tmp"
with open(meta_tmp, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(meta_tmp, meta_path)
PYEOF

# index/projects.json IS shared across every project on this machine — guard
# the read-modify-write with the short-lived, granular index lock. Held only
# for this update (never across graphify above); on contention we retry a
# few times and, failing that, skip the index update rather than block the
# session (meta.json above has already been written either way).
if acquire_index_lock; then
  python3 - "${PROJECTS_INDEX}" "${SLUG}" "${CANONICAL_PATH}" \
    "${TIMESTAMP_VALUE}" "${CURRENT_HASH}" <<'PYEOF' || true
import json
import os
import sys

(index_path, slug, path, timestamp, content_hash) = sys.argv[1:6]

os.makedirs(os.path.dirname(index_path), exist_ok=True)
try:
    with open(index_path, "r", encoding="utf-8") as f:
        index_data = json.load(f)
except (OSError, json.JSONDecodeError):
    index_data = {"projects": []}

index_data.setdefault("projects", [])
found = False
for project in index_data["projects"]:
    if project.get("slug") == slug:
        project["path_by_host"] = path
        project["last_mapped_at"] = timestamp
        project["last_content_hash"] = content_hash
        project["status"] = "mapped"
        project.pop("pending_reason", None)
        found = True
        break
if not found:
    index_data["projects"].append({
        "slug": slug,
        "path_by_host": path,
        "last_mapped_at": timestamp,
        "last_content_hash": content_hash,
        "status": "mapped",
    })

index_tmp = index_path + ".tmp"
with open(index_tmp, "w", encoding="utf-8") as f:
    json.dump(index_data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(index_tmp, index_path)
PYEOF
  release_index_lock
else
  log "could not acquire index lock after retries, skipping index/projects.json update this time"
fi

log "mapped slug=${SLUG} successfully, syncing"

# --- sync ---------------------------------------------------------------
"${SCRIPT_DIR}/sync.sh" "${SLUG}" \
  "projects/${SLUG}/graph.json" \
  "projects/${SLUG}/GRAPH_REPORT.md" \
  "projects/${SLUG}/meta.json" \
  "index/projects.json" \
  >/tmp/claude-memory-sync-from-detect.log 2>&1 || true

exit 0
