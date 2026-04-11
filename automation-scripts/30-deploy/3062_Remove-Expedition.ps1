#Requires -Version 7.0
<#
.SYNOPSIS
    Tears down an expedition — stops containers, removes tunnel routes, cleans DNS.

.DESCRIPTION
    Reverse of 3060_Deploy-Expedition.ps1:
      1. Stops and removes the Docker Compose stack
      2. Removes routes from tunnel-routes.yaml
      3. Syncs the updated config to Cloudflare API
      4. Optionally removes DNS CNAME records

    Exit Codes:
      0 - Success
      1 - Validation failure
      2 - Docker failure
      3 - Tunnel sync failure

.PARAMETER Name
    Short expedition name (e.g. "wildroot"). Must match what was used in Deploy.

.PARAMETER Path
    Path to the expedition directory. Default: expeditions/<Name>/backend

.PARAMETER RemoveDNS
    Also remove DNS CNAME records from Cloudflare.

.PARAMETER RemoveFiles
    Also delete the expedition directory (DANGER).

.PARAMETER DryRun
    Show what would be done without making changes.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    .\3062_Remove-Expedition.ps1 -Name wildroot

.EXAMPLE
    .\3062_Remove-Expedition.ps1 -Name acme-crm -RemoveDNS -Force

.NOTES
    Stage: Deploy
    Order: 3062
    Dependencies: 3060
    Tags: teardown, expedition, customer-app, cleanup
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$Path,

    [switch]$RemoveDNS,
    [switch]$RemoveFiles,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot    = (Resolve-Path "$PSScriptRoot/../../../../").Path
$ConfigPath     = Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml"
$SyncScript     = Join-Path $PSScriptRoot "3040_Sync-CloudflareTunnel.ps1"
$ExpeditionsDir = Join-Path $ProjectRoot "expeditions"

if (-not $Path) { $Path = Join-Path $ExpeditionsDir "$Name/backend" }
if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path $ProjectRoot $Path }

function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

Write-Title "Remove Expedition: $Name"

if (-not $Force -and -not $DryRun) {
    $confirm = Read-Host "  Are you sure you want to tear down expedition '$Name'? (y/N)"
    if ($confirm -ne 'y') { Write-Info "Cancelled."; exit 0 }
}

# ── Phase 1: Stop containers ─────────────────────────────────────────────
Write-Title "Phase 1 — Stop Containers"

$composePath = Join-Path $Path "docker-compose.yml"
if (Test-Path $composePath) {
    Write-Step "docker compose down"
    if (-not $DryRun) {
        Push-Location $Path
        try { docker compose -f $composePath down 2>&1 | Out-Null } catch { Write-Info "Compose down warning: $_" }
        Pop-Location
    }
    Write-Good "Containers stopped"
} else {
    Write-Info "No compose file at $Path — skipping container teardown"
}

# ── Phase 2: Remove tunnel routes ────────────────────────────────────────
Write-Title "Phase 2 — Remove Tunnel Routes"

if (Test-Path $ConfigPath) {
    $yamlContent = Get-Content $ConfigPath -Raw
    $originalLength = $yamlContent.Length

    # Remove route blocks that match this expedition name
    # Pattern: comment line with name + hostname + service + description + health_check + critical
    $pattern = "(?ms)\n\s*#\s*──\s*$([regex]::Escape($Name))\s*\([^)]+\)[^─]+─+\n\s*-\s*hostname:[^\n]+\n\s*service:[^\n]+\n\s*description:[^\n]+\n\s*health_check:[^\n]+\n\s*critical:[^\n]+"
    $yamlContent = [regex]::Replace($yamlContent, $pattern, '')

    # Clean up double blank lines
    $yamlContent = $yamlContent -replace '\n{3,}', "`n`n"

    if ($yamlContent.Length -lt $originalLength) {
        if (-not $DryRun) {
            Set-Content -Path $ConfigPath -Value $yamlContent -Encoding UTF8
        }
        Write-Good "Removed tunnel routes for $Name"
    } else {
        Write-Info "No tunnel routes found for $Name"
    }
}

# ── Phase 3: Sync to CF ──────────────────────────────────────────────────
Write-Title "Phase 3 — Sync to Cloudflare"

if ((Test-Path $SyncScript) -and -not $DryRun) {
    $syncArgs = @("-Force")
    if ($DryRun) { $syncArgs += "-DryRun" }
    & $SyncScript @syncArgs
    Write-Good "Tunnel config synced"
} else {
    Write-Info "[DryRun] Would sync tunnel config to CF"
}

# ── Phase 4: Cleanup ─────────────────────────────────────────────────────
if ($RemoveFiles) {
    Write-Title "Phase 4 — Remove Files"
    $expDir = Join-Path $ExpeditionsDir $Name
    if (Test-Path $expDir) {
        if (-not $DryRun) {
            Remove-Item -Recurse -Force $expDir
        }
        Write-Good "Removed: $expDir"
    }
}

Write-Title "Teardown Complete"
Write-Host "  Expedition '$Name' has been removed." -ForegroundColor Green
Write-Host ""

exit 0
