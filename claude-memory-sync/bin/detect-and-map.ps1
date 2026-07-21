<#
.SYNOPSIS
    SessionStart hook entry point (Windows). Maps the current project into
    %USERPROFILE%\.claude-memory via `graphify`, then syncs the memory repo.
.DESCRIPTION
    Mirrors bin/detect-and-map.sh. MUST NEVER block the Claude Code session
    and MUST NEVER throw an unhandled error out to the caller — every failure
    path logs and exits 0.
#>
param()

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeMemoryDir = $env:CLAUDE_MEMORY_DIR
if ([string]::IsNullOrWhiteSpace($ClaudeMemoryDir)) {
    $ClaudeMemoryDir = Join-Path $env:USERPROFILE ".claude-memory"
}

function Write-Log {
    param([string]$Message)
    Write-Host "[detect-and-map.ps1] $Message"
}

function Get-ContentHash {
    param([string]$Dir)
    Push-Location $Dir
    try {
        $gitHead = $null
        try { $gitHead = (git rev-parse HEAD 2>$null) } catch { $gitHead = $null }
        if ($LASTEXITCODE -eq 0 -and $gitHead) {
            return "git:$gitHead"
        }
    } finally {
        Pop-Location
    }

    try {
        $files = Get-ChildItem -Path $Dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' }
        $joined = ($files | Sort-Object FullName | ForEach-Object { "$($_.LastWriteTimeUtc.Ticks) $($_.FullName)" }) -join "`n"
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
            $hashBytes = $sha256.ComputeHash($bytes)
            $hex = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
            return "mtime:$($hex.Substring(0,16))"
        } finally {
            $sha256.Dispose()
        }
    } catch {
        return "mtime:unknown"
    }
}

function Test-Prerequisites {
    $missing = @()
    $python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $python) {
        return "python3 not found"
    }
    try {
        $verOutput = & $python.Source --version 2>&1
        if ($verOutput -match '(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            if ($major -lt 3 -or ($major -eq 3 -and $minor -lt 10)) {
                return "python >= 3.10 required, found $major.$minor"
            }
        }
    } catch {
        return "unable to determine python version"
    }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        return "uv not found"
    }
    if (-not (Get-Command graphify -ErrorAction SilentlyContinue)) {
        return "graphify not found"
    }
    return $null
}

function Enter-IndexLock {
    # Short-lived, granular lock protecting only the shared index/projects.json
    # read-modify-write. Distinct from (and narrower than) the per-slug
    # .lock file: this one is held only for the duration of a single index
    # update, never across the graphify call, so concurrent sessions for
    # DIFFERENT projects never wait on each other for long.
    param([string]$LockDir)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    return $false
}

function Exit-IndexLock {
    param([string]$LockDir)
    Remove-Item -Path $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-PendingStatus {
    param([string]$IndexPath, [string]$Slug, [string]$Path, [string]$Reason)
    $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
    if (-not $pythonCmd) {
        Write-Log "pending: $Reason (and python unavailable to persist status)"
        return
    }
    $pyScript = @'
import json, os, sys
index_path, slug, path, reason = sys.argv[1:5]
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
    data["projects"].append({"slug": slug, "path_by_host": path, "status": "pending", "pending_reason": reason})
tmp_path = index_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp_path, index_path)
'@
    $tmpScript = New-TemporaryFile
    Set-Content -Path $tmpScript -Value $pyScript -Encoding utf8
    $indexLockDir = Join-Path (Split-Path -Parent $IndexPath) ".index.lock"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $IndexPath) | Out-Null
    if (-not (Enter-IndexLock -LockDir $indexLockDir)) {
        Write-Log "could not acquire index lock, skipping pending-status index update this time"
        Remove-Item -Path $tmpScript -ErrorAction SilentlyContinue
        return
    }
    try {
        & $pythonCmd.Source $tmpScript $IndexPath $Slug $Path $Reason 2>$null | Out-Null
    } catch {
        Write-Log "failed to persist pending status: $_"
    } finally {
        Exit-IndexLock -LockDir $indexLockDir
        Remove-Item -Path $tmpScript -ErrorAction SilentlyContinue
    }
}

