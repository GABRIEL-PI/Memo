# Architecture

This document is the reference specification for `claude-memory-sync`. It
describes the dedicated memory repository layout, project identity rules,
the `detect-and-map` flow, the `sync` flow, the installer flow, and the
`merge-settings.py` contract. Implementation files should stay faithful to
this document; if they diverge, treat this document as the source of truth
and reconcile the code.

## Memory repo layout (`~/.claude-memory` on macOS/Linux, `%USERPROFILE%\.claude-memory` on Windows)

```
claude-memory/
├── README.md
├── .gitignore
├── .gitattributes
├── manifest.json
├── index/projects.json       # global catalog: 1 entry per project {slug, path_by_host, last_mapped_at, status}
├── index/machines.json       # known hostnames
├── projects/<slug>/meta.json
├── projects/<slug>/graph.json         # Graphify output, versioned
├── projects/<slug>/GRAPH_REPORT.md    # Graphify output, versioned
├── projects/<slug>/notes.md           # manually curated, optional
├── global/conventions.md
├── bin/  (copy of the operational scripts, to run directly from the cloned repo)
└── config/settings.template.json
```

`graph.html` is NEVER versioned (derivable, large) — it must be in the
template `.gitignore`.

## Project slug (stable identity across OSes)

1. If a `git remote origin` exists → slug = `host/owner/repo` normalized,
   lowercase, with `/` replaced by `_` to form a folder name (e.g.
   `github.com_gabriel-pi_myproject`).
2. Otherwise → slug = `local_<folder-name>_<hash8-of-canonical-path>`,
   marked `"local-only": true` in `meta.json`.

## `detect-and-map` flow

Called by the Claude Code `SessionStart` hook. ALWAYS runs in
background/non-blocking mode; must never hang the session nor fail loudly.

1. Resolve cwd → canonical path.
2. Derive slug (via `slug.sh` / `slug.ps1`).
3. Query `~/.claude-memory/index/projects.json`: does an entry already
   exist with the same slug AND an unchanged project hash
   (`git rev-parse HEAD` if a git repo, else an aggregate mtime hash) since
   the last map? If so, exit (fast path, no work).
4. Acquire a per-slug lock (a `.lock` file in `projects/<slug>/`) — if
   already locked by another process, exit immediately without waiting
   (avoids a race between concurrent sessions). Always release the lock via
   trap/finally, including on error.
5. Check prerequisites (`python3 --version` >= 3.10, `uv --version`,
   `graphify --version`). If anything is missing: record status "pending"
   in the index with the reason, release the lock, exit — NEVER fail
   loudly nor block the session.
6. Run `graphify` against the project directory, output into a temp dir
   (`mktemp -d`).
7. Copy `graph.json` + `GRAPH_REPORT.md` into
   `~/.claude-memory/projects/<slug>/` (create the folder if missing).
   Discard `graph.html`.
8. Update the project's `meta.json` (current host via `hostname`,
   ISO8601 timestamp, content hash, this machine's local path) and
   `index/projects.json` (upsert by slug).
9. Call `sync.sh` / `sync.ps1`, passing the list of touched files.
10. Release the lock (always).

## `sync.sh` / `sync.ps1`

1. `cd ~/.claude-memory`
2. `git pull --rebase --autostash`
3. `git add` by EXPLICIT FILE NAME (never `-A`/`.`) — only the files this
   process touched (received as arguments, or via
   `git status --porcelain` filtered to the `projects/<slug>/` and
   `index/` prefixes; never a blind add).
4. `git commit -m "map: <slug> @ <hostname> <timestamp>"` (skip if nothing
   staged).
5. `git push`; if rejected (non-fast-forward), retry from step 2 through 3
   up to 3 attempts with backoff (sleep 2/4/8s), then give up, logging the
   error without hanging the calling process.

## `install.sh` / `install.ps1` (idempotent — re-running never breaks anything)

