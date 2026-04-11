#Requires -Version 7.0
<#
.SYNOPSIS
    Syncs ALL required secrets from the local AitherSecrets vault to GitHub repo secrets.

.DESCRIPTION
    Two-way secret management for AitherOS:

    1. Local vault (AitherSecrets :8111) is the SOURCE OF TRUTH
    2. This script PUSHES secrets TO GitHub for use in CI/CD workflows
    3. GitHub secrets are write-only by design — you can't read them back
    4. Partners clone the repo, run the bootstrap, and set their own secrets

    Secret tiers:
    - CRITICAL:  Deployment secrets (SSH keys, master keys) — required for ring promotions
    - HIGH:      LLM API keys — required for inference
    - MEDIUM:    Social/platform integrations — optional, per-feature
    - LOW:       Development conveniences — nice to have

    This script reads from the vault (or env vars or .env files) and pushes
    to GitHub using `gh secret set`.

.PARAMETER Tier
    Which tier(s) to sync: Critical, High, Medium, Low, All. Default: Critical,High

.PARAMETER Source
    Where to read secrets from: vault, env, file. Default: vault

.PARAMETER EnvFile
    Path to .env file when Source=file

.PARAMETER Owner
    GitHub repo owner. Default: Aitherium

.PARAMETER Repo
    GitHub repo name. Default: AitherOS

.PARAMETER DryRun
    Show what would be synced without actually syncing

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    .\6010_Sync-SecretsToGitHub.ps1                             # Sync critical + high from vault
    .\6010_Sync-SecretsToGitHub.ps1 -Tier All -Force            # Sync everything
    .\6010_Sync-SecretsToGitHub.ps1 -Source file -EnvFile .env  # From .env file
    .\6010_Sync-SecretsToGitHub.ps1 -DryRun                     # Preview only

.NOTES
    Category: security
    Script: 6010
    Dependencies: GitHub CLI (gh), AitherSecrets (optional)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Critical", "High", "Medium", "Low", "All")]
    [string[]]$Tier = @("Critical", "High"),

    [ValidateSet("vault", "env", "file")]
    [string]$Source = "vault",

    [string]$EnvFile,

    [string]$Owner = "Aitherium",
    [string]$Repo = "AitherOS",

    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# SECRET REGISTRY — Master list of all secrets the system uses
# ═══════════════════════════════════════════════════════════════

function Get-SecretRegistry {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\..\.."))
    $registryPath = Join-Path $repoRoot "AitherOS\config\secrets-registry.yaml"

    if (-not (Test-Path $registryPath)) {
        throw "Secrets registry not found: $registryPath"
    }

    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        throw "ConvertFrom-Yaml is required to load $registryPath. Use PowerShell 7+."
    }

    $registry = Get-Content -Path $registryPath -Raw | ConvertFrom-Yaml
    if (-not $registry.secrets) {
        throw "Secrets registry did not contain a 'secrets' collection: $registryPath"
    }

    return @(
        $registry.secrets | ForEach-Object {
            [PSCustomObject]@{
                Name = [string]$_.name
                Tier = (Get-Culture).TextInfo.ToTitleCase([string]$_.tier)
                Category = if ($_.category) { [string]$_.category } else { "General" }
                Description = if ($_.description) { [string]$_.description } else { [string]$_.name }
                Actions = [bool]$_.actions
                Partner = [bool]$_.partner
            }
        }
    )
}

$SecretRegistry = Get-SecretRegistry

# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

function Get-SecretValue {
    param([string]$Name, [string]$Source)

    switch ($Source) {
        "vault" {
            try {
                $result = Invoke-RestMethod -Uri "http://localhost:8111/secrets/$Name" -TimeoutSec 5 -ErrorAction Stop
                return $result.value
            } catch {
                # Fallback to env var
                $envVal = [System.Environment]::GetEnvironmentVariable($Name)
                return $envVal
            }
        }
        "env" {
            return [System.Environment]::GetEnvironmentVariable($Name)
        }
        "file" {
            # Will be populated from env file
            return $script:fileSecrets[$Name]
        }
    }
    return $null
}

# ═══════════════════════════════════════════════════════════════
# PREFLIGHT
# ═══════════════════════════════════════════════════════════════

# Verify gh CLI
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) is not installed. Install from https://cli.github.com/"
    exit 1
}

$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "GitHub CLI is not authenticated. Run 'gh auth login' first."
    exit 1
}

