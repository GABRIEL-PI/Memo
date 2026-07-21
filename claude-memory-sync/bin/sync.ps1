<#
.SYNOPSIS
    Pull-rebase, stage only touched files by explicit name, commit, push with
    bounded retry-on-reject. Mirrors bin/sync.sh. Never throws out to the
    calling process — always exits 0 so a hook chain is not blocked.
.PARAMETER Slug
    Project slug, used for the commit message and to scope file discovery.
.PARAMETER Files
    Explicit repo-relative file paths to stage. If omitted, `git status
    --porcelain` is filtered to projects/<Slug>/ and index/ paths only.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Slug,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Files = @()
)

$ErrorActionPreference = "Stop"
$MaxPushAttempts = 3

function Write-Log {
    param([string]$Message)
    Write-Host "[sync.ps1] $Message"
}

$claudeMemoryDir = $env:CLAUDE_MEMORY_DIR
if ([string]::IsNullOrWhiteSpace($claudeMemoryDir)) {
    $claudeMemoryDir = Join-Path $env:USERPROFILE ".claude-memory"
}

try {
    if (-not (Test-Path (Join-Path $claudeMemoryDir ".git"))) {
        Write-Log "no git repo at $claudeMemoryDir, skipping sync"
        exit 0
    }

    Push-Location $claudeMemoryDir
    try {
        git pull --rebase --autostash 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "git pull --rebase --autostash failed, continuing to attempt local commit only"
        }

        $filesToAdd = @()
        if ($Files.Count -gt 0) {
            $filesToAdd = $Files
        } else {
            $porcelain = git status --porcelain
            foreach ($line in $porcelain) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $relPath = $line.Substring(3)
                if ($relPath -like "projects/$Slug/*" -or $relPath -like "index/*") {
                    $filesToAdd += $relPath
                }
            }
        }

        if ($filesToAdd.Count -eq 0) {
            Write-Log "nothing to stage for slug=$Slug"
            exit 0
        }

        foreach ($f in $filesToAdd) {
            if (Test-Path $f) {
                git add -- "$f"
            }
        }

        git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Log "nothing staged after filtering, skipping commit"
            exit 0
        }

        $hostnameValue = $env:COMPUTERNAME
        if ([string]::IsNullOrWhiteSpace($hostnameValue)) {
            $hostnameValue = "unknown-host"
        }
        $timestampValue = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

        git commit -m "map: $Slug @ $hostnameValue $timestampValue" | Out-Null

        $attempt = 1
        $delaySeconds = 2
        while ($attempt -le $MaxPushAttempts) {
            git push 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "push succeeded on attempt $attempt"
                exit 0
            }

            Write-Log "push attempt $attempt failed"

            if ($attempt -eq $MaxPushAttempts) {
                Write-Log "giving up after $MaxPushAttempts attempts, local commit preserved"
                exit 0
            }

            Start-Sleep -Seconds $delaySeconds
            $delaySeconds = $delaySeconds * 2

            git pull --rebase --autostash 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "retry pull --rebase failed"
            }

            $attempt++
        }
    } finally {
        Pop-Location
    }
} catch {
    Write-Log "unexpected error, exiting cleanly without blocking caller: $_"
    exit 0
}
