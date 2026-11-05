<#
.SYNOPSIS
    Idempotent installer for claude-memory-sync (Windows). Re-running this
    script is always safe: every step checks current state before acting
    and never destroys existing data.
.PARAMETER SessionsDir
    Google Drive folder for Claude session transcripts (session sync). Falls
    back to $env:CLAUDE_SESSIONS_DIR, then the existing config\local.env,
    then an interactive prompt. With `iwr | iex` parameters cannot be passed,
    so use the environment variable instead.
.PARAMETER SkipSessionSync
    Do not configure session sync nor add its hooks
    ($env:CLAUDE_SKIP_SESSION_SYNC = "1" works too).
#>
param(
    [string]$SessionsDir = "",
    [switch]$SkipSessionSync
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeMemoryDir = $env:CLAUDE_MEMORY_DIR
if ([string]::IsNullOrWhiteSpace($ClaudeMemoryDir)) {
    $ClaudeMemoryDir = Join-Path $env:USERPROFILE ".claude-memory"
}
$ClaudeSettingsPath = $env:CLAUDE_SETTINGS_PATH
if ([string]::IsNullOrWhiteSpace($ClaudeSettingsPath)) {
    $ClaudeSettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
}
$SshDir = Join-Path $env:USERPROFILE ".ssh"
$SshKeyPath = Join-Path $SshDir "claude_memory_ed25519"
$SshConfigPath = Join-Path $SshDir "config"
$SshHostAlias = "github-claude-memory"
$MemoryRepoSshUrl = "git@${SshHostAlias}:GABRIEL-PI/claude-memory.git"
$MarkerStart = "# >>> claude-memory >>>"
$MarkerEnd = "# <<< claude-memory <<<"
$LocalEnvFile = Join-Path $ClaudeMemoryDir "config\local.env"
if (-not $SessionsDir -and $env:CLAUDE_SESSIONS_DIR) { $SessionsDir = $env:CLAUDE_SESSIONS_DIR }
if ($env:CLAUDE_SKIP_SESSION_SYNC -eq "1") { $SkipSessionSync = [switch]$true }

function Write-Log { param([string]$Message) Write-Host "[install.ps1] $Message" }
function Write-Warn { param([string]$Message) Write-Warning "[install.ps1] $Message" }
function Die { param([string]$Message) Write-Error "[install.ps1] ERROR: $Message"; exit 1 }

Write-Log "detected OS: Windows"

# --- step 1: Python 3.10+ ---------------------------------------------------
function Test-PythonVersionOk {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $cmd) { return $false }
    try {
        $verOutput = & $cmd.Source --version 2>&1
        if ($verOutput -match '(\d+)\.(\d+)') {
            $major = [int]$Matches[1]
            $minor = [int]$Matches[2]
            return ($major -gt 3) -or ($major -eq 3 -and $minor -ge 10)
        }
    } catch {
        return $false
    }
    return $false
}

if (Test-PythonVersionOk) {
    Write-Log "python >= 3.10 already present"
} else {
    Write-Log "python >= 3.10 not found, attempting install via winget"
    try {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
        }
    } catch {
        Write-Warn "winget install of Python failed: $_"
    }
    if (-not (Test-PythonVersionOk)) {
        Die "Python 3.10+ is required but could not be installed automatically. Please install it manually from https://www.python.org/downloads/ and re-run this script."
    }
}

