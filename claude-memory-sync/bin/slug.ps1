<#
.SYNOPSIS
    Derive a stable, cross-machine project slug for a given directory.
.DESCRIPTION
    Mirrors bin/slug.sh. See docs/ARCHITECTURE.md for the slug rules:
      1. Git repo with an `origin` remote -> host/owner/repo, lowercased,
         "/" replaced with "_".
      2. Otherwise -> local_<folder-name>_<hash8-of-canonical-path>, and the
         caller is expected to mark meta.json with "local-only": true.
.PARAMETER Path
    Directory to derive the slug for. Defaults to the current directory.
#>
param(
    [string]$Path = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

function ConvertFrom-RemoteUrl {
    param([string]$RemoteUrl)

    $normalized = $RemoteUrl

    if ($normalized -match '^git@([^:]+):(.+)$') {
        $normalized = "$($Matches[1])/$($Matches[2])"
    }

    $normalized = $normalized -replace '^ssh://git@', ''
    $normalized = $normalized -replace '^ssh://', ''
    $normalized = $normalized -replace '^https://', ''
    $normalized = $normalized -replace '^http://', ''
    $normalized = $normalized -replace '\.git$', ''
    $normalized = $normalized.TrimEnd('/')

    $normalized = $normalized.ToLowerInvariant()
    return ($normalized -replace '/', '_')
}

function Get-Sha256Hash8 {
    param([string]$InputString)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
        $hashBytes = $sha256.ComputeHash($bytes)
        $hex = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 8)
    } finally {
        $sha256.Dispose()
    }
}

try {
    $canonicalPath = (Resolve-Path -LiteralPath $Path).ProviderPath

    $slug = $null
    Push-Location $canonicalPath
    try {
        $gitTopLevel = $null
        try {
            $gitTopLevel = (git rev-parse --show-toplevel 2>$null)
        } catch {
            $gitTopLevel = $null
        }

        if ($LASTEXITCODE -eq 0 -and $gitTopLevel) {
            $remoteUrl = $null
            try {
                $remoteUrl = (git remote get-url origin 2>$null)
            } catch {
                $remoteUrl = $null
            }
            if ($LASTEXITCODE -eq 0 -and $remoteUrl) {
                $slug = ConvertFrom-RemoteUrl -RemoteUrl $remoteUrl.Trim()
            }
        }
    } finally {
        Pop-Location
    }

    if (-not $slug) {
        $folderName = Split-Path -Leaf $canonicalPath
        $hash8 = Get-Sha256Hash8 -InputString $canonicalPath
        $slug = "local_${folderName}_${hash8}"
    }

    Write-Output $slug
} catch {
    Write-Error "slug.ps1: failed to derive slug: $_"
    exit 1
}
