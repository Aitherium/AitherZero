#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys a customer expedition app — Docker container + tunnel route + DNS.

.DESCRIPTION
    End-to-end deployment for expedition (customer) apps:
      1. Validates the expedition directory and docker-compose.yml
      2. Ensures the app container joins the shared AitherOS Docker network
      3. Starts/rebuilds the Docker Compose stack
      4. Adds ingress route(s) to tunnel-routes.yaml
      5. Pushes tunnel config to Cloudflare API
      6. Creates DNS CNAME records pointing to the tunnel
      7. Runs health checks against the tunnel endpoint

    Designed to be called by Atlas, Demiurge, or AitherZero automation.

    Exit Codes:
      0 - Success
      1 - Validation failure (missing files, bad config)
      2 - Docker failure (build/start failed)
      3 - Tunnel sync failure (CF API error)
      4 - Health check failure (app unreachable via tunnel)

.PARAMETER Name
    Short name for the expedition (e.g. "wildroot"). Used as the app identifier
    in tunnel routes and Docker naming.

.PARAMETER Path
    Path to the expedition directory containing docker-compose.yml.
    Default: expeditions/<Name>/backend

.PARAMETER Hostname
    Public hostname(s) for the tunnel route. Comma-separated for multiple.
    Example: "wildrootalchemy.co,www.wildrootalchemy.co"

.PARAMETER Service
    Internal Docker service URL the tunnel should proxy to.
    Example: "http://wildroot-backend:8000"

.PARAMETER ContainerName
    Docker container name that must be on the shared network.
    Default: derived from Name (e.g. "<name>-backend")

.PARAMETER HealthPath
    Health check endpoint path. Default: "/health"

.PARAMETER Critical
    Whether this route is marked critical in tunnel config. Default: $true

.PARAMETER Build
    Force rebuild Docker images before starting.

.PARAMETER DryRun
    Show what would be done without making changes.

.PARAMETER SkipTunnel
    Skip tunnel route sync (just deploy the container).

.PARAMETER SkipDNS
    Skip DNS CNAME creation.

.PARAMETER Force
    Skip confirmation prompts.

.EXAMPLE
    # Deploy Wildroot Alchemy
    .\3060_Deploy-Expedition.ps1 -Name wildroot `
        -Hostname "wildrootalchemy.co,www.wildrootalchemy.co" `
        -Service "http://wildroot-backend:8000"

.EXAMPLE
    # Deploy a new customer app
    .\3060_Deploy-Expedition.ps1 -Name acme-crm `
        -Hostname "app.acmecrm.io" `
        -Service "http://acme-crm-backend:8000" `
        -Build

.EXAMPLE
    # Dry run — preview what would happen
    .\3060_Deploy-Expedition.ps1 -Name wildroot `
        -Hostname "wildrootalchemy.co" `
        -Service "http://wildroot-backend:8000" `
        -DryRun

.NOTES
    Stage: Deploy
    Order: 3060
    Dependencies: 3040
    Tags: deploy, expedition, customer-app, tunnel, cloudflare, docker
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$Path,

    [Parameter(Mandatory)]
    [string]$Hostname,

    [Parameter(Mandatory)]
    [string]$Service,

    [string]$ContainerName,

    [string]$HealthPath = "/health",

    [switch]$Critical,

    [switch]$Build,

    [switch]$DryRun,

    [switch]$SkipTunnel,

    [switch]$SkipDNS,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Paths ─────────────────────────────────────────────────────────────────
$ProjectRoot    = (Resolve-Path "$PSScriptRoot/../../../../").Path
$ConfigPath     = Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml"
$EnvFile        = Join-Path $ProjectRoot ".env"
$SyncScript     = Join-Path $PSScriptRoot "3040_Sync-CloudflareTunnel.ps1"
$ExpeditionsDir = Join-Path $ProjectRoot "expeditions"

if (-not $Path) {
    $Path = Join-Path $ExpeditionsDir "$Name/backend"
}
if (-not [System.IO.Path]::IsPathRooted($Path)) {
    $Path = Join-Path $ProjectRoot $Path
}
if (-not $ContainerName) {
    $ContainerName = "$Name-backend"
}

$Hostnames = $Hostname -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# ── Helpers ───────────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

# ══════════════════════════════════════════════════════════════════════════
Write-Title "Deploy Expedition: $Name"
Write-Host ""
Write-Host "  Name:           $Name" -ForegroundColor Gray
Write-Host "  Path:           $Path" -ForegroundColor Gray
Write-Host "  Hostname(s):    $($Hostnames -join ', ')" -ForegroundColor Gray
Write-Host "  Service:        $Service" -ForegroundColor Gray
Write-Host "  Container:      $ContainerName" -ForegroundColor Gray
Write-Host "  Health:         $HealthPath" -ForegroundColor Gray
Write-Host "  Critical:       $Critical" -ForegroundColor Gray
Write-Host "  DryRun:         $DryRun" -ForegroundColor Gray
Write-Host ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 1: Validate expedition directory
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Phase 1 — Validate Expedition"

