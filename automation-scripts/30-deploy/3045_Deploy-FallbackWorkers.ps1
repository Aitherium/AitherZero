<#
.SYNOPSIS
    Deploy Cloudflare Workers for failover/maintenance pages.

.DESCRIPTION
    Deploys one or both Cloudflare Workers that serve maintenance/failover pages
    when the tunnel or origin host goes down:

      1. aitheros-fallback  — covers all *.aitherium.com subdomains
      2. wildroot-fallback  — covers wildrootalchemy.co + www.wildrootalchemy.co

    Requires `wrangler` CLI to be installed and authenticated.

.PARAMETER Worker
    Which worker(s) to deploy. Valid values: All, Demo, Wildroot.
    Default: All

.PARAMETER DryRun
    Show what would be deployed without actually deploying.

.EXAMPLE
    .\Deploy-FallbackWorkers.ps1
    .\Deploy-FallbackWorkers.ps1 -Worker Wildroot
    .\Deploy-FallbackWorkers.ps1 -DryRun
#>
#Requires -Version 7.0

[CmdletBinding()]
param(
    [ValidateSet('All', 'Demo', 'Wildroot')]
    [string]$Worker = 'All',

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$DemoWorkerDir = Join-Path $RepoRoot 'AitherOS' 'assets' 'fallback-page'
$WildrootWorkerDir = Join-Path $RepoRoot 'AitherOS' 'deploy' 'cloudflare-workers' 'wildroot-fallback'

# Verify wrangler is available
if (-not (Get-Command 'wrangler' -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command 'npx' -ErrorAction SilentlyContinue)) {
        Write-Error "Neither 'wrangler' nor 'npx' found. Install wrangler: npm i -g wrangler"
        return
    }
    $WranglerCmd = 'npx wrangler'
} else {
    $WranglerCmd = 'wrangler'
}

function Deploy-Worker {
    param(
        [string]$Name,
        [string]$Directory
    )

    Write-Host "`n━━━ Deploying: $Name ━━━" -ForegroundColor Cyan

    if (-not (Test-Path (Join-Path $Directory 'wrangler.toml'))) {
        Write-Error "Missing wrangler.toml in $Directory"
        return $false
    }

    if (-not (Test-Path (Join-Path $Directory 'worker.js'))) {
        Write-Error "Missing worker.js in $Directory"
        return $false
    }

    Write-Host "  Directory: $Directory" -ForegroundColor DarkGray
    Write-Host "  Config:    $(Get-Content (Join-Path $Directory 'wrangler.toml') -First 1)" -ForegroundColor DarkGray

    # Show routes
    $toml = Get-Content (Join-Path $Directory 'wrangler.toml') -Raw
    $routes = [regex]::Matches($toml, 'pattern\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    Write-Host "  Routes:" -ForegroundColor DarkGray
    foreach ($r in $routes) {
        Write-Host "    • $r" -ForegroundColor Yellow
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would deploy $Name" -ForegroundColor DarkYellow
        return $true
    }

    Push-Location $Directory
    try {
        $output = & $WranglerCmd deploy 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to deploy $Name`n$output"
            return $false
        }
        Write-Host "  ✅ $Name deployed successfully" -ForegroundColor Green
        $output | Where-Object { $_ -match 'https://' } | ForEach-Object {
            Write-Host "  $_" -ForegroundColor DarkGray
        }
        return $true
    } finally {
        Pop-Location
    }
}

# ── Deploy ────────────────────────────────────────────────────────────────────

$results = @{}

if ($Worker -in 'All', 'Demo') {
    $results['aitheros-fallback'] = Deploy-Worker -Name 'aitheros-fallback' -Directory $DemoWorkerDir
}

if ($Worker -in 'All', 'Wildroot') {
    $results['wildroot-fallback'] = Deploy-Worker -Name 'wildroot-fallback' -Directory $WildrootWorkerDir
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n━━━ Deployment Summary ━━━" -ForegroundColor Cyan
foreach ($kv in $results.GetEnumerator()) {
    $icon = if ($kv.Value) { '✅' } else { '❌' }
    $color = if ($kv.Value) { 'Green' } else { 'Red' }
    Write-Host "  $icon $($kv.Key)" -ForegroundColor $color
}

Write-Host "`nNext steps:" -ForegroundColor White
Write-Host "  • Verify failover: stop your tunnel, visit the domains in a browser" -ForegroundColor DarkGray
Write-Host "  • Monitor: Cloudflare Dashboard → Workers & Pages → each worker's logs" -ForegroundColor DarkGray
Write-Host "  • Test API: curl -s https://demo.aitherium.com/api/health (should 503 when down)" -ForegroundColor DarkGray