# --- step 2: uv --------------------------------------------------------------
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Write-Log "uv already present"
} else {
    Write-Log "installing uv"
    try {
        Invoke-Expression (Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1")
    } catch {
        Die "failed to install uv: $_"
    }
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Die "uv installation did not result in a usable 'uv' command on PATH"
}

# --- step 3: graphify --------------------------------------------------------
if (Get-Command graphify -ErrorAction SilentlyContinue) {
    Write-Log "graphify already present"
} else {
    Write-Log "installing graphify via uv tool install"
    try {
        uv tool install graphifyy
    } catch {
        Die "failed to install graphify: $_"
    }
}

if (-not (Get-Command graphify -ErrorAction SilentlyContinue)) {
    Write-Warn "graphify still not on PATH after install; you may need to restart your shell"
}

# --- step 4: dedicated SSH key -----------------------------------------------
New-Item -ItemType Directory -Force -Path $SshDir | Out-Null

if (Test-Path $SshKeyPath) {
    Write-Log "SSH key $SshKeyPath already exists, reusing"
} else {
    Write-Log "generating dedicated SSH key at $SshKeyPath"
    ssh-keygen -t ed25519 -N '""' -f "$SshKeyPath" -C "claude-memory-sync"
    if ($LASTEXITCODE -ne 0) { Die "ssh-keygen failed" }
}

if (-not (Test-Path $SshConfigPath)) {
    New-Item -ItemType File -Path $SshConfigPath -Force | Out-Null
}

$existingConfig = Get-Content -Path $SshConfigPath -Raw -ErrorAction SilentlyContinue
if ($existingConfig -and $existingConfig.Contains($MarkerStart)) {
    Write-Log "SSH config block for claude-memory already present, leaving untouched"
} else {
    Write-Log "appending claude-memory SSH host block to $SshConfigPath"
    $block = @"

$MarkerStart
Host $SshHostAlias
  HostName github.com
  User git
  IdentityFile $SshKeyPath
  IdentitiesOnly yes
$MarkerEnd
"@
    Add-Content -Path $SshConfigPath -Value $block
}

Write-Log "Public key (register this as a write-access Deploy Key on the 'claude-memory' GitHub repo if not already done):"
Get-Content "$SshKeyPath.pub"

# --- step 5: validate SSH access --------------------------------------------
$sshTestOutput = ""
try {
    $sshTestOutput = (ssh -T -o StrictHostKeyChecking=accept-new "git@$SshHostAlias" 2>&1 | Out-String)
} catch {
    $sshTestOutput = "$_"
}
if ($sshTestOutput -match "successfully authenticated") {
    Write-Log "SSH access to github-claude-memory confirmed"
} else {
    Write-Warn "could not confirm SSH access yet (expected if the deploy key isn't registered on GitHub yet). Output was:"
    Write-Warn $sshTestOutput
}

# --- step 6: clone or update the memory repo --------------------------------
if (Test-Path (Join-Path $ClaudeMemoryDir ".git")) {
    Write-Log "$ClaudeMemoryDir already a git repo, pulling latest"
    Push-Location $ClaudeMemoryDir
    try {
        git pull --rebase --autostash
        if ($LASTEXITCODE -ne 0) { Write-Warn "git pull failed; leaving existing repo state as-is" }
    } finally {
        Pop-Location
    }
} elseif (Test-Path $ClaudeMemoryDir) {
    Write-Warn "$ClaudeMemoryDir exists but is not a git repo; leaving it untouched. Please resolve manually."
} else {
    Write-Log "cloning $MemoryRepoSshUrl into $ClaudeMemoryDir"
    git clone "$MemoryRepoSshUrl" "$ClaudeMemoryDir"
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "clone failed (deploy key likely not yet registered). Creating an empty local repo scaffold instead; re-run install.ps1 after registering the deploy key."
        New-Item -ItemType Directory -Force -Path $ClaudeMemoryDir | Out-Null
        Push-Location $ClaudeMemoryDir
        try { git init -q } finally { Pop-Location }
    }
}

# --- step 7: copy operational scripts into the memory repo ------------------
$destBin = Join-Path $ClaudeMemoryDir "bin"
New-Item -ItemType Directory -Force -Path $destBin | Out-Null
Copy-Item -Path (Join-Path $ScriptDir "bin\*") -Destination $destBin -Force -Recurse

# --- seed template files (never overwrite existing curated content) --------
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeMemoryDir "index") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeMemoryDir "global") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ClaudeMemoryDir "config") | Out-Null

function Copy-IfMissing {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path $Destination)) {
        Copy-Item -Path $Source -Destination $Destination
    }
}

Copy-IfMissing (Join-Path $ScriptDir "template\index\projects.json") (Join-Path $ClaudeMemoryDir "index\projects.json")
Copy-IfMissing (Join-Path $ScriptDir "template\index\machines.json") (Join-Path $ClaudeMemoryDir "index\machines.json")
Copy-IfMissing (Join-Path $ScriptDir "template\global\conventions.md") (Join-Path $ClaudeMemoryDir "global\conventions.md")
Copy-IfMissing (Join-Path $ScriptDir "template\.gitignore") (Join-Path $ClaudeMemoryDir ".gitignore")
Copy-IfMissing (Join-Path $ScriptDir ".gitattributes") (Join-Path $ClaudeMemoryDir ".gitattributes")
Copy-IfMissing (Join-Path $ScriptDir "template\settings.template.json") (Join-Path $ClaudeMemoryDir "config\settings.template.json")
Copy-IfMissing (Join-Path $ScriptDir "manifest.json") (Join-Path $ClaudeMemoryDir "manifest.json")

# The memory repo may predate session sync: make sure the per-machine config
# is never committed (append-only, idempotent).
$memoryGitignore = Join-Path $ClaudeMemoryDir ".gitignore"
$gitignoreLines = @(Get-Content -LiteralPath $memoryGitignore -ErrorAction SilentlyContinue)
if ($gitignoreLines -notcontains "config/local.env") {
    Add-Content -LiteralPath $memoryGitignore -Value "`n# Per-machine config (Drive path), never versioned`nconfig/local.env"
}

# --- step 7b: session sync folder (Google Drive) ----------------------------
function Get-LocalEnvValue {
    param([string]$Key)
    if (-not (Test-Path -LiteralPath $LocalEnvFile)) { return "" }
    $value = ""
    foreach ($line in Get-Content -LiteralPath $LocalEnvFile) {
        if ($line -match "^\s*$([regex]::Escape($Key))=(.*)$") { $value = $Matches[1].Trim().Trim('"') }
    }
    return $value
}