try {
    $targetDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { (Get-Location).Path }
    $canonicalPath = (Resolve-Path -LiteralPath $targetDir -ErrorAction Stop).ProviderPath

    $slug = & "$ScriptDir\slug.ps1" -Path $canonicalPath
    if ([string]::IsNullOrWhiteSpace($slug)) {
        Write-Log "could not derive slug for $canonicalPath, exiting quietly"
        exit 0
    }

    $projectsIndex = Join-Path $ClaudeMemoryDir "index\projects.json"
    $projectDir = Join-Path $ClaudeMemoryDir "projects\$slug"
    $lockFile = Join-Path $projectDir ".lock"

    $currentHash = Get-ContentHash -Dir $canonicalPath

    if (Test-Path $projectsIndex) {
        $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
        if ($pythonCmd) {
            $checkScript = @'
import json, sys
index_path, slug, current_hash = sys.argv[1:4]
try:
    with open(index_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    print("no"); sys.exit(0)
for project in data.get("projects", []):
    if project.get("slug") == slug:
        if project.get("last_content_hash") == current_hash and project.get("status") == "mapped":
            print("yes"); sys.exit(0)
        break
print("no")
'@
            $tmpCheck = New-TemporaryFile
            Set-Content -Path $tmpCheck -Value $checkScript -Encoding utf8
            try {
                $already = & $pythonCmd.Source $tmpCheck $projectsIndex $slug $currentHash 2>$null
                if ($already -eq "yes") {
                    Write-Log "slug=$slug already mapped at current hash, nothing to do"
                    exit 0
                }
            } finally {
                Remove-Item -Path $tmpCheck -ErrorAction SilentlyContinue
            }
        }
    }

    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

    # Atomic exclusive lock acquisition: a single New-Item call is the only
    # check we perform. If the file already exists, New-Item throws and the
    # catch block IS the "already locked" signal — there must be no separate
    # Test-Path check beforehand, since that would reintroduce the TOCTOU gap
    # (two sessions could both pass Test-Path before either creates the file).
    try {
        New-Item -ItemType File -Path $lockFile -ErrorAction Stop | Out-Null
    } catch {
        Write-Log "slug=$slug already locked by another process, exiting immediately"
        exit 0
    }

    try {
        $prereqError = Test-Prerequisites
        if ($prereqError) {
            Write-PendingStatus -IndexPath $projectsIndex -Slug $slug -Path $canonicalPath -Reason $prereqError
            Write-Log "prerequisites missing ($prereqError), recorded pending status, exiting quietly"
            exit 0
        }

        $tmpOutDir = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName()))
        try {
            # graphify >= 0.9.x requires an explicit subcommand. `extract` runs
            # headless AST extraction (--code-only: no API key, skips
            # doc/paper/image files) into "$tmpOutDir\graphify-out\";
            # `cluster-only` then (re)clusters and writes GRAPH_REPORT.md. With
            # no LLM backend configured, cluster-only degrades gracefully to
            # "Community N" placeholder labels instead of failing.
            $graphifyOutDir = Join-Path $tmpOutDir.FullName "graphify-out"

            Push-Location $canonicalPath
            try {
                & graphify extract . --output $tmpOutDir.FullName --code-only *> (Join-Path $env:TEMP "claude-memory-graphify.log")
                $graphifyExit = $LASTEXITCODE
            } finally {
                Pop-Location
            }

            if ($graphifyExit -eq 0) {
                & graphify cluster-only $tmpOutDir.FullName *>> (Join-Path $env:TEMP "claude-memory-graphify.log")
                $graphifyExit = $LASTEXITCODE
            }

            $graphJson = Join-Path $graphifyOutDir "graph.json"
            $graphReport = Join-Path $graphifyOutDir "GRAPH_REPORT.md"

            if ($graphifyExit -ne 0 -or -not (Test-Path $graphJson) -or -not (Test-Path $graphReport)) {
                Write-PendingStatus -IndexPath $projectsIndex -Slug $slug -Path $canonicalPath -Reason "graphify run failed or output incomplete"
                Write-Log "graphify failed for slug=$slug, recorded pending status, exiting quietly"
                exit 0
            }

            Copy-Item -Path $graphJson -Destination (Join-Path $projectDir "graph.json") -Force
            Copy-Item -Path $graphReport -Destination (Join-Path $projectDir "GRAPH_REPORT.md") -Force
            # graph.html (if produced) is intentionally discarded — never versioned.
        } finally {
            Remove-Item -Path $tmpOutDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

        $hostnameValue = $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($hostnameValue)) { $hostnameValue = "unknown-host" }
        $timestampValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $isLocalOnly = $slug.StartsWith("local_")

        $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
        if ($pythonCmd) {
            # meta.json is per-slug state, already protected by the outer
            # per-slug $lockFile above — no extra locking needed here.
            $metaScript = @'
import json, os, sys
(meta_path, slug, path, host, timestamp, content_hash, is_local_only) = sys.argv[1:8]
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
'@
            $tmpMeta = New-TemporaryFile
            Set-Content -Path $tmpMeta -Value $metaScript -Encoding utf8
            try {
                & $pythonCmd.Source $tmpMeta (Join-Path $projectDir "meta.json") $slug $canonicalPath $hostnameValue $timestampValue $currentHash $(if ($isLocalOnly) { "true" } else { "false" }) 2>$null | Out-Null
            } finally {
                Remove-Item -Path $tmpMeta -ErrorAction SilentlyContinue
            }

            # index/projects.json IS shared across every project on this
            # machine — a second, narrower lock (index/.index.lock) protects
            # only this read-modify-write, held briefly and never across the
            # (potentially slow) graphify call above. On contention we retry
            # a few times and, failing that, skip the index update rather
            # than block the session.
            $indexScript = @'
import json, os, sys
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
    index_data["projects"].append({"slug": slug, "path_by_host": path, "last_mapped_at": timestamp, "last_content_hash": content_hash, "status": "mapped"})
index_tmp = index_path + ".tmp"
with open(index_tmp, "w", encoding="utf-8") as f:
    json.dump(index_data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(index_tmp, index_path)
'@
            $tmpIndex = New-TemporaryFile
            Set-Content -Path $tmpIndex -Value $indexScript -Encoding utf8
            $indexLockDir = Join-Path (Split-Path -Parent $projectsIndex) ".index.lock"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $projectsIndex) | Out-Null
            if (Enter-IndexLock -LockDir $indexLockDir) {
                try {
                    & $pythonCmd.Source $tmpIndex $projectsIndex $slug $canonicalPath $timestampValue $currentHash 2>$null | Out-Null
                } finally {
                    Exit-IndexLock -LockDir $indexLockDir
                }
            } else {
                Write-Log "could not acquire index lock after retries, skipping index/projects.json update this time"
            }
            Remove-Item -Path $tmpIndex -ErrorAction SilentlyContinue
        }

        Write-Log "mapped slug=$slug successfully, syncing"
        & "$ScriptDir\sync.ps1" -Slug $slug -Files @(
            "projects/$slug/graph.json",
            "projects/$slug/GRAPH_REPORT.md",
            "projects/$slug/meta.json",
            "index/projects.json"
        ) *> (Join-Path $env:TEMP "claude-memory-sync-from-detect.log")
    } finally {
        Remove-Item -Path $lockFile -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "unexpected error, exiting cleanly without blocking the session: $_"
    exit 0
}

exit 0
