# Architecture

This document is the reference specification for `claude-memory-sync`. It
describes the dedicated memory repository layout, project identity rules,
the `detect-and-map` flow, the `sync` flow, the session sync flow (Google
Drive), the installer flow, and the `merge-settings.py` contract. Implementation files should stay faithful to
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
├── config/settings.template.json
└── config/local.env                   # per-machine, NEVER versioned (CLAUDE_SESSIONS_DIR=...)
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

## Session sync (`sync-sessions.sh` / `sync-sessions.ps1`)

Memory (native `memory/` + graphs) is versioned in git. Session
**transcripts** are not: they go to a cloud-synced folder (Google Drive),
because they contain secrets (command output, `.env` contents, tokens pasted
into prompts) and grow large. Git/GitHub must never receive them.

### What is synced

Inside the local Claude project folder (`~/.claude/projects/<encoded-cwd>/`):

- `<session-id>.jsonl` (the transcript), and
- the sibling `<session-id>/` directory if present (subagent transcripts,
  `tool-results/`, metadata such as `custom-title.json`).

`memory/` and anything else in that folder is never touched (native memory
goes through git via `mirror-native-memory.sh`).

Remote layout, keyed by the project slug (never by path — paths differ
between macOS and Windows):

```
$CLAUDE_SESSIONS_DIR/
└── <slug>/
    ├── <session-id>.jsonl
    ├── <session-id>/...
    └── _conflicts/<hostname>/<session-id>.jsonl   # only on divergence
```

### Configuration

`CLAUDE_SESSIONS_DIR` comes from the environment, else from
`~/.claude-memory/config/local.env` (a `KEY="value"` file, parsed — never
sourced/executed — and git-ignored). If unset or the folder does not exist
(Drive not mounted), both modes exit 0 silently (a line goes to the log
file only when the folder is configured but missing). Suggested values
(documentation only, never hardcoded):

- macOS: `~/Library/CloudStorage/GoogleDrive-<email>/Meu Drive/claude-sessions`
  (PT-BR account) or `.../My Drive/claude-sessions` (EN account)
- Windows: `G:\Meu Drive\claude-sessions` or `G:\My Drive\claude-sessions`

The Drive root folder name is localized ("My Drive" / "Meu Drive"); the
installer auto-detects both. `GoogleDrive-<email>/` itself is read-only —
the folder must live inside the root. The installer creates only the last
path component (never intermediate directories) and only when its parent
exists.

The Drive folder MUST be "Available offline" (or the Drive client in Mirror
mode). Online-only placeholders cannot be detected reliably; reading one
either blocks on download or fails, and the sync then skips/logs it.

### Hook flow

1. The hook command runs `sync-sessions.{sh,ps1} <push|pull>` in the
   foreground. It reads the hook JSON from stdin (`cwd`, `session_id`,
   `transcript_path`) and immediately re-launches itself detached
   (`nohup` / hidden `Start-Process`) with those values as arguments, then
   exits 0. The command must NOT be wrapped in `nohup ... &` in
   `settings.json`: a backgrounded command gets `/dev/null` as stdin and
   would lose the payload.
2. Local folder: `dirname(transcript_path)` — authoritative, since it is the
   folder Claude Code itself uses. Fallback (manual runs): encode `cwd` the
   way Claude Code does — every character outside `[A-Za-z0-9]` becomes `-`
   (`/Users/a/dev/x` -> `-Users-a-dev-x`, `D:\dow\X` -> `D--dow-X`); names
   longer than 200 chars are truncated by Claude Code and suffixed with a
   hash we cannot reproduce, so the fallback accepts a unique prefix match
   only. This encoding is an observed implementation detail, not a public
   contract — hence the preference for `transcript_path`.
3. Slug via `slug.sh` / `slug.ps1` on `cwd`.
4. Per-slug lock in the LOCAL temp dir (`$TMPDIR` / `%TEMP%`, never on the
   Drive): `mkdir` lock, shared by push and pull. Since the worker already
   runs detached it waits up to 60s (`CLAUDE_SESSION_SYNC_LOCK_WAIT`) rather
   than skipping, so the push after a session's last turn is not lost.
   Locks older than 15 min are considered stale and reclaimed.
5. Per-file decision (see below), atomic copy (temp file
   `.<name>.sync-tmp.<pid>` in the destination dir + rename; mtime
   preserved).