# Upsert KEY="VALUE", preserving any other keys.
function Set-LocalEnvValue {
    param([string]$Key, [string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LocalEnvFile) | Out-Null
    $lines = @(Get-Content -LiteralPath $LocalEnvFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Key))=" })
    $lines += "$Key=`"$Value`""
    $tmp = "$LocalEnvFile.tmp.$PID"
    Set-Content -LiteralPath $tmp -Value $lines -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $LocalEnvFile -Force
}

$ConfiguredSessionsDir = ""
if ($SkipSessionSync) {
    Write-Log "session sync skipped (-SkipSessionSync)"
} else {
    $currentSessionsDir = Get-LocalEnvValue "CLAUDE_SESSIONS_DIR"
    if (-not $SessionsDir -and $currentSessionsDir) {
        $SessionsDir = $currentSessionsDir
        Write-Log "session sync folder already configured: $SessionsDir"
    }
    if (-not $SessionsDir -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $suggested = ""
        # Drive root is localized: "My Drive" (EN) / "Meu Drive" (PT-BR).
        foreach ($root in @("G:\My Drive", "G:\Meu Drive")) {
            if (Test-Path -LiteralPath $root) { $suggested = Join-Path $root "claude-sessions"; break }
        }
        $prompt = "Google Drive folder for Claude sessions (empty = skip)"
        if ($suggested) { $prompt += " [$suggested]" }
        $answer = Read-Host $prompt
        $SessionsDir = if ($answer) { $answer } else { $suggested }
    }

    if (-not $SessionsDir) {
        Write-Warn "no session sync folder configured; hooks will be installed but stay inactive until CLAUDE_SESSIONS_DIR is set in $LocalEnvFile"
    } else {
        if (-not (Test-Path -LiteralPath $SessionsDir)) {
            if (Test-Path -LiteralPath (Split-Path -Parent $SessionsDir)) {
                try {
                    New-Item -ItemType Directory -Path $SessionsDir -ErrorAction Stop | Out-Null
                    Write-Log "created $SessionsDir"
                } catch {
                    Write-Warn "could not create $SessionsDir (read-only location? use a folder inside 'My Drive'/'Meu Drive'); NOT saving it"
                    $SessionsDir = ""
                }
            } else {
                Write-Warn "parent of $SessionsDir does not exist (Drive not mounted?); saving the path anyway"
            }
        }
        if ($SessionsDir -and $SessionsDir -ne $currentSessionsDir) {
            Set-LocalEnvValue "CLAUDE_SESSIONS_DIR" $SessionsDir
            Write-Log "saved CLAUDE_SESSIONS_DIR to $LocalEnvFile"
        }
        $ConfiguredSessionsDir = $SessionsDir
        if ($SessionsDir) { Write-Log "IMPORTANT: mark this folder 'Available offline' in Google Drive (or use Mirror mode), otherwise transcripts may be online-only placeholders." }
    }
}

# --- step 8: merge hooks into the user's real settings.json -----------------
Write-Log "merging claude-memory hooks into $ClaudeSettingsPath"
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue }
$mergeArgs = @((Join-Path $ScriptDir "bin\merge-settings.py"), "--settings-path", "$ClaudeSettingsPath", "--memory-dir", "$ClaudeMemoryDir")
if ($SkipSessionSync) { $mergeArgs += "--skip-session-sync" }
& $pythonCmd.Source @mergeArgs
if ($LASTEXITCODE -ne 0) { Die "merge-settings.py failed" }

# --- step 9: optional smoke test ---------------------------------------------
$smokeTestDir = $env:CLAUDE_MEMORY_SMOKE_TEST_DIR
if ($smokeTestDir -and (Test-Path $smokeTestDir)) {
    Write-Log "running smoke test against $smokeTestDir"
    Push-Location $smokeTestDir
    try {
        & (Join-Path $ClaudeMemoryDir "bin\detect-and-map.ps1")
    } catch {
        Write-Warn "smoke test run reported an error (non-fatal): $_"
    } finally {
        Pop-Location
    }
} else {
    Write-Log "no CLAUDE_MEMORY_SMOKE_TEST_DIR provided, skipping smoke test"
}

# --- step 10: summary ---------------------------------------------------------
Write-Host ""
Write-Host "==============================================================="
Write-Host "claude-memory-sync install complete."
Write-Host ""
Write-Host "Memory repo:      $ClaudeMemoryDir"
Write-Host "Settings merged:  $ClaudeSettingsPath (backup created alongside it)"
Write-Host "SSH key:          $SshKeyPath"
Write-Host "Sessions folder:  $(if ($ConfiguredSessionsDir) { $ConfiguredSessionsDir } else { '<not configured>' }) (config: $LocalEnvFile)"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. If you haven't already, register the public key printed above as a"
Write-Host "     write-access Deploy Key on the 'claude-memory' GitHub repository:"
Write-Host "       $SshKeyPath.pub"
Write-Host "  2. Re-run this script after registering the key if the initial clone"
Write-Host "     above fell back to an empty local scaffold."
Write-Host "  3. Start a new Claude Code session in any project - detect-and-map will"
Write-Host "     run automatically in the background."
Write-Host "==============================================================="
