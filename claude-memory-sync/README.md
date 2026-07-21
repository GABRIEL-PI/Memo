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
6. Merge a `SessionStart` hook into your real `~/.claude/settings.json`
   (after backing it up), without touching any hook you already have.

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
  `/tmp/claude-memory-*.log` files yourself.