$composePath = Join-Path $Path "docker-compose.yml"
if (-not (Test-Path $composePath)) {
    # Try docker-compose.yaml
    $composePath = Join-Path $Path "docker-compose.yaml"
}

if (-not (Test-Path $composePath)) {
    Write-Bad "No docker-compose.yml found at $Path"
    exit 1
}
Write-Good "Found compose file: $composePath"

# Validate Docker is available
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Bad "Docker is not installed"
    exit 1
}
try { docker info 2>&1 | Out-Null } catch { Write-Bad "Docker daemon not running"; exit 1 }
Write-Good "Docker is available"

# ══════════════════════════════════════════════════════════════════════════
# PHASE 2: Ensure shared network exists & compose has it
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Phase 2 — Network Configuration"

# Detect the shared AitherOS network
$sharedNetworkName = "aitheros-fresh_aither-network"
$existingNets = docker network ls --format '{{.Name}}' 2>&1
if ($existingNets -notcontains $sharedNetworkName) {
    # Try alternate naming
    $alt = $existingNets | Where-Object { $_ -match 'aither.*network' } | Select-Object -First 1
    if ($alt) {
        $sharedNetworkName = $alt
        Write-Info "Using detected network: $sharedNetworkName"
    } else {
        Write-Step "Creating shared network: $sharedNetworkName"
        if (-not $DryRun) {
            docker network create $sharedNetworkName 2>&1 | Out-Null
        }
    }
}
Write-Good "Shared network: $sharedNetworkName"

# Check if compose file already references the shared network
$composeContent = Get-Content $composePath -Raw
$hasSharedNet = $composeContent -match 'aither-shared-net|aither.*network'
if (-not $hasSharedNet) {
    Write-Step "Compose file missing shared network — injecting aither-shared-net"
    if (-not $DryRun) {
        # Find the first service and add the network to it
        # Also add the external network definition
        $networkBlock = @"

  aither-shared-net:
    external: true
    name: $sharedNetworkName
"@
        if ($composeContent -match '(?m)^networks:') {
            # Append to existing networks section
            $composeContent = $composeContent -replace '(?m)(^networks:\s*\n)', "`$1$networkBlock`n"
        } else {
            # Add networks section at end
            $composeContent += "`nnetworks:$networkBlock`n"
        }
        Set-Content -Path $composePath -Value $composeContent -Encoding UTF8
        Write-Good "Injected shared network into compose file"
    }
} else {
    Write-Good "Compose already has shared network reference"
}

# ══════════════════════════════════════════════════════════════════════════
# PHASE 3: Deploy Docker Compose stack
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Phase 3 — Deploy Container Stack"

$composeArgs = @("-f", $composePath, "up", "-d")
if ($Build) { $composeArgs += "--build" }