6. Log to `/tmp/claude-memory-sync-sessions.log` (`%TEMP%\...` on Windows),
   rotated at 1 MB. Nothing on stderr/stdout of the hook.

`push` (Stop hook): local -> `$CLAUDE_SESSIONS_DIR/<slug>/`.
`pull` (SessionStart hook): `$CLAUDE_SESSIONS_DIR/<slug>/` -> local, skipping
the current session's `<session_id>.jsonl` and `<session_id>/`.

### Per-file decision (mtime-independent for transcripts)

Transcripts are append-only, so content — not clocks — decides. This avoids
clock skew between machines and mtime rewriting by the Drive client.

| Destination state | `.jsonl` action |
| --- | --- |
| missing | copy |
| same size | skip |
| smaller AND a byte-prefix of the source | copy (fast-forward) |
| larger AND the source is its prefix | skip (destination ahead) |
| anything else | conflict |

Conflict handling: `push` never overwrites the Drive copy; it stores the
local version at `_conflicts/<hostname>/<file>` (one snapshot per host and
file, refreshed only when its size changes — not one per turn). `pull`
leaves the local file untouched and logs the conflict. Resolution is manual.

Non-transcript files (tool results, metadata): copy if missing, or if the
content differs and the source mtime is newer.

Nothing is ever deleted at the destination (the only removals are the
script's own temp files and stale lock dirs).

### Known limitations

- `claude --resume` shows the picker before `SessionStart` fires, so
  sessions pulled during that start-up appear on the next launch (or via
  `/resume` inside the session). Run
  `~/.claude-memory/bin/sync-sessions.sh pull --foreground` in the project
  dir beforehand to pull them immediately.
- A session resumed on another machine carries the original machine's
  absolute paths (`cwd`, file paths in tool calls/results).
- Resuming the same session concurrently on two machines produces a
  divergence (see conflict handling); last-writer-wins is deliberately NOT
  used.
- Never symlink `~/.claude/projects` (or a project folder) into the Drive:
  the Drive client would sync half-written files, could evict them to
  online-only, and Claude Code would read/write through the cloud layer.

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
   Ensure `config/local.env` is listed in the memory repo's `.gitignore`
   (appended if an older repo lacks it).
7b. Session sync folder: take `--sessions-dir` / `-SessionsDir`, else
   `$CLAUDE_SESSIONS_DIR`, else the value already in `config/local.env`,
   else prompt (via `/dev/tty`, so `curl | sh` still works; suggesting the
   single detected, writable Google Drive root — "My Drive" or "Meu Drive" —
   plus `/claude-sessions`). Empty answer = skip
   (hooks stay installed but inactive). Upsert the value into
   `config/local.env` (mode 600, other keys preserved), create the folder if
   its parent exists, and remind the user to make it "Available offline".
   `--skip-session-sync` / `-SkipSessionSync` skips this step and the
   session hooks.
8. Run `merge-settings.py` to insert the hooks into the user's real
   `~/.claude/settings.json` (backing up first, validating JSON afterward,
   without duplicating an existing hook, without removing the
   already-present `Stop` hooks).
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
- Unless `--skip-session-sync`: inserts `SessionStart` ->
  `sync-sessions.{sh,ps1} pull` and `Stop` -> `sync-sessions.{sh,ps1} push`
  (matcher `""`, `timeout` 30, no `nohup` wrapper — see Session sync), and
  sets `cleanupPeriodDays` to 3650 if absent or lower (Claude Code prunes
  local transcripts older than this; a higher existing value is kept).
- Does NOT duplicate the entry if the same command already exists in the
  hooks array. The session hooks are matched by pattern
  (`sync-sessions.(sh|ps1) push|pull`), so a different path/quoting never
  creates a second entry.
- If the merged result equals the current file, exits without writing or
  creating a backup.
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
  (`*.lock`), and the per-machine `config/local.env`.
- `template/index/projects.json` and `machines.json`: valid empty
  skeletons (`{"projects": []}` and `{"machines": []}`).
- `template/global/conventions.md`: short placeholder explaining the
  file's purpose.
- `template/settings.template.json`: the hook JSON snippets
  (SessionStart + Stop) and `cleanupPeriodDays`, ready for human inspection (documentation/reference — the automatic
  merge is `merge-settings.py`'s job, not this file's).
