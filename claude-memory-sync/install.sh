#!/usr/bin/env bash
# install.sh — idempotent installer for claude-memory-sync (macOS/Linux).
# Re-running this script is always safe: every step checks current state
# before acting and never destroys existing data.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR:-${HOME}/.claude-memory}"
CLAUDE_SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-${HOME}/.claude/settings.json}"
SSH_KEY_PATH="${HOME}/.ssh/claude_memory_ed25519"
SSH_CONFIG_PATH="${HOME}/.ssh/config"
SSH_HOST_ALIAS="github-claude-memory"
MEMORY_REPO_SSH_URL="git@${SSH_HOST_ALIAS}:GABRIEL-PI/claude-memory.git"
MARKER_START="# >>> claude-memory >>>"
MARKER_END="# <<< claude-memory <<<"

log() { printf '[install.sh] %s\n' "$*"; }
warn() { printf '[install.sh] WARNING: %s\n' "$*" >&2; }
die() { printf '[install.sh] ERROR: %s\n' "$*" >&2; exit 1; }

OS_NAME="$(uname -s)"
log "detected OS: ${OS_NAME}"

# --- step 1: Python 3.10+ ---------------------------------------------------
python_version_ok() {
  command -v python3 >/dev/null 2>&1 || return 1
  local major minor
  major="$(python3 -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo 0)"
  minor="$(python3 -c 'import sys; print(sys.version_info[1])' 2>/dev/null || echo 0)"
  [[ "${major}" -ge 3 ]] && [[ "${minor}" -ge 10 ]]
}

if python_version_ok; then
  log "python3 >= 3.10 already present"
else
  log "python3 >= 3.10 not found, attempting install"
  case "${OS_NAME}" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        brew install python@3.12 || true
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y python3.12 python3.12-venv || \
          sudo apt-get install -y python3 || true
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3.12 || sudo dnf install -y python3 || true
      fi
      ;;
    *)
      warn "unrecognized OS '${OS_NAME}', skipping automatic python install"
      ;;
  esac
  if ! python_version_ok; then
    die "Python 3.10+ is required but could not be installed automatically. Please install it manually (e.g. https://www.python.org/downloads/) and re-run this script."
  fi
fi

# --- step 2: uv --------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
  log "uv already present"
else
  log "installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh || die "failed to install uv"
  export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
fi

command -v uv >/dev/null 2>&1 || die "uv installation did not result in a usable 'uv' command on PATH"

# --- step 3: graphify --------------------------------------------------------
if command -v graphify >/dev/null 2>&1; then
  log "graphify already present: $(graphify --version 2>/dev/null || echo unknown-version)"
else
  log "installing graphify via uv tool install"
  uv tool install graphifyy || die "failed to install graphify"
fi

command -v graphify >/dev/null 2>&1 || warn "graphify still not on PATH after install; you may need to restart your shell or add uv's tool bin dir to PATH"

# --- step 4: dedicated SSH key -----------------------------------------------
if [[ -f "${SSH_KEY_PATH}" ]]; then
  log "SSH key ${SSH_KEY_PATH} already exists, reusing"
else
  log "generating dedicated SSH key at ${SSH_KEY_PATH}"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" -C "claude-memory-sync" || die "ssh-keygen failed"
fi

mkdir -p "$(dirname "${SSH_CONFIG_PATH}")"
touch "${SSH_CONFIG_PATH}"
chmod 600 "${SSH_CONFIG_PATH}"

if grep -qF "${MARKER_START}" "${SSH_CONFIG_PATH}" 2>/dev/null; then
  log "SSH config block for claude-memory already present, leaving untouched"
else
  log "appending claude-memory SSH host block to ${SSH_CONFIG_PATH}"
  {
    printf '\n%s\n' "${MARKER_START}"
    printf 'Host %s\n' "${SSH_HOST_ALIAS}"
    printf '  HostName github.com\n'
    printf '  User git\n'
    printf '  IdentityFile %s\n' "${SSH_KEY_PATH}"
    printf '  IdentitiesOnly yes\n'
    printf '%s\n' "${MARKER_END}"
  } >>"${SSH_CONFIG_PATH}"
fi

log "Public key (register this as a write-access Deploy Key on the 'claude-memory' GitHub repo if not already done):"
cat "${SSH_KEY_PATH}.pub"

# --- step 5: validate SSH access --------------------------------------------
SSH_TEST_OUTPUT="$(ssh -T -o StrictHostKeyChecking=accept-new "git@${SSH_HOST_ALIAS}" 2>&1 || true)"
if printf '%s' "${SSH_TEST_OUTPUT}" | grep -qi "successfully authenticated"; then
  log "SSH access to github-claude-memory confirmed"
else
  warn "could not confirm SSH access yet (this is expected if the deploy key isn't registered on GitHub yet). Output was:"
  printf '%s\n' "${SSH_TEST_OUTPUT}" >&2
fi

# --- step 6: clone or update the memory repo --------------------------------
if [[ -d "${CLAUDE_MEMORY_DIR}/.git" ]]; then
  log "${CLAUDE_MEMORY_DIR} already a git repo, pulling latest"
  (cd "${CLAUDE_MEMORY_DIR}" && git pull --rebase --autostash) || \
    warn "git pull in ${CLAUDE_MEMORY_DIR} failed; leaving existing repo state as-is"
