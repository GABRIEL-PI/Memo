<#
.SYNOPSIS
    Sync Claude Code session transcripts through a cloud-synced folder
    (Google Drive), keyed by the stable project slug. Mirrors
    bin/sync-sessions.sh.
.DESCRIPTION
    push (Stop hook):         local project folder -> CLAUDE_SESSIONS_DIR\<slug>
    pull (SessionStart hook): CLAUDE_SESSIONS_DIR\<slug> -> local project folder

    Contract: never block, never fail loudly, always exit 0. Silent no-op if
    CLAUDE_SESSIONS_DIR is unset or does not exist. Never deletes anything at
    the destination. The hook invocation reads the JSON payload from stdin
    and re-launches itself hidden in the background with -Foreground.
.PARAMETER Mode
    push | pull
#>
param(
    [Parameter(Position = 0)][string]$Mode = "",
    [string]$Cwd = "",
    [string]$SessionId = "",
    [string]$Transcript = "",
    [string]$ArgsFile = "",
    [switch]$Foreground
)

$ErrorActionPreference = "Stop"

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$ClaudeMemoryDir = if ($env:CLAUDE_MEMORY_DIR) { $env:CLAUDE_MEMORY_DIR } else { Join-Path $env:USERPROFILE ".claude-memory" }
$ClaudeProjectsDir = if ($env:CLAUDE_PROJECTS_DIR) { $env:CLAUDE_PROJECTS_DIR } else { Join-Path $env:USERPROFILE ".claude\projects" }
$LocalEnvFile = if ($env:CLAUDE_MEMORY_LOCAL_ENV) { $env:CLAUDE_MEMORY_LOCAL_ENV } else { Join-Path $ClaudeMemoryDir "config\local.env" }
$TempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LogFile = if ($env:CLAUDE_SESSION_SYNC_LOG) { $env:CLAUDE_SESSION_SYNC_LOG } else { Join-Path $TempDir "claude-memory-sync-sessions.log" }
$LockStaleSeconds = 900
$LockWaitSeconds = if ($env:CLAUDE_SESSION_SYNC_LOCK_WAIT) { [int]$env:CLAUDE_SESSION_SYNC_LOCK_WAIT } else { 60 }
$HostName = $env:COMPUTERNAME
if (-not $HostName) { $HostName = "unknown-host" }

$script:Copied = 0
$script:Conflicts = 0

function Write-Log {
    param([string]$Message)
    try {
        $ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        Add-Content -LiteralPath $LogFile -Value "$ts [sync-sessions.ps1] $Message" -Encoding UTF8
    } catch { }
}

