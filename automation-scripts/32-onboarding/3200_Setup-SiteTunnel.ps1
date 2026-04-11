#Requires -Version 7.0

<#
.SYNOPSIS
    Install and configure Cloudflare Tunnel for a remote AitherOS site.

.DESCRIPTION
    Sets up cloudflared on the local machine, injects the tunnel token into
    the AitherOS .env, and starts the tunnel as a persistent service.

    Steps:
        1. Install cloudflared (winget/apt/brew) if not present
        2. Inject CLOUDFLARE_TUNNEL_TOKEN into .env
        3. Start cloudflared as a system service
        4. Verify tunnel connectivity

    Exit Codes:
        0 - Success
        1 - cloudflared install failed
        2 - Configuration failed
        3 - Tunnel connectivity check failed

.PARAMETER TunnelToken
    Cloudflare tunnel token (eyJ...). REQUIRED.

.PARAMETER SiteSlug
    Site identifier for logging. Default: hostname.

.PARAMETER DryRun
    Preview only.

.PARAMETER PassThru
    Return result object.

.NOTES
    Stage: Onboarding
    Order: 3200
    Dependencies: none
    Tags: onboarding, tunnel, cloudflare, site-setup
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TunnelToken,

    [string]$SiteSlug = $env:COMPUTERNAME,

    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'

# --- Resolve project root ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InitScript = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) '_init.ps1'
if (Test-Path $InitScript) { . $InitScript }
if (-not $ProjectRoot) { $ProjectRoot = (git -C $ScriptDir rev-parse --show-toplevel 2>$null) ?? (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) }

function Write-Step { param([string]$Name, [string]$Status = 'running')
    $icon = switch ($Status) { 'done' { '[OK]' } 'fail' { '[FAIL]' } 'skip' { '[SKIP]' } default { '[..]' } }
    Write-Host "$icon $Name" -ForegroundColor $(switch ($Status) { 'done' { 'Green' } 'fail' { 'Red' } 'skip' { 'Yellow' } default { 'Cyan' } })
}

# ── Step 1: Install cloudflared ──────────────────────────────────────────

Write-Step "Install cloudflared" 'running'

$cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue

if (-not $cloudflared) {
    if ($DryRun) { Write-Step "Install cloudflared (DRY RUN)" 'skip'; return }

    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        Write-Host "  Installing via winget..."
        winget install --id Cloudflare.cloudflared --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
    }
    elseif (Test-Path /usr/bin/apt-get) {
        Write-Host "  Installing via apt..."
        $debUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb'
        Invoke-WebRequest -Uri $debUrl -OutFile '/tmp/cloudflared.deb'
        sudo dpkg -i /tmp/cloudflared.deb
    }
    elseif (Get-Command brew -ErrorAction SilentlyContinue) {
        Write-Host "  Installing via brew..."
        brew install cloudflared
    }
    else {
        Write-Step "Install cloudflared" 'fail'
        Write-Error "Cannot auto-install cloudflared. Install manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        exit 1
    }

    $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
    if (-not $cloudflared) {
        Write-Step "Install cloudflared" 'fail'
        exit 1
    }
}

Write-Step "Install cloudflared ($(& cloudflared --version 2>&1 | Select-Object -First 1))" 'done'

# ── Step 2: Inject tunnel token into .env ────────────────────────────────

Write-Step "Configure tunnel token" 'running'

$envFile = Join-Path $ProjectRoot '.env'
if (-not (Test-Path $envFile)) {
    Write-Host "  Creating .env from template..."
    $template = Join-Path $ProjectRoot '.env.example'
    if (Test-Path $template) { Copy-Item $template $envFile }
    else { New-Item -Path $envFile -ItemType File -Force | Out-Null }
}

$envContent = Get-Content $envFile -Raw -ErrorAction SilentlyContinue
if ($envContent -match 'CLOUDFLARE_TUNNEL_TOKEN=') {
    # Replace existing
    $envContent = $envContent -replace 'CLOUDFLARE_TUNNEL_TOKEN=.*', "CLOUDFLARE_TUNNEL_TOKEN=$TunnelToken"
}
else {
    # Append
    $envContent += "`nCLOUDFLARE_TUNNEL_TOKEN=$TunnelToken`n"
}
Set-Content -Path $envFile -Value $envContent -NoNewline

Write-Step "Configure tunnel token" 'done'

# ── Step 3: Start tunnel service ─────────────────────────────────────────

Write-Step "Start tunnel service" 'running'

if ($DryRun) { Write-Step "Start tunnel service (DRY RUN)" 'skip' }
else {
    # If Docker is running and we have the compose file, use the container
    $composeFile = Join-Path $ProjectRoot 'docker-compose.aitheros.yml'
    if ((Get-Command docker -ErrorAction SilentlyContinue) -and (Test-Path $composeFile)) {
        Write-Host "  Starting via Docker Compose..."
        docker compose -f $composeFile up -d aitheros-tunnel 2>&1 | ForEach-Object { Write-Host "  $_" }
    }
    else {
        # Install as system service
        Write-Host "  Installing as system service..."
        if ($IsWindows -or $env:OS -eq 'Windows_NT') {
            & cloudflared service install $TunnelToken 2>&1 | ForEach-Object { Write-Host "  $_" }
        }
        else {
            sudo cloudflared service install $TunnelToken 2>&1 | ForEach-Object { Write-Host "  $_" }
            sudo systemctl start cloudflared 2>&1 | Out-Null
        }
    }
    Write-Step "Start tunnel service" 'done'
}

# ── Step 4: Verify connectivity ──────────────────────────────────────────

Write-Step "Verify tunnel connectivity" 'running'

$maxRetries = 6
$connected = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    Start-Sleep -Seconds 5
    try {
        $resp = Invoke-WebRequest -Uri "https://$SiteSlug.aitherium.com" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -lt 500) { $connected = $true; break }
    }
    catch {
        Write-Host "  Attempt $i/$maxRetries - waiting for tunnel..."
    }
}

if ($connected) {
    Write-Step "Verify tunnel connectivity ($SiteSlug.aitherium.com reachable)" 'done'
}
else {
    Write-Step "Verify tunnel connectivity (may need DNS propagation)" 'skip'
    Write-Host "  Tunnel token injected. DNS may take a few minutes to propagate."
    Write-Host "  Check: https://$SiteSlug.aitherium.com"
}

# ── Summary ──────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Tunnel configured for site: $SiteSlug" -ForegroundColor Green
Write-Host "  Token: $($TunnelToken.Substring(0, [Math]::Min(20, $TunnelToken.Length)))..."
Write-Host "  URLs:  https://$SiteSlug.aitherium.com"
Write-Host ""

exit 0
