<#
.SYNOPSIS
    Idempotent installer for claude-memory-sync (Windows). Re-running this
    script is always safe: every step checks current state before acting
    and never destroys existing data.
#>
param()

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

# --- step 8: merge SessionStart hook into the user's real settings.json ----
Write-Log "merging SessionStart hook into $ClaudeSettingsPath"
$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python3 -ErrorAction SilentlyContinue }
& $pythonCmd.Source (Join-Path $ScriptDir "bin\merge-settings.py") --settings-path "$ClaudeSettingsPath" --memory-dir "$ClaudeMemoryDir"
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
