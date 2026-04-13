#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstrap secrets for a new AitherOS deployment (partner or fresh install).

.DESCRIPTION
    Interactive wizard that walks through ALL required secrets, auto-generates
    what it can (master keys, DB passwords), prompts for the rest, and pushes
    everything to BOTH the local AitherSecrets vault AND (optionally) GitHub.

    Designed for:
    1. First-time local development setup
    2. Partner deployments (fork the repo, run this, you're good)
    3. Fresh staging/prod server setup

    The script reads the secrets registry (AitherOS/config/secrets-registry.yaml)
    and walks you through each tier interactively.

.PARAMETER Tier
    Which tiers to bootstrap: Critical, High, Medium, Low, All.
    Default: Critical,High (minimum for a working system)

.PARAMETER SyncToGitHub
    Also push secrets to GitHub after setting them locally.

.PARAMETER NonInteractive
    Skip prompts — only set auto-generated secrets and skip manual ones.
    Useful for CI/CD or scripted setups.

.PARAMETER VaultUrl
    AitherSecrets vault URL. Default: http://localhost:8111

.PARAMETER EnvFile
    Optional .env file to read existing secret values from.

.PARAMETER Owner
    GitHub repo owner (for -SyncToGitHub). Default: Aitherium

.PARAMETER Repo
    GitHub repo name (for -SyncToGitHub). Default: AitherOS

.EXAMPLE
    .\6011_Bootstrap-PartnerSecrets.ps1                           # Interactive wizard, critical+high
    .\6011_Bootstrap-PartnerSecrets.ps1 -Tier All                 # Full setup
    .\6011_Bootstrap-PartnerSecrets.ps1 -SyncToGitHub             # Also push to GitHub
    .\6011_Bootstrap-PartnerSecrets.ps1 -NonInteractive           # Auto-gen only, no prompts
    .\6011_Bootstrap-PartnerSecrets.ps1 -EnvFile .env.staging     # Pre-load from file

.NOTES
    Category: security
    Script: 6011
    Dependencies: AitherSecrets vault (optional), GitHub CLI (optional)
#>

[CmdletBinding()]
param(
    [ValidateSet("Critical", "High", "Medium", "Low", "All")]
    [string[]]$Tier = @("Critical", "High"),

    [switch]$SyncToGitHub,
    [switch]$NonInteractive,

    [string]$VaultUrl = "http://localhost:8111",
    [string]$EnvFile,

    [string]$Owner = "Aitherium",
    [string]$Repo = "AitherOS"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# SECRET REGISTRY
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
                Generate = if ($_.generate) { [string]$_.generate } else { "manual" }
                Description = if ($_.description) { [string]$_.description } else { [string]$_.name }
                Partner = [bool]$_.partner
                Actions = [bool]$_.actions
            }
        }
    )
}

$SecretRegistry = Get-SecretRegistry

# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

