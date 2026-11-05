#!/usr/bin/env python3
"""merge-settings.py — idempotently insert the claude-memory hooks into a
Claude Code settings.json, without touching any other hook:

  - SessionStart -> detect-and-map (graphify mapping, background)
  - SessionStart -> sync-sessions pull (Drive -> local transcripts)
  - Stop         -> sync-sessions push (local -> Drive transcripts)

and raise `cleanupPeriodDays` so Claude Code does not prune old transcripts.

Design goals (see docs/ARCHITECTURE.md):
  - Never lose existing hooks (e.g. an existing Stop hook stays untouched).
  - Never duplicate the SessionStart hook command if run again.
  - Always back up the original file before writing (timestamped backup if
    a .bak already exists, so history is preserved rather than overwritten).
  - Validate the merged JSON is well-formed before ever touching the real
    file: write to a temp file, json.load() it back, then os.replace()
    atomically.
  - Standard library only: json, os, sys, argparse, datetime, platform,
    shutil.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import re
import shutil
import sys

DEFAULT_MATCHER = "*"
HOOK_DESCRIPTION = (
    "Background: map current project into ~/.claude-memory and sync (non-blocking)"
)
# Session hooks use "" (all sources: startup/resume/clear/compact), matching
# the convention of the other hooks already present in the user's settings.
SESSION_SYNC_MATCHER = ""
# sync-sessions detaches itself after reading stdin; the timeout is only a
# safety net for the foreground part.
SESSION_SYNC_TIMEOUT_SECONDS = 30
MIN_CLEANUP_PERIOD_DAYS = 3650


def default_settings_path() -> str:
    home = os.path.expanduser("~")
    return os.path.join(home, ".claude", "settings.json")


def default_memory_dir() -> str:
    home = os.path.expanduser("~")
    return os.path.join(home, ".claude-memory")


def build_hook_command(memory_dir: str) -> str:
    """Build the async/background, non-blocking hook command for this OS."""
    system = platform.system()
    if system == "Windows":
        script_path = os.path.join(memory_dir, "bin", "detect-and-map.ps1")
        log_path = os.path.join(
            os.environ.get("TEMP", os.path.join(memory_dir, "tmp")),
            "claude-memory-detect-and-map.log",
        )
        # Start-Process with -NoNewWindow keeps it attached but non-blocking;
        # redirect stdout/stderr so the hook call itself returns immediately.
        return (
            'powershell -NoProfile -Command '
            f'"Start-Process -FilePath powershell -ArgumentList '
            f'\'-NoProfile\',\'-ExecutionPolicy\',\'Bypass\',\'-File\',\'{script_path}\' '
            f'-WindowStyle Hidden -RedirectStandardOutput \'{log_path}\' '
            f'-RedirectStandardError \'{log_path}\'"'
        )

    script_path = os.path.join(memory_dir, "bin", "detect-and-map.sh")
    log_path = "/tmp/claude-memory-detect-and-map.log"
    return f'nohup "{script_path}" >"{log_path}" 2>&1 &'


def build_session_sync_command(memory_dir: str, mode: str) -> str:
    """Command for `sync-sessions.{sh,ps1} <push|pull>`.

    The script reads the hook JSON from stdin and then detaches itself, so
    the command must NOT be wrapped in `nohup ... &` (a backgrounded command
    gets /dev/null as stdin and would lose the payload).
    """
    if platform.system() == "Windows":
        # Forward slashes survive both cmd.exe and Git Bash quoting rules.
        script_path = os.path.join(memory_dir, "bin", "sync-sessions.ps1").replace("\\", "/")
        return (
            "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass "
            f'-File "{script_path}" {mode}'
        )
    script_path = os.path.join(memory_dir, "bin", "sync-sessions.sh")
    return f'"{script_path}" {mode}'


def session_sync_pattern(mode: str) -> re.Pattern[str]:
    """Match any sync-sessions hook for `mode`, whatever path/quoting it uses,
    so re-running the installer with a different memory dir never duplicates."""
    return re.compile(rf"sync-sessions\.(sh|ps1)[\"']?\s+{mode}\b")


def load_json(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def backup_settings(path: str) -> str | None:
    if not os.path.exists(path):
        return None

    backup_path = path + ".bak"
    if os.path.exists(backup_path):
        epoch = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
        backup_path = f"{path}.bak.{epoch}"

    shutil.copy2(path, backup_path)
    return backup_path


def hook_command_exists(session_start_entries: list, command: str) -> bool:
    for entry in session_start_entries:
        for hook in entry.get("hooks", []):
            if hook.get("command") == command:
                return True
    return False


def hook_matching_exists(entries: list, pattern: re.Pattern[str]) -> bool:
    for entry in entries:
        for hook in entry.get("hooks", []):
            if pattern.search(str(hook.get("command", ""))):
                return True
    return False


def merge_hook(
    settings: dict,
    event: str,
    hook: dict,
    matcher: str,
    existing_pattern: re.Pattern[str] | None = None,
) -> dict:
    """Return a new settings dict with `hook` appended under `event`, unless
    an equivalent hook (same command, or matching `existing_pattern`) is
    already present. Never removes or reorders existing entries."""
    merged = json.loads(json.dumps(settings))
    merged.setdefault("hooks", {})
    entries = merged["hooks"].setdefault(event, [])

    if hook_command_exists(entries, hook["command"]):
        return merged
    if existing_pattern is not None and hook_matching_exists(entries, existing_pattern):
        return merged

    merged["hooks"][event] = entries + [{"matcher": matcher, "hooks": [hook]}]
    return merged


def merge_session_sync_hooks(settings: dict, memory_dir: str) -> dict:
    merged = settings
    for event, mode in (("SessionStart", "pull"), ("Stop", "push")):
        merged = merge_hook(
            merged,
            event,
            {
                "type": "command",
                "command": build_session_sync_command(memory_dir, mode),
                "timeout": SESSION_SYNC_TIMEOUT_SECONDS,
            },
            SESSION_SYNC_MATCHER,
            existing_pattern=session_sync_pattern(mode),
        )
    return merged


def ensure_cleanup_period(settings: dict, minimum: int) -> dict:
    """Raise cleanupPeriodDays to `minimum` if absent or lower; never lower it."""
    merged = json.loads(json.dumps(settings))
    current = merged.get("cleanupPeriodDays")
    if not isinstance(current, int) or isinstance(current, bool) or current < minimum:
        merged["cleanupPeriodDays"] = minimum
    return merged


def merge_session_start_hook(settings: dict, command: str) -> dict:
    """Return a new settings dict with the SessionStart hook merged in.

    Never mutates the input dict in place (immutability per coding
    standards) — builds and returns a new structure.
    """
    merged = json.loads(json.dumps(settings))  # deep copy, stdlib-only

    merged.setdefault("hooks", {})
    merged["hooks"].setdefault("SessionStart", [])

    session_start_entries = merged["hooks"]["SessionStart"]

    if hook_command_exists(session_start_entries, command):
        return merged

    new_hook_entry = {
        "matcher": DEFAULT_MATCHER,
        "hooks": [
            {
                "type": "command",
                "command": command,
                "description": HOOK_DESCRIPTION,
            }
        ],
    }
    merged["hooks"]["SessionStart"] = session_start_entries + [new_hook_entry]
    return merged


def write_settings_atomically(path: str, settings: dict) -> None:
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, sort_keys=False)
        f.write("\n")

    # Validate before replacing the real file.
    with open(tmp_path, "r", encoding="utf-8") as f:
        json.load(f)

    os.replace(tmp_path, path)


def parse_args(argv: list) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge the claude-memory hooks into settings.json"
    )
    parser.add_argument(
        "--settings-path",
        default=default_settings_path(),
        help="Path to the Claude Code settings.json to modify (default: ~/.claude/settings.json)",
    )
    parser.add_argument(
        "--memory-dir",
        default=default_memory_dir(),
        help="Path to the claude-memory repo (default: ~/.claude-memory)",
    )
    parser.add_argument(
        "--skip-session-sync",
        action="store_true",
        help="Do not add the sync-sessions hooks nor touch cleanupPeriodDays",
    )
    return parser.parse_args(argv)


def main(argv: list) -> int:
    args = parse_args(argv)
    settings_path = args.settings_path

    os.makedirs(os.path.dirname(settings_path) or ".", exist_ok=True)

    if os.path.exists(settings_path):
        try:
            existing_settings = load_json(settings_path)
        except json.JSONDecodeError as exc:
            print(
                f"ERROR: {settings_path} is not valid JSON, refusing to touch it: {exc}",
                file=sys.stderr,
            )
            return 1
    else:
        existing_settings = {}

    hook_command = build_hook_command(args.memory_dir)
    merged_settings = merge_session_start_hook(existing_settings, hook_command)
    if not args.skip_session_sync:
        merged_settings = merge_session_sync_hooks(merged_settings, args.memory_dir)
        merged_settings = ensure_cleanup_period(merged_settings, MIN_CLEANUP_PERIOD_DAYS)

    if merged_settings == existing_settings:
        print(f"{settings_path} already up to date, nothing to do")
        return 0

    backup_path = backup_settings(settings_path)
    if backup_path:
        print(f"Backed up existing settings to {backup_path}")
    else:
        print(f"No existing settings file at {settings_path}, creating a new one")

    try:
        write_settings_atomically(settings_path, merged_settings)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: failed to write merged settings: {exc}", file=sys.stderr)
        return 1

    print(f"claude-memory hooks merged into {settings_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