0. Detect OS, set paths.
1. Check Python 3.10+; if missing, try to install it (brew on macOS,
   apt/dnf on Linux, winget on Windows); if that fails, abort with a clear
   message instructing manual installation, without leaving the system in
   a broken state.
2. Check `uv`; install via the official installer if missing.
3. `uv tool install graphifyy`; validate `graphify --version`.
4. Dedicated SSH key: if `~/.ssh/claude_memory_ed25519` doesn't exist,
   generate it (`ssh-keygen -t ed25519 -N "" -f ...`, no passphrase since
   it runs non-interactively). Insert a `Host github-claude-memory` block
   into `~/.ssh/config` idempotently (markers `# >>> claude-memory >>>` /
   `# <<<`, only inserted if absent). Print the public key and instruct
   the user to register it as a (write-access) Deploy Key on the
   `claude-memory` GitHub repo — a manual step, since the script has no
   GitHub credentials.
5. Validate access: `ssh -T git@github-claude-memory` (do NOT fail the
   script if the test returns GitHub's normal success text, which always
   "fails" with exit code 1 but a welcome message like "Hi <user>! You've
   successfully authenticated" — handle this correctly by grepping the
   output, not treating it as an error).
6. Clone `git@github-claude-memory:GABRIEL-PI/claude-memory.git` into
   `~/.claude-memory` (or `git pull --rebase` if it already exists and is
   a valid git repo).
7. Copy this toolkit's `bin/*` scripts into `~/.claude-memory/bin/` (make
   them executable on Unix via `chmod +x`).
8. Run `merge-settings.py` to insert the `SessionStart` hook into the
   user's real `~/.claude/settings.json` (backing up first, validating
   JSON afterward, without duplicating an existing hook, without removing
   the already-present `Stop` hook).
9. Optional smoke test (can be skipped if there's no test project).
10. Print a final summary with next steps (mainly: register the deploy
    key if not already registered).

## `merge-settings.py`

- Reads the user's real `~/.claude/settings.json` (path configurable via
  an argument to make testing easier).
- Backs up to `~/.claude/settings.json.bak` — if a backup already exists,
  use a timestamped name instead of overwriting it (e.g.
  `settings.json.bak.<epoch>`), preserving history.
- Inserts/updates the `SessionStart` hook entry pointing at
  `~/.claude-memory/bin/detect-and-map.sh` (or `.ps1` on Windows, detected
  at runtime), as an ASYNCHRONOUS/background, non-blocking command (e.g.
  `nohup ... &` with output redirection, or the equivalent Claude Code
  hook pattern).
- Does NOT duplicate the entry if the same command already exists in the
  hooks array.
- Does NOT remove any existing hook (e.g. an existing `Stop` hook from
  `save-to-obsidian.sh` must remain untouched).
- Validates that the resulting JSON is syntactically valid BEFORE writing
  the final file: writes to a temp file, validates with `json.load`, then
  atomically `os.replace`s it into place.
- Uses only the Python standard library (`json`, `os`, `sys`, `argparse`,
  `datetime`, `platform`, `shutil`). No external dependencies.

## Quality requirements

- Shell scripts: `set -euo pipefail` at the top, all variables quoted, no
  `eval` of uncontrolled input, minimal comments (only where logic isn't
  obvious).
- PowerShell: `$ErrorActionPreference = "Stop"`, explicit error handling
  with try/catch where relevant.
- No hardcoded secrets anywhere.
- `manifest.json`: just the system's schema version.
- Root `.gitattributes`: `merge=union` for `index/*.json` (to reduce merge
  conflicts between concurrent machines).
- `template/.gitignore`: ignores `graph.html`, caches, temp lock files
  (`*.lock`).
- `template/index/projects.json` and `machines.json`: valid empty
  skeletons (`{"projects": []}` and `{"machines": []}`).
- `template/global/conventions.md`: short placeholder explaining the
  file's purpose.
- `template/settings.template.json`: the SessionStart hook JSON snippet,
  ready for human inspection (documentation/reference — the automatic
  merge is `merge-settings.py`'s job, not this file's).