elif [[ -d "${CLAUDE_MEMORY_DIR}" ]]; then
  warn "${CLAUDE_MEMORY_DIR} exists but is not a git repo; leaving it untouched. Please resolve manually."
else
  log "cloning ${MEMORY_REPO_SSH_URL} into ${CLAUDE_MEMORY_DIR}"
  if ! git clone "${MEMORY_REPO_SSH_URL}" "${CLAUDE_MEMORY_DIR}"; then
    warn "clone failed (deploy key likely not yet registered). Creating an empty local repo scaffold instead; re-run install.sh after registering the deploy key to finish syncing."
    mkdir -p "${CLAUDE_MEMORY_DIR}"
    (cd "${CLAUDE_MEMORY_DIR}" && git init -q)
  fi
fi

# --- step 7: copy operational scripts into the memory repo ------------------
mkdir -p "${CLAUDE_MEMORY_DIR}/bin"
for f in "${SCRIPT_DIR}"/bin/*; do
  cp "${f}" "${CLAUDE_MEMORY_DIR}/bin/$(basename "${f}")"
done
chmod +x "${CLAUDE_MEMORY_DIR}"/bin/*.sh 2>/dev/null || true
chmod +x "${CLAUDE_MEMORY_DIR}"/bin/merge-settings.py 2>/dev/null || true

# Seed template files into the memory repo if not already present (never
# overwrite existing curated content).
mkdir -p "${CLAUDE_MEMORY_DIR}/index" "${CLAUDE_MEMORY_DIR}/global" "${CLAUDE_MEMORY_DIR}/config"
[[ -f "${CLAUDE_MEMORY_DIR}/index/projects.json" ]] || cp "${SCRIPT_DIR}/template/index/projects.json" "${CLAUDE_MEMORY_DIR}/index/projects.json"
[[ -f "${CLAUDE_MEMORY_DIR}/index/machines.json" ]] || cp "${SCRIPT_DIR}/template/index/machines.json" "${CLAUDE_MEMORY_DIR}/index/machines.json"
[[ -f "${CLAUDE_MEMORY_DIR}/global/conventions.md" ]] || cp "${SCRIPT_DIR}/template/global/conventions.md" "${CLAUDE_MEMORY_DIR}/global/conventions.md"
[[ -f "${CLAUDE_MEMORY_DIR}/.gitignore" ]] || cp "${SCRIPT_DIR}/template/.gitignore" "${CLAUDE_MEMORY_DIR}/.gitignore"
[[ -f "${CLAUDE_MEMORY_DIR}/.gitattributes" ]] || cp "${SCRIPT_DIR}/.gitattributes" "${CLAUDE_MEMORY_DIR}/.gitattributes"
[[ -f "${CLAUDE_MEMORY_DIR}/config/settings.template.json" ]] || cp "${SCRIPT_DIR}/template/settings.template.json" "${CLAUDE_MEMORY_DIR}/config/settings.template.json"
[[ -f "${CLAUDE_MEMORY_DIR}/manifest.json" ]] || cp "${SCRIPT_DIR}/manifest.json" "${CLAUDE_MEMORY_DIR}/manifest.json"

# --- step 8: merge SessionStart hook into the user's real settings.json ----
log "merging SessionStart hook into ${CLAUDE_SETTINGS_PATH}"
python3 "${SCRIPT_DIR}/bin/merge-settings.py" \
  --settings-path "${CLAUDE_SETTINGS_PATH}" \
  --memory-dir "${CLAUDE_MEMORY_DIR}" || die "merge-settings.py failed"

# --- step 9: optional smoke test ---------------------------------------------
if [[ -n "${CLAUDE_MEMORY_SMOKE_TEST_DIR:-}" ]] && [[ -d "${CLAUDE_MEMORY_SMOKE_TEST_DIR}" ]]; then
  log "running smoke test against ${CLAUDE_MEMORY_SMOKE_TEST_DIR}"
  (cd "${CLAUDE_MEMORY_SMOKE_TEST_DIR}" && CLAUDE_MEMORY_DIR="${CLAUDE_MEMORY_DIR}" "${CLAUDE_MEMORY_DIR}/bin/detect-and-map.sh") || \
    warn "smoke test run reported an error (non-fatal, see logs in /tmp/claude-memory-*.log)"
else
  log "no CLAUDE_MEMORY_SMOKE_TEST_DIR provided, skipping smoke test"
fi

# --- step 10: summary ---------------------------------------------------------
cat <<SUMMARY

===============================================================
claude-memory-sync install complete.

Memory repo:      ${CLAUDE_MEMORY_DIR}
Settings merged:  ${CLAUDE_SETTINGS_PATH} (backup created alongside it)
SSH key:          ${SSH_KEY_PATH}

Next steps:
  1. If you haven't already, register the public key printed above as a
     write-access Deploy Key on the 'claude-memory' GitHub repository:
       ${SSH_KEY_PATH}.pub
  2. Re-run this script after registering the key if the initial clone
     above fell back to an empty local scaffold.
  3. Start a new Claude Code session in any project — detect-and-map will
     run automatically in the background.
===============================================================
SUMMARY