# Load file secrets if needed
$script:fileSecrets = @{}
if ($Source -eq "file") {
    if (-not $EnvFile) {
        Write-Error "Must specify -EnvFile when using -Source file"
        exit 1
    }
    if (-not (Test-Path $EnvFile)) {
        Write-Error "File not found: $EnvFile"
        exit 1
    }
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line.Split("=", 2)
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim().Trim('"').Trim("'")
                $script:fileSecrets[$key] = $val
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# FILTER BY TIER
# ═══════════════════════════════════════════════════════════════

$selectedSecrets = if ($Tier -contains "All") {
    $SecretRegistry
} else {
    $SecretRegistry | Where-Object { $_.Tier -in $Tier }
}

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       AITHEROS SECRETS → GITHUB SYNC                    ║" -ForegroundColor Cyan
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Target:  $("$Owner/$Repo".PadRight(45))║" -ForegroundColor White
Write-Host "║  Source:  $($Source.PadRight(45))║" -ForegroundColor White
Write-Host "║  Tiers:   $(($Tier -join ", ").PadRight(45))║" -ForegroundColor White
Write-Host "║  Secrets: $("$($selectedSecrets.Count) candidates".PadRight(45))║" -ForegroundColor White
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# SCAN + SYNC
# ═══════════════════════════════════════════════════════════════

$results = @{
    Synced  = @()
    Missing = @()
    Skipped = @()
    Failed  = @()
}

# Group by category for display
$grouped = $selectedSecrets | Group-Object -Property Category

foreach ($group in $grouped | Sort-Object Name) {
    Write-Host "  ── $($group.Name) ──" -ForegroundColor Yellow

    foreach ($secret in $group.Group) {
        $name = $secret.Name
        $value = Get-SecretValue -Name $name -Source $Source

        $tierIcon = switch ($secret.Tier) {
            "Critical" { "🔴" }
            "High"     { "🟠" }
            "Medium"   { "🟡" }
            "Low"      { "🟢" }
        }

        if (-not $value) {
            Write-Host "  $tierIcon $($name.PadRight(40)) ⊘ not set" -ForegroundColor DarkGray
            $results.Missing += $secret
            continue
        }

        # Mask value for display
        $masked = if ($value.Length -gt 8) {
            "$($value.Substring(0,4))...$($value.Substring($value.Length-4))"
        } else { "****" }

        if ($DryRun) {
            Write-Host "  $tierIcon $($name.PadRight(40)) → would sync ($masked)" -ForegroundColor Cyan
            $results.Skipped += $secret
            continue
        }

        if (-not $Force -and -not $DryRun) {
            # Auto-approve for non-interactive
            if ($env:AITHERZERO_NONINTERACTIVE -ne "true") {
                $confirm = Read-Host "  Sync $name ($masked)? (y/N)"
                if ($confirm -notin @("y", "Y", "yes")) {
                    Write-Host "  $tierIcon $($name.PadRight(40)) ⊘ skipped" -ForegroundColor DarkGray
                    $results.Skipped += $secret
                    continue
                }
            }
        }

        # Push to GitHub
        try {
            $value | gh secret set $name --repo "$Owner/$Repo" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  $tierIcon $($name.PadRight(40)) ✓ synced ($masked)" -ForegroundColor Green
                $results.Synced += $secret
            } else {
                Write-Host "  $tierIcon $($name.PadRight(40)) ✗ failed" -ForegroundColor Red
                $results.Failed += $secret
            }
        } catch {
            Write-Host "  $tierIcon $($name.PadRight(40)) ✗ error: $_" -ForegroundColor Red
            $results.Failed += $secret
        }
    }
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SYNC SUMMARY                                           ║" -ForegroundColor Cyan
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  ✓ Synced:  $("$($results.Synced.Count)".PadRight(45))║" -ForegroundColor Green
Write-Host "║  ⊘ Missing: $("$($results.Missing.Count) (no value found)".PadRight(45))║" -ForegroundColor $(if ($results.Missing.Count -gt 0) { "Yellow" } else { "Green" })
Write-Host "║  ⊘ Skipped: $("$($results.Skipped.Count)".PadRight(45))║" -ForegroundColor DarkGray
Write-Host "║  ✗ Failed:  $("$($results.Failed.Count)".PadRight(45))║" -ForegroundColor $(if ($results.Failed.Count -gt 0) { "Red" } else { "Green" })
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

if ($results.Missing.Count -gt 0) {
    Write-Host ""
    Write-Host "  Missing secrets — set them first:" -ForegroundColor Yellow
    foreach ($m in $results.Missing) {
        $tierIcon = switch ($m.Tier) {
            "Critical" { "🔴" }
            "High"     { "🟠" }
            "Medium"   { "🟡" }
            "Low"      { "🟢" }
        }
        Write-Host "  $tierIcon [$($m.Tier)] $($m.Name)" -ForegroundColor DarkGray
        Write-Host "       $($m.Description)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Set via vault:  curl -X POST http://localhost:8111/secrets -d '{`"name`":`"KEY`",`"value`":`"val`"}'" -ForegroundColor Gray
    Write-Host "  Set via script: .\6001_Add-Secret.ps1 -Name KEY -Value val" -ForegroundColor Gray
    Write-Host "  Set via env:    `$env:KEY = 'val'; then re-run with -Source env" -ForegroundColor Gray
}

Write-Host ""