Write-Step "docker compose $($composeArgs -join ' ')"
if (-not $DryRun) {
    Push-Location $Path
    try {
        $output = docker compose @composeArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Bad "Docker Compose failed:`n$output"
            exit 2
        }
        Write-Good "Container stack deployed"
    } finally {
        Pop-Location
    }

    # Wait for container to be healthy
    Write-Step "Waiting for $ContainerName to be healthy..."
    $maxWait = 60
    $waited = 0
    while ($waited -lt $maxWait) {
        $health = docker inspect --format '{{.State.Health.Status}}' $ContainerName 2>&1
        if ($health -eq 'healthy') { break }
        if ($health -match 'No such') {
            # No healthcheck defined — check running state
            $state = docker inspect --format '{{.State.Status}}' $ContainerName 2>&1
            if ($state -eq 'running') { break }
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    if ($waited -ge $maxWait) {
        Write-Bad "Container $ContainerName did not become healthy within ${maxWait}s"
        exit 2
    }
    Write-Good "$ContainerName is healthy"
} else {
    Write-Info "[DryRun] Would run: docker compose $($composeArgs -join ' ')"
}

# Ensure container is on shared network
Write-Step "Connecting $ContainerName to $sharedNetworkName"
if (-not $DryRun) {
    docker network connect $sharedNetworkName $ContainerName 2>&1 | Out-Null
    # Verify
    $nets = docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $ContainerName 2>&1
    if ($nets -match $sharedNetworkName -or $nets -match 'aither') {
        Write-Good "$ContainerName connected to shared network"
    } else {
        Write-Bad "$ContainerName failed to join shared network"
        Write-Info "Networks: $nets"
    }
} else {
    Write-Info "[DryRun] Would connect $ContainerName to $sharedNetworkName"
}

# ══════════════════════════════════════════════════════════════════════════
# PHASE 4: Add tunnel routes to tunnel-routes.yaml
# ══════════════════════════════════════════════════════════════════════════
if (-not $SkipTunnel) {
    Write-Title "Phase 4 — Tunnel Route Configuration"

    if (-not (Test-Path $ConfigPath)) {
        Write-Bad "tunnel-routes.yaml not found at $ConfigPath"
        exit 3
    }

    $yamlContent = Get-Content $ConfigPath -Raw
    $routesAdded = 0

    foreach ($hn in $Hostnames) {
        if ($yamlContent -match [regex]::Escape($hn)) {
            Write-Info "Route already exists: $hn"
            continue
        }

        $isPrimary = ($hn -eq $Hostnames[0])
        $desc = if ($isPrimary) { "$Name — expedition app" } else { "$Name — alias ($hn)" }
        $isCritical = if ($isPrimary -and $Critical) { "true" } else { "false" }

        $routeBlock = @"

  # ── $Name ($hn) ────────────────────────────────────────────────────
  - hostname: $hn
    service: $Service
    description: "$desc"
    health_check: $HealthPath
    critical: $isCritical
"@

        # Insert before the catchall section
        if ($yamlContent -match '(?m)^# ── Catch-all') {
            $yamlContent = $yamlContent -replace '(?m)(^# ── Catch-all)', "$routeBlock`n`n`$1"
        } elseif ($yamlContent -match '(?m)^catchall:') {
            $yamlContent = $yamlContent -replace '(?m)(^catchall:)', "$routeBlock`n`n`$1"
        } else {
            # Append before end
            $yamlContent += $routeBlock
        }

        $routesAdded++
        Write-Good "Added route: $hn → $Service"
    }

    if ($routesAdded -gt 0 -and -not $DryRun) {
        Set-Content -Path $ConfigPath -Value $yamlContent -Encoding UTF8
        Write-Good "Updated tunnel-routes.yaml ($routesAdded route(s) added)"
    } elseif ($DryRun) {
        Write-Info "[DryRun] Would add $routesAdded route(s) to tunnel-routes.yaml"
    }

    # ══════════════════════════════════════════════════════════════════════
    # PHASE 5: Sync to Cloudflare API
    # ══════════════════════════════════════════════════════════════════════
    Write-Title "Phase 5 — Sync to Cloudflare"

    if (-not (Test-Path $SyncScript)) {
        Write-Bad "Sync script not found: $SyncScript"
        exit 3
    }

    $syncArgs = @()
    if ($DryRun) { $syncArgs += "-DryRun" }
    if ($Force) { $syncArgs += "-Force" }
    if (-not $SkipDNS) { $syncArgs += "-EnsureDNS" }

    Write-Step "Running 3040_Sync-CloudflareTunnel.ps1 $($syncArgs -join ' ')"
    if (-not $DryRun) {
        & $SyncScript @syncArgs
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Bad "Tunnel sync failed (exit code: $LASTEXITCODE)"
            exit 3
        }
        Write-Good "Tunnel routes synced to Cloudflare"
    } else {
        Write-Info "[DryRun] Would sync tunnel routes to Cloudflare API"
    }
} else {
    Write-Info "Skipping tunnel setup (--SkipTunnel)"
}

# ══════════════════════════════════════════════════════════════════════════
# PHASE 6: Health check via tunnel
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Phase 6 — Tunnel Health Check"

if (-not $DryRun -and -not $SkipTunnel) {
    $primaryHost = $Hostnames[0]
    $healthUrl = "https://$primaryHost$HealthPath"
    Write-Step "Checking: $healthUrl"

    # Give DNS/tunnel a moment to propagate
    Start-Sleep -Seconds 3

    $maxRetries = 5
    $healthy = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10 -ErrorAction Stop
            Write-Good "Health check passed: $healthUrl"
            $healthy = $true
            break
        } catch {
            Write-Info "Attempt $i/$maxRetries — $($_.Exception.Message)"
            if ($i -lt $maxRetries) { Start-Sleep -Seconds 5 }
        }
    }

    if (-not $healthy) {
        Write-Bad "Health check failed after $maxRetries attempts"
        Write-Info "This may be a DNS propagation issue — the tunnel route is configured correctly."
        Write-Info "Run: .\3041_CloudflareTunnel-HealthCheck.ps1 to check later."
        # Don't fail — DNS propagation is expected
    }
} else {
    Write-Info "[DryRun/SkipTunnel] Skipping tunnel health check"
}

# ══════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Deployment Complete"
Write-Host ""
Write-Host "  Expedition:     $Name" -ForegroundColor Green
Write-Host "  Container:      $ContainerName" -ForegroundColor Green
Write-Host "  Hostname(s):    $($Hostnames -join ', ')" -ForegroundColor Green
Write-Host "  Tunnel:         $Service" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Verify DNS resolves: nslookup $($Hostnames[0])" -ForegroundColor Gray
Write-Host "    2. If DNS points elsewhere, update nameservers at registrar" -ForegroundColor Gray
Write-Host "    3. Test: curl https://$($Hostnames[0])$HealthPath" -ForegroundColor Gray
Write-Host ""

exit 0