function Read-LocalEnvValue {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $LocalEnvFile)) { return "" }
    $value = ""
    foreach ($line in Get-Content -LiteralPath $LocalEnvFile) {
        if ($line -match "^\s*$([regex]::Escape($Key))=(.*)$") { $value = $Matches[1].Trim() }
    }
    $value = $value.Trim('"').Trim("'")
    if ($value -eq "~") { $value = $env:USERPROFILE }
    elseif ($value.StartsWith("~/") -or $value.StartsWith("~\")) { $value = Join-Path $env:USERPROFILE $value.Substring(2) }
    return $value
}

# Claude Code folder name: every non-[A-Za-z0-9] UTF-16 code unit -> "-"
# (D:\dow\X -> D--dow-X). Only used when transcript_path is unavailable.
function ConvertTo-ProjectDirName {
    param([string]$Path)
    return ($Path -creplace '[^A-Za-z0-9]', '-')
}

function Test-IsPrefixOf {
    param([string]$Small, [string]$Big)
    $bufSize = 1MB
    $a = $null; $b = $null
    try {
        $a = [System.IO.File]::Open($Small, 'Open', 'Read', 'ReadWrite')
        $b = [System.IO.File]::Open($Big, 'Open', 'Read', 'ReadWrite')
        if ($a.Length -gt $b.Length) { return $false }
        $bufA = New-Object byte[] $bufSize
        $bufB = New-Object byte[] $bufSize
        $remaining = $a.Length
        while ($remaining -gt 0) {
            $want = [int][Math]::Min($bufSize, $remaining)
            $ra = 0; while ($ra -lt $want) { $n = $a.Read($bufA, $ra, $want - $ra); if ($n -le 0) { return $false }; $ra += $n }
            $rb = 0; while ($rb -lt $want) { $n = $b.Read($bufB, $rb, $want - $rb); if ($n -le 0) { return $false }; $rb += $n }
            for ($i = 0; $i -lt $want; $i++) { if ($bufA[$i] -ne $bufB[$i]) { return $false } }
            $remaining -= $want
        }
        return $true
    } catch {
        return $false
    } finally {
        if ($a) { $a.Dispose() }
        if ($b) { $b.Dispose() }
    }
}

function Test-SameContent {
    param([string]$A, [string]$B)
    if ((Get-Item -LiteralPath $A).Length -ne (Get-Item -LiteralPath $B).Length) { return $false }
    return (Test-IsPrefixOf -Small $A -Big $B)
}

# Atomic: copy to a hidden temp file in the destination dir, then rename.
function Copy-Atomic {
    param([string]$Src, [string]$Dst)
    $dstDir = Split-Path -Parent $Dst
    $tmp = Join-Path $dstDir (".{0}.sync-tmp.{1}" -f (Split-Path -Leaf $Dst), $PID)
    try {
        New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
        [System.IO.File]::Copy($Src, $tmp, $true)
        [System.IO.File]::SetLastWriteTimeUtc($tmp, [System.IO.File]::GetLastWriteTimeUtc($Src))
        if (Test-Path -LiteralPath $Dst) {
            try {
                [System.IO.File]::Replace($tmp, $Dst, [NullString]::Value)
            } catch {
                # Some virtual filesystems (e.g. Drive for desktop) reject
                # ReplaceFile; fall back to an overwriting copy.
                [System.IO.File]::Copy($tmp, $Dst, $true)
                [System.IO.File]::SetLastWriteTimeUtc($Dst, [System.IO.File]::GetLastWriteTimeUtc($Src))
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        } else {
            [System.IO.File]::Move($tmp, $Dst)
        }
        return $true
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-Log "copy failed: $Src -> ${Dst}: $_"
        return $false
    }
}

function Invoke-Conflict {
    param([string]$Src, [string]$Rel)
    $script:Conflicts++
    if ($Mode -eq "push") {
        $conflictDst = Join-Path (Join-Path (Join-Path $RemoteDir "_conflicts") $HostName) $Rel
        $existingSize = if (Test-Path -LiteralPath $conflictDst) { (Get-Item -LiteralPath $conflictDst).Length } else { -1 }
        if ((Get-Item -LiteralPath $Src).Length -ne $existingSize) { [void](Copy-Atomic -Src $Src -Dst $conflictDst) }
        Write-Log "CONFLICT $Slug/${Rel}: local and Drive diverged; local copy kept at $conflictDst"
    } else {
        Write-Log "CONFLICT $Slug/${Rel}: Drive and local diverged; kept local copy untouched"
    }
}

# Transcripts are append-only: a destination that is a byte-prefix of the
# source is a safe fast-forward; anything else is "destination ahead" or
# divergence.
function Sync-File {
    param([string]$Src, [string]$Dst, [string]$Rel)
    if (-not (Test-Path -LiteralPath $Dst)) {
        if (Copy-Atomic -Src $Src -Dst $Dst) { $script:Copied++ }
        return
    }
    $srcSize = (Get-Item -LiteralPath $Src).Length
    $dstSize = (Get-Item -LiteralPath $Dst).Length

    if ($Rel.EndsWith(".jsonl")) {
        if ($srcSize -eq $dstSize) { return }
        if ($srcSize -gt $dstSize) {
            if (Test-IsPrefixOf -Small $Dst -Big $Src) {
                if (Copy-Atomic -Src $Src -Dst $Dst) { $script:Copied++ }
            } else {
                Invoke-Conflict -Src $Src -Rel $Rel
            }
            return
        }
        if (-not (Test-IsPrefixOf -Small $Src -Big $Dst)) { Invoke-Conflict -Src $Src -Rel $Rel }
        return
    }

    if (Test-SameContent -A $Src -B $Dst) { return }
    if ((Get-Item -LiteralPath $Src).LastWriteTimeUtc -gt (Get-Item -LiteralPath $Dst).LastWriteTimeUtc) {
        if (Copy-Atomic -Src $Src -Dst $Dst) { $script:Copied++ }
    }
}

# Every <id>.jsonl plus its sibling <id>\ directory; memory\ is never touched.
function Sync-Tree {
    param([string]$From, [string]$To, [string]$SkipId)
    foreach ($f in Get-ChildItem -LiteralPath $From -Filter "*.jsonl" -File -ErrorAction SilentlyContinue) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        if ($SkipId -and $id -eq $SkipId) { continue }
        Sync-File -Src $f.FullName -Dst (Join-Path $To $f.Name) -Rel $f.Name
        $subDir = Join-Path $From $id
        if (Test-Path -LiteralPath $subDir -PathType Container) {
            foreach ($sub in Get-ChildItem -LiteralPath $subDir -Recurse -File -Force -ErrorAction SilentlyContinue) {
                if ($sub.Name -like ".*.sync-tmp.*") { continue }
                $rel = $sub.FullName.Substring($From.TrimEnd('\', '/').Length + 1)
                Sync-File -Src $sub.FullName -Dst (Join-Path $To $rel) -Rel $rel
            }
        }
    }
}

try {
    if ($Mode -ne "push" -and $Mode -ne "pull") {
        Write-Log "invalid mode '$Mode' (expected push|pull)"
        exit 0
    }

    $SessionsDir = $env:CLAUDE_SESSIONS_DIR
    if ([string]::IsNullOrWhiteSpace($SessionsDir)) { $SessionsDir = Read-LocalEnvValue "CLAUDE_SESSIONS_DIR" }
    if ([string]::IsNullOrWhiteSpace($SessionsDir)) { exit 0 }
    if (-not (Test-Path -LiteralPath $SessionsDir -PathType Container)) {
        Write-Log "CLAUDE_SESSIONS_DIR '$SessionsDir' does not exist (Drive not mounted?), skipping $Mode"
        exit 0
    }

    if (-not $Foreground) {
        # Hook mode: consume the stdin payload, then detach.
        $raw = ""
        if ([Console]::IsInputRedirected) {
            try { $raw = [Console]::In.ReadToEnd() } catch { $raw = "" }
        }
        if ($raw) {
            try {
                $payload = $raw | ConvertFrom-Json
                if (-not $Cwd -and $payload.cwd) { $Cwd = [string]$payload.cwd }
                if (-not $SessionId -and $payload.session_id) { $SessionId = [string]$payload.session_id }
                if (-not $Transcript -and $payload.transcript_path) { $Transcript = [string]$payload.transcript_path }
            } catch {
                Write-Log "could not parse hook payload: $_"
            }
        }
        if (-not $Cwd) { $Cwd = (Get-Location).Path }

        # Pass values through a temp JSON file: Start-Process argument quoting
        # is fragile with spaces/quotes in paths.
        $argsFile = Join-Path $TempDir ("claude-session-sync-args-{0}.json" -f [guid]::NewGuid().ToString("N"))
        @{ cwd = $Cwd; session_id = $SessionId; transcript_path = $Transcript } |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $argsFile -Encoding UTF8
        $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" $Mode -Foreground -ArgsFile `"$argsFile`""
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden | Out-Null
        exit 0
    }
} catch {
    Write-Log "unexpected error before detaching: $_"
    exit 0
}

# --- background worker ---------------------------------------------------
$LockDir = $null
$LockHeld = $false
try {
    if ($ArgsFile -and (Test-Path -LiteralPath $ArgsFile)) {
        try {
            $a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
            if (-not $Cwd) { $Cwd = [string]$a.cwd }
            if (-not $SessionId) { $SessionId = [string]$a.session_id }
            if (-not $Transcript) { $Transcript = [string]$a.transcript_path }
        } finally {
            Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $Cwd) { $Cwd = (Get-Location).Path }

    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction SilentlyContinue
    }

    if ($Transcript) {
        $LocalDir = Split-Path -Parent $Transcript
    } else {
        $encoded = ConvertTo-ProjectDirName -Path $Cwd
        if ($encoded.Length -le 200) {
            $LocalDir = Join-Path $ClaudeProjectsDir $encoded
        } else {
            $candidates = @(Get-ChildItem -LiteralPath $ClaudeProjectsDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name.StartsWith($encoded.Substring(0, 200)) })
            if ($candidates.Count -ne 1) {
                Write-Log "cannot resolve long project dir for '$Cwd' ($($candidates.Count) candidates), skipping"
                exit 0
            }
            $LocalDir = $candidates[0].FullName
        }
    }

    if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) {
        Write-Log "cannot resolve cwd '$Cwd', skipping $Mode"
        exit 0
    }

    $Slug = (& (Join-Path $ScriptDir "slug.ps1") -Path $Cwd 2>$null | Select-Object -First 1)
    if (-not $Slug) {
        Write-Log "could not derive slug for $Cwd, skipping $Mode"
        exit 0
    }
    $Slug = $Slug.Trim()
    $RemoteDir = Join-Path $SessionsDir $Slug

    # Per-slug lock (local, never on the Drive). Wait instead of skipping so
    # the push after a session's last turn is not lost.
    $LockDir = Join-Path $TempDir "claude-session-sync-$Slug.lock"
    for ($attempt = 0; $attempt -lt $LockWaitSeconds; $attempt++) {
        try {
            [void](New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop)
            $LockHeld = $true
            break
        } catch {
            try {
                $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockDir).LastWriteTimeUtc).TotalSeconds
                if ($age -gt $LockStaleSeconds) {
                    Write-Log "removing stale lock $LockDir (age $([int]$age)s)"
                    Remove-Item -LiteralPath $LockDir -Force -ErrorAction SilentlyContinue
                    continue
                }
            } catch { }
            Start-Sleep -Seconds 1
        }
    }
    if (-not $LockHeld) {
        Write-Log "$Mode for ${Slug}: lock busy for ${LockWaitSeconds}s, skipping"
        exit 0
    }

    if ($Mode -eq "push") {
        if (-not (Test-Path -LiteralPath $LocalDir -PathType Container)) { exit 0 }
        New-Item -ItemType Directory -Force -Path $RemoteDir | Out-Null
        Sync-Tree -From $LocalDir -To $RemoteDir -SkipId ""
    } else {
        if (-not (Test-Path -LiteralPath $RemoteDir -PathType Container)) { exit 0 }
        New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
        Sync-Tree -From $RemoteDir -To $LocalDir -SkipId $SessionId
    }

    if ($script:Copied -gt 0 -or $script:Conflicts -gt 0) {
        Write-Log "$Mode slug=$Slug local=$LocalDir copied=$($script:Copied) conflicts=$($script:Conflicts)"
    }
} catch {
    Write-Log "unexpected error during ${Mode}: $_"
} finally {
    if ($LockHeld -and $LockDir) { Remove-Item -LiteralPath $LockDir -Force -ErrorAction SilentlyContinue }
}
exit 0
