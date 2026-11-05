# claude-memory-sync

Installer and operational scripts for a persistent, multi-device memory
system for Claude Code. Every machine you run Claude Code on maps the
current project into a shared knowledge base (via
[`graphify`](https://example.invalid/graphify)) and keeps it in sync
through a dedicated Git repository, `~/.claude-memory`.

## What it does

- On every Claude Code `SessionStart`, a background hook derives a stable
  slug for the current project, runs `graphify` to produce `graph.json` +
  `GRAPH_REPORT.md`, and commits/pushes them into `~/.claude-memory`.
- The same repo is shared across all your machines, so project knowledge
  built on one device is available on the next.
- Everything runs in the background and is designed to fail silently
  (recording a "pending" status) rather than block or break your session.
- **Session transcripts** (`claude --resume` history) are synced through a
  Google Drive folder — not through Git — so a session started on one
  machine can be resumed on another. See [Session sync](#session-sync-google-drive).

## Install

macOS/Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/GABRIEL-PI/Memo/main/claude-memory-sync/install.sh | sh
```

Windows (PowerShell):

```powershell
iwr https://raw.githubusercontent.com/GABRIEL-PI/Memo/main/claude-memory-sync/install.ps1 | iex
```

The installer is idempotent — re-running it never breaks an existing
setup. It will:

1. Ensure Python 3.10+ and `uv` are present.
2. Install `graphify` via `uv tool install`.
3. Generate a dedicated SSH key (`~/.ssh/claude_memory_ed25519`) and print
   the public key for you to register as a **write-access Deploy Key** on
   your `claude-memory` GitHub repository (manual step — the installer
   never has GitHub credentials).
4. Clone (or update) `~/.claude-memory`.
5. Copy the operational scripts into `~/.claude-memory/bin/`.
6. Ask for the Google Drive folder used for session sync and save it in
   `~/.claude-memory/config/local.env` (per machine, never committed).
7. Merge the hooks (`SessionStart`: detect-and-map + session pull; `Stop`:
   session push) and `cleanupPeriodDays: 3650` into your real
   `~/.claude/settings.json` (after backing it up), without touching any
   hook you already have.

Non-interactive session sync setup:

```sh
./install.sh --sessions-dir "$HOME/Library/CloudStorage/GoogleDrive-you@example.com/Meu Drive/claude-sessions"
./install.sh --skip-session-sync      # memory/graphs only
```

```powershell
.\install.ps1 -SessionsDir "G:\Meu Drive\claude-sessions"
$env:CLAUDE_SESSIONS_DIR = "G:\Meu Drive\claude-sessions"; iwr ... | iex   # when piping
```

## Daily Usage

Usage is mostly **passive**: the `SessionStart` hook runs `detect-and-map.sh` (or `.ps1` on Windows) in the background on every Claude Code session. If the project has already been mapped and nothing has changed, it takes the fast path and does nothing. If it's new or changed, it runs `graphify`, commits, and pushes to `~/.claude-memory`—all without blocking your session.

### Manual commands

Force an immediate remap of the current project:

```bash
# macOS/Linux
~/.claude-memory/bin/detect-and-map.sh

# Windows (PowerShell)
~/.claude-memory/bin/detect-and-map.ps1
```

Force a manual sync (pull in mappings from other machines):

```bash
# macOS/Linux
~/.claude-memory/bin/sync.sh

# Windows (PowerShell)
~/.claude-memory/bin/sync.ps1
```

### Checking what's been mapped

View the catalog of all mapped projects:

```bash
cat ~/.claude-memory/index/projects.json
```

Each project is identified by a **slug** (format: `host_owner_repo` derived from your git remote, or `local_<name>_<hash8>` for local projects). To find your current project's slug:

```bash
~/.claude-memory/bin/slug.sh  # or slug.ps1 on Windows
```

Once you have the slug, read the human-friendly graph report for that project:

```bash
cat ~/.claude-memory/projects/<slug>/GRAPH_REPORT.md
```

### Viewing the graph

The `graph.json` is versioned in git (so it syncs across devices), but `graph.html` is derived locally and not committed. To explore the graph interactively:

```bash
cd ~/.claude-memory/projects/<slug>
graphify view graph.json
```

### Manual notes per project

Each project folder contains a `notes.md` file that is never overwritten by `graphify` and is safe to edit freely:

```bash
~/.claude-memory/projects/<slug>/notes.md
```

Use this to record context, decisions, or reminders specific to that project.

## Session sync (Google Drive)

Memory stays in Git. Session transcripts
(`~/.claude/projects/<folder>/<session-id>.jsonl` plus the `<session-id>/`
folder with subagents and tool results) go to a Google Drive folder, keyed
by the project slug — so `~/dev/rocket/x` on macOS and `D:\dow\x` on
Windows land in the same place.

> **Transcripts contain secrets.** Every command output, file read, `.env`
> content or token you pasted ends up in them. That is why they go to your
> private Drive and **never to GitHub** — not even a private repo. Do not
> share the `claude-sessions` folder.

- `Stop` hook -> `sync-sessions push`: copies new/grown transcripts of the
  current project to `<drive>/claude-sessions/<slug>/`.
- `SessionStart` hook -> `sync-sessions pull`: copies transcripts that are
  missing or have grown on the Drive into the local project folder (never
  the session that is currently starting), so `claude --resume` lists
  sessions from other machines.
- Both run detached, exit 0 on any error, and do nothing at all if
  `CLAUDE_SESSIONS_DIR` is not configured or the Drive is not mounted.
- Nothing is ever deleted on the Drive. If the same session was continued
  on two machines (divergence), the Drive copy is kept and the local one is
  saved under `<slug>/_conflicts/<hostname>/` for manual resolution.
- Log: `/tmp/claude-memory-sync-sessions.log` (`%TEMP%\claude-memory-sync-sessions.log`).

Configuration (per machine): `CLAUDE_SESSIONS_DIR` env var, or
`~/.claude-memory/config/local.env`:

```sh
# macOS (PT-BR account: "Meu Drive"; EN account: "My Drive")
CLAUDE_SESSIONS_DIR="/Users/you/Library/CloudStorage/GoogleDrive-you@example.com/Meu Drive/claude-sessions"
# Windows
CLAUDE_SESSIONS_DIR="G:\Meu Drive\claude-sessions"
```

The Drive root name depends on the account language ("My Drive" /
"Meu Drive"); the installer detects both and suggests
`<root>/claude-sessions` when exactly one writable root is found. Keep the
folder inside that root: `GoogleDrive-<email>/` itself is read-only.

Requirements and caveats:

- Mark the `claude-sessions` folder **"Available offline"** in Google Drive
  for desktop (or use Mirror mode). Online-only placeholders can't be
  detected reliably and may block or be skipped.
- **Do not symlink `~/.claude/projects` into the Drive.** Claude Code writes
  transcripts continuously; the Drive client would upload half-written files
  and could evict them to online-only. The copy-based hooks avoid this.
- `claude --resume` shows its picker before the `SessionStart` hook runs, so
  sessions pulled during that start-up show up on the next launch (or via
  `/resume`). To pull right away:
  `~/.claude-memory/bin/sync-sessions.sh pull --foreground` (from the
  project dir).
- A resumed session keeps the original machine's absolute paths in its
  history (`/Users/...` vs `D:\...`); Claude will see them as-is.

## How it works under the hood

```
SessionStart hook (background, non-blocking)
        │
        ▼
  detect-and-map.sh/.ps1
        │  1. resolve cwd -> canonical path
        │  2. derive stable slug (git remote, or local_<name>_<hash8>)
        │  3. fast-path: already mapped at current content hash? exit.
        │  4. acquire per-slug lock (non-blocking; skip if already held)
        │  5. check prerequisites (python3, uv, graphify); if missing,
        │     record "pending" status and exit quietly
        │  6. run graphify -> temp dir
        │  7. copy graph.json + GRAPH_REPORT.md into
        │     ~/.claude-memory/projects/<slug>/ (discard graph.html)
        │  8. update meta.json + index/projects.json
        │  9. call sync.sh/.ps1
        ▼
  sync.sh/.ps1
     git pull --rebase --autostash
     git add <explicit touched files only>
     git commit -m "map: <slug> @ <hostname> <timestamp>"
     git push (retry up to 3x with backoff on non-fast-forward rejection)

SessionStart / Stop hooks (detached, non-blocking)
        │
        ▼
  sync-sessions.sh/.ps1 pull|push
        │  1. read {cwd, session_id, transcript_path} from stdin, detach
        │  2. local dir = dirname(transcript_path); slug via slug.sh
        │  3. per-slug local lock
        │  4. per file: copy if missing / fast-forward if append-only;
        │     divergence -> _conflicts/<host>/ (push) or log (pull)
        ▼
  $CLAUDE_SESSIONS_DIR/<slug>/  (Google Drive, never Git)
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full
specification, including the exact slug rules and the `merge-settings.py`
contract.

## Folder structure

```
claude-memory-sync/
├── README.md
├── install.sh / install.ps1
├── manifest.json
├── .gitattributes
├── template/                  # seeded into a fresh ~/.claude-memory
│   ├── .gitignore
│   ├── index/{projects,machines}.json
│   ├── global/conventions.md
│   └── settings.template.json
├── bin/
│   ├── detect-and-map.sh / .ps1
│   ├── sync.sh / .ps1
│   ├── slug.sh / .ps1
│   ├── sync-sessions.sh / .ps1   # session transcripts <-> Google Drive
│   ├── mirror-native-memory.sh
│   └── merge-settings.py
└── docs/ARCHITECTURE.md
```

The dedicated memory repo (`~/.claude-memory`) mirrors a subset of this
layout plus `projects/<slug>/{meta.json,graph.json,GRAPH_REPORT.md,notes.md}`
— see ARCHITECTURE.md for the full clone-side layout.

## Known risks

- **`graph.json` merge conflicts across machines.** Two machines mapping
  the same project concurrently can both push updates to
  `projects/<slug>/graph.json`. `index/*.json` uses `merge=union` in
  `.gitattributes` to reduce index conflicts, but `graph.json` itself has
  no custom merge driver — a real conflict there will surface as a normal
  git conflict on the next `sync`, and needs manual resolution (or a
  re-run of `detect-and-map` to regenerate it).
- **Repo growth over time.** `graph.json` and `GRAPH_REPORT.md` are
  versioned per project on every content change; a long-lived repo with
  many actively developed projects will grow. Periodic history cleanup
  (e.g. `git gc`, or squashing old history) is a manual operational task,
  not automated by this toolkit.
- **Windows without Python installed.** `install.ps1` tries `winget` to
  install Python automatically; if `winget` is unavailable or the org
  blocks package installs, the script aborts with a manual-install
  instruction rather than leaving a half-configured state.
- **Silent failure of `detect-and-map`.** By design, missing prerequisites
  or a failed `graphify` run are recorded as a "pending" status in
  `index/projects.json` and the hook exits quietly — this keeps sessions
  fast and non-blocking, but it also means a broken environment can go
  unnoticed unless you check `index/projects.json` or the
  `/tmp/claude-memory-*.log` files yourself. The same applies to session
  sync: check `/tmp/claude-memory-sync-sessions.log` for `CONFLICT` lines.
- **Session folder name encoding.** The local folder comes from the hook's
  `transcript_path`, which is authoritative. Only manual runs without it
  fall back to re-deriving Claude Code's folder name from the path (every
  non-alphanumeric character -> `-`, e.g. `D:\dow\X` -> `D--dow-X`) — an
  undocumented Claude Code detail that may change.