function New-RandomSecret {
    param([int]$Length = 64)
    $bytes = [byte[]]::new($Length / 2)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Set-VaultSecret {
    param([string]$Name, [string]$Value, [string]$VaultUrl)
    try {
        $body = @{ name = $Name; value = $Value; type = "api_key"; access = "private" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$VaultUrl/secrets" -Method POST -Body $body -ContentType "application/json" -TimeoutSec 10 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-VaultSecret {
    param([string]$Name, [string]$VaultUrl)
    try {
        $result = Invoke-RestMethod -Uri "$VaultUrl/secrets/$Name" -TimeoutSec 5 -ErrorAction Stop
        return $result.value
    } catch {
        return $null
    }
}

function Set-GitHubSecret {
    param([string]$Name, [string]$Value, [string]$Owner, [string]$Repo)
    try {
        $Value | gh secret set $Name --repo "$Owner/$Repo" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════
# PRE-LOAD ENV FILE
# ═══════════════════════════════════════════════════════════════

$preloaded = @{}
if ($EnvFile -and (Test-Path $EnvFile)) {
    Write-Host "  📄 Pre-loading values from $EnvFile" -ForegroundColor Cyan
    Get-Content $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line.Split("=", 2)
            if ($parts.Count -eq 2) {
                $preloaded[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
            }
        }
    }
    Write-Host "  📄 Loaded $($preloaded.Count) values" -ForegroundColor Green
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
# VAULT HEALTH CHECK
# ═══════════════════════════════════════════════════════════════

$vaultAvailable = $false
try {
    Invoke-RestMethod -Uri "$VaultUrl/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
    $vaultAvailable = $true
} catch {}

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║       AITHEROS SECRETS BOOTSTRAP                        ║" -ForegroundColor Magenta
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║  Vault:    $(if ($vaultAvailable) { "✓ online ($VaultUrl)".PadRight(44) } else { "⊘ offline (will set env vars only)".PadRight(44) })║" -ForegroundColor $(if ($vaultAvailable) { "Green" } else { "Yellow" })
Write-Host "║  GitHub:   $(if ($SyncToGitHub) { "✓ will sync to $Owner/$Repo".PadRight(44) } else { "⊘ local only (use -SyncToGitHub)".PadRight(44) })║" -ForegroundColor White
Write-Host "║  Tiers:    $(($Tier -join ", ").PadRight(44))║" -ForegroundColor White
Write-Host "║  Mode:     $(if ($NonInteractive) { "non-interactive (auto-gen only)".PadRight(44) } else { "interactive wizard".PadRight(44) })║" -ForegroundColor White
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

# ═══════════════════════════════════════════════════════════════
# FILTER
# ═══════════════════════════════════════════════════════════════

$selected = if ($Tier -contains "All") { $SecretRegistry } else {
    $SecretRegistry | Where-Object { $_.Tier -in $Tier }
}

# ═══════════════════════════════════════════════════════════════
# WALK THROUGH SECRETS
# ═══════════════════════════════════════════════════════════════

$stats = @{ Set = 0; Skipped = 0; AutoGenerated = 0; AlreadySet = 0; Failed = 0 }
$envExport = @()

$grouped = $selected | Group-Object -Property Category
foreach ($group in $grouped | Sort-Object Name) {
    Write-Host "  ╔══ $($group.Name.ToUpper()) ══╗" -ForegroundColor Yellow
    Write-Host ""

    foreach ($secret in $group.Group) {
        $name = $secret.Name
        $tierIcon = switch ($secret.Tier) {
            "Critical" { "🔴" }
            "High"     { "🟠" }
            "Medium"   { "🟡" }
            "Low"      { "🟢" }
        }

        # Check if already set in vault
        $existing = if ($vaultAvailable) { Get-VaultSecret -Name $name -VaultUrl $VaultUrl } else { $null }
        # Or in preloaded env file
        if (-not $existing) { $existing = $preloaded[$name] }
        # Or in environment
        if (-not $existing) { $existing = [Environment]::GetEnvironmentVariable($name) }

        if ($existing) {
            $masked = if ($existing.Length -gt 8) { "$($existing.Substring(0,4))...$($existing.Substring($existing.Length-4))" } else { "****" }
            Write-Host "  $tierIcon $($name.PadRight(38)) ✓ already set ($masked)" -ForegroundColor Green
            $stats.AlreadySet++
            $envExport += "$name=$existing"
            continue
        }

        # Auto-generate if possible
        if ($secret.Generate -eq "auto") {
            $generated = New-RandomSecret -Length 64
            Write-Host "  $tierIcon $($name.PadRight(38)) 🔑 auto-generated" -ForegroundColor Cyan

            if ($vaultAvailable) {
                $ok = Set-VaultSecret -Name $name -Value $generated -VaultUrl $VaultUrl
                if ($ok) {
                    Write-Host "       → vault ✓" -ForegroundColor Green
                } else {
                    Write-Host "       → vault ✗ (will use env var)" -ForegroundColor Yellow
                }
            }

            if ($SyncToGitHub) {
                $ok = Set-GitHubSecret -Name $name -Value $generated -Owner $Owner -Repo $Repo
                Write-Host "       → github $(if ($ok) { '✓' } else { '✗' })" -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            }

            [Environment]::SetEnvironmentVariable($name, $generated, "Process")
            $envExport += "$name=$generated"
            $stats.AutoGenerated++
            continue
        }

        # Manual secret — prompt if interactive
        if ($NonInteractive) {
            Write-Host "  $tierIcon $($name.PadRight(38)) ⊘ skipped (manual, non-interactive)" -ForegroundColor DarkGray
            $stats.Skipped++
            continue
        }

        Write-Host "  $tierIcon $($name.PadRight(38)) — $($secret.Description)" -ForegroundColor White
        $value = Read-Host "       Enter value (or ENTER to skip)"

        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "       → skipped" -ForegroundColor DarkGray
            $stats.Skipped++
            continue
        }

        # Store it
        $stored = $false
        if ($vaultAvailable) {
            $ok = Set-VaultSecret -Name $name -Value $value -VaultUrl $VaultUrl
            if ($ok) {
                Write-Host "       → vault ✓" -ForegroundColor Green
                $stored = $true
            }
        }

        if ($SyncToGitHub) {
            $ok = Set-GitHubSecret -Name $name -Value $value -Owner $Owner -Repo $Repo
            Write-Host "       → github $(if ($ok) { '✓' } else { '✗' })" -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
            if ($ok) { $stored = $true }
        }

        [Environment]::SetEnvironmentVariable($name, $value, "Process")
        $envExport += "$name=$value"

        if ($stored) { $stats.Set++ } else { $stats.Failed++ }
    }
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
# EXPORT .env FILE
# ═══════════════════════════════════════════════════════════════

$envPath = Join-Path $PSScriptRoot "..\..\..\..\secrets.env"
$envPath = [System.IO.Path]::GetFullPath($envPath)

if ($envExport.Count -gt 0) {
    Write-Host "  📝 Writing secrets backup to $envPath" -ForegroundColor Cyan
    Write-Host "     ⚠️  THIS FILE CONTAINS SECRETS — do NOT commit it!" -ForegroundColor Red
    @(
        "# AitherOS Secrets Export — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "# Generated by 6011_Bootstrap-PartnerSecrets.ps1"
        "# ⚠️  DO NOT COMMIT THIS FILE — add to .gitignore"
        ""
    ) + $envExport | Set-Content -Path $envPath -Force

    # Make sure it's gitignored
    $gitignorePath = Join-Path $PSScriptRoot "..\..\..\..\..\.gitignore"
    $gitignorePath = [System.IO.Path]::GetFullPath($gitignorePath)
    if (Test-Path $gitignorePath) {
        $gitignore = Get-Content $gitignorePath -Raw
        if ($gitignore -notmatch "secrets\.env") {
            Add-Content -Path $gitignorePath -Value "`nsecrets.env"
            Write-Host "     Added secrets.env to .gitignore" -ForegroundColor Green
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  BOOTSTRAP SUMMARY                                      ║" -ForegroundColor Magenta
Write-Host "╠═══════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║  ✓ Already set:    $("$($stats.AlreadySet)".PadRight(38))║" -ForegroundColor Green
Write-Host "║  🔑 Auto-generated: $("$($stats.AutoGenerated)".PadRight(38))║" -ForegroundColor Cyan
Write-Host "║  ✓ Manually set:   $("$($stats.Set)".PadRight(38))║" -ForegroundColor Green
Write-Host "║  ⊘ Skipped:        $("$($stats.Skipped)".PadRight(38))║" -ForegroundColor DarkGray
Write-Host "║  ✗ Failed:         $("$($stats.Failed)".PadRight(38))║" -ForegroundColor $(if ($stats.Failed -gt 0) { "Red" } else { "Green" })
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

if ($stats.Skipped -gt 0) {
    Write-Host "  💡 Re-run without -NonInteractive to set skipped secrets" -ForegroundColor Yellow
    Write-Host "  💡 Or set them manually:" -ForegroundColor Yellow
    Write-Host "     curl -X POST $VaultUrl/secrets -H 'Content-Type: application/json' -d '{`"name`":`"KEY`",`"value`":`"val`"}'" -ForegroundColor Gray
    Write-Host ""
}

if (-not $SyncToGitHub) {
    Write-Host "  💡 To also push to GitHub: re-run with -SyncToGitHub" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  🎯 Next steps:" -ForegroundColor White
Write-Host "     1. Start services:  npm start" -ForegroundColor Gray
Write-Host "     2. Check vault:     curl http://localhost:8111/secrets" -ForegroundColor Gray
Write-Host "     3. Sync to GitHub:  .\6010_Sync-SecretsToGitHub.ps1 -Tier All -Force" -ForegroundColor Gray
Write-Host ""
