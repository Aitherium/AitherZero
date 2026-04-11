#Requires -Version 7.0
<#
.SYNOPSIS
    Partner deployment engine — pull compiled images, auto-configure, start.

.DESCRIPTION
    Deploys AitherOS to a partner's machine using pre-built Nuitka-compiled
    Docker images from GHCR. No source code is pulled or exposed.

    This script handles the complete partner deployment pipeline:
    1. Detect host hardware (GPU, CPU, RAM)
    2. Auto-select GPU profile based on VRAM
    3. Generate partner .env configuration
    4. Authenticate with GHCR (if needed)
    5. Pull compiled Docker images
    6. Create required Docker volumes
    7. Start services via docker-compose.partner.yml
    8. Validate deployment health

    Unlike 3020_Deploy-OneClick.ps1, this script:
    - NEVER builds from source
    - Uses docker-compose.partner.yml (no build blocks, no source mounts)
    - Images contain compiled Python (.so), no readable .py files
    - GPU profile auto-selected from gpu-profiles.yaml

.PARAMETER Modules
    Capability modules to deploy (comma-separated).
    Options: core, intelligence, memory, agents, creative, all
    Default: core

.PARAMETER Registry
    Container registry. Default: ghcr.io/aitherium

.PARAMETER ImageTag
    Image tag to pull. Default: dist-latest

.PARAMETER GpuProfile
    Override GPU profile. If empty, auto-detected from hardware.

.PARAMETER DryRun
    Show what would be done without executing.

.PARAMETER Force
    Force re-pull images and recreate containers.

.PARAMETER NonInteractive
    Suppress all prompts.

.EXAMPLE
    # Core only (dashboard + chat)
    .\3030_Deploy-Partner.ps1 -Modules core

.EXAMPLE
    # Core + intelligence + memory
    .\3030_Deploy-Partner.ps1 -Modules core,intelligence,memory

.EXAMPLE
    # Everything
    .\3030_Deploy-Partner.ps1 -Modules all

.NOTES
    Category: deploy
    Dependencies: PowerShell 7+, Docker
    Platform: Windows, Linux, macOS
    Script: 3030
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Modules = "core",

    [string]$Registry = "ghcr.io/aitherium",

    [string]$ImageTag = "dist-latest",

    [string]$GpuProfile = "",

    [switch]$DryRun,
    [switch]$Force,
    [switch]$NonInteractive
)

# Resolve 'all' and normalize module list
$allModules = @('core', 'intelligence', 'memory', 'agents', 'creative')
if ($Modules -eq 'all') {
    $moduleList = $allModules
} else {
    $moduleList = ($Modules -split ',').Trim().Where({ $_ -ne '' })
    # Ensure 'core' is always included
    if ('core' -notin $moduleList) { $moduleList = @('core') + $moduleList }
}
# Validate
foreach ($m in $moduleList) {
    if ($m -notin $allModules) {
        Write-Host "Unknown module: $m. Valid: $($allModules -join ', ')" -ForegroundColor Red
        exit 1
    }
}
$composeProfStr = $moduleList -join ','
$modulesStr = $moduleList -join ','

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ═══════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════

. "$PSScriptRoot/../_init.ps1"

$startTime = Get-Date
$results = @{
    Phase       = @{}
    Errors      = @()
    Warnings    = @()
    StartTime   = $startTime
    Modules     = $moduleList
    Registry    = $Registry
    ImageTag    = $ImageTag
    GpuProfile  = ""
    HwDetected  = @{}
}

# Auto-detect CI/non-interactive
if ($env:CI -eq 'true' -or $env:GITHUB_ACTIONS -eq 'true' -or $env:AITHEROS_NONINTERACTIVE -eq '1') {
    $NonInteractive = $true
}

$composeFile = Join-Path $projectRoot "docker-compose.partner.yml"

# ═══════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════

$banner = @"

╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║     █████╗ ██╗████████╗██╗  ██╗███████╗██████╗  ██████╗ ███████╗  ║
║    ██╔══██╗██║╚══██╔══╝██║  ██║██╔════╝██╔══██╗██╔═══██╗██╔════╝  ║
║    ███████║██║   ██║   ███████║█████╗  ██████╔╝██║   ██║███████╗  ║
║    ██╔══██║██║   ██║   ██╔══██║██╔══╝  ██╔══██╗██║   ██║╚════██║  ║
║    ██║  ██║██║   ██║   ██║  ██║███████╗██║  ██║╚██████╔╝███████║  ║
║    ╚═╝  ╚═╝╚═╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝  ║
║                                                                   ║
║              PARTNER DEPLOYMENT ENGINE v2.0                       ║
║                                                                   ║
╠═══════════════════════════════════════════════════════════════════╣
║  Mode:        Pull (compiled images from GHCR)                    ║
║  Modules:     $($modulesStr.PadRight(50))║
║  Registry:    $($Registry.PadRight(50))║
║  Tag:         $($ImageTag.PadRight(50))║
╚═══════════════════════════════════════════════════════════════════╝

"@
Write-Host $banner -ForegroundColor Cyan

if ($DryRun) {
    Write-Host "[DRY RUN] Showing deployment plan — nothing will be executed.`n" -ForegroundColor Yellow
}

# ═══════════════════════════════════════════════════════════════
# PHASE RUNNER
# ═══════════════════════════════════════════════════════════════

function Invoke-Phase {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Action,
        [switch]$ContinueOnError
    )

    $phaseStart = Get-Date
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "  PHASE: $Name" -ForegroundColor Cyan
    Write-Host "  $Description" -ForegroundColor Gray
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would execute: $Name" -ForegroundColor Yellow
        $results.Phase[$Name] = @{ Status = 'DryRun'; Duration = '0s' }
        return $true
    }

    try {
        & $Action
        $duration = (Get-Date) - $phaseStart
        $results.Phase[$Name] = @{ Status = 'Success'; Duration = "$([math]::Round($duration.TotalSeconds))s" }
        Write-Host "  ✓ $Name completed ($([math]::Round($duration.TotalSeconds))s)" -ForegroundColor Green
        return $true
    }
    catch {
        $duration = (Get-Date) - $phaseStart
        $results.Phase[$Name] = @{ Status = 'Failed'; Duration = "$([math]::Round($duration.TotalSeconds))s"; Error = $_.Exception.Message }
        $results.Errors += "$Name : $($_.Exception.Message)"

        if ($ContinueOnError) {
            Write-Warning "  ⚠ $Name failed (non-fatal): $($_.Exception.Message)"
            return $true
        }
        else {
            Write-Host "  ✗ $Name FAILED: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1: HARDWARE DETECTION
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Hardware Detection" -Description "Detecting GPU, CPU, RAM, and selecting GPU profile" -Action {
    # --- GPU Detection ---
    $gpuName = "Unknown"
    $gpuVramGb = 0

    try {
        $nvidiaSmi = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $nvidiaSmi) {
            $parts = $nvidiaSmi -split ','
            $gpuName = $parts[0].Trim()
            $vramMb = [int]$parts[1].Trim()
            $gpuVramGb = [math]::Floor($vramMb / 1024)
            Write-Host "    ✓ GPU: $gpuName ($gpuVramGb GB VRAM)" -ForegroundColor Green
        }
        else {
            Write-Host "    ⚠ No NVIDIA GPU detected (nvidia-smi not available)" -ForegroundColor Yellow
            Write-Host "      AitherOS will run in CPU-only mode via Ollama" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "    ⚠ GPU detection failed: $_" -ForegroundColor Yellow
    }

    # --- CPU Detection ---
    $cpuName = "Unknown"
    $cpuCores = 4
    $cpuThreads = [Environment]::ProcessorCount

    try {
        if ($IsWindows) {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $cpuName = $cpu.Name.Trim()
            $cpuCores = $cpu.NumberOfCores
            $cpuThreads = $cpu.NumberOfLogicalProcessors
        }
        elseif (Test-Path /proc/cpuinfo) {
            $cpuinfo = Get-Content /proc/cpuinfo -Raw
            $cpuName = ($cpuinfo -split "`n" | Where-Object { $_ -match "model name" } | Select-Object -First 1) -replace "model name\s*:\s*", ""
            $cpuCores = [math]::Max(1, $cpuThreads / 2)
        }
        Write-Host "    ✓ CPU: $cpuName ($cpuCores cores / $cpuThreads threads)" -ForegroundColor Green
    }
    catch {
        Write-Host "    ⚠ CPU detection limited" -ForegroundColor Yellow
    }

    # --- RAM Detection ---
    $ramGb = 16
    try {
        if ($IsWindows) {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $ramGb = [math]::Floor($cs.TotalPhysicalMemory / 1GB)
        }
        elseif (Test-Path /proc/meminfo) {
            $meminfo = Get-Content /proc/meminfo -Raw
            $memKb = [int64](($meminfo -split "`n" | Where-Object { $_ -match "MemTotal" }) -replace "[^0-9]", "")
            $ramGb = [math]::Floor($memKb / 1024 / 1024)
        }
        Write-Host "    ✓ RAM: $ramGb GB" -ForegroundColor Green
    }
    catch {
        Write-Host "    ⚠ RAM detection failed, assuming $ramGb GB" -ForegroundColor Yellow
    }

    # --- Timezone ---
    $timezone = "America/Los_Angeles"
    try {
        if ($IsWindows) {
            $ianaMap = @{
                "Pacific Standard Time"          = "America/Los_Angeles"
                "Mountain Standard Time"         = "America/Denver"
                "Central Standard Time"          = "America/Chicago"
                "Eastern Standard Time"          = "America/New_York"
                "UTC"                            = "UTC"
                "GMT Standard Time"              = "Europe/London"
                "Central European Standard Time" = "Europe/Berlin"
                "Tokyo Standard Time"            = "Asia/Tokyo"
                "AUS Eastern Standard Time"      = "Australia/Sydney"
            }
            $winTz = [System.TimeZoneInfo]::Local.Id
            if ($ianaMap.ContainsKey($winTz)) { $timezone = $ianaMap[$winTz] }
        }
        elseif (Test-Path /etc/timezone) {
            $timezone = (Get-Content /etc/timezone -Raw).Trim()
        }
        Write-Host "    ✓ Timezone: $timezone" -ForegroundColor Green
    }
    catch { }

    # --- Store detection results ---
    $results.HwDetected = @{
        GpuName    = $gpuName
        GpuVramGb  = $gpuVramGb
        CpuName    = $cpuName
        CpuCores   = $cpuCores
        CpuThreads = $cpuThreads
        RamGb      = $ramGb
        Timezone   = $timezone
    }

    # --- Auto-select GPU profile ---
    $selectedProfile = $GpuProfile
    if (-not $selectedProfile) {
        if ($gpuVramGb -ge 32) {
            $selectedProfile = "balanced"
            Write-Host "    → GPU Profile: balanced (${gpuVramGb}GB — dual vLLM mode)" -ForegroundColor Cyan
        }
        elseif ($gpuVramGb -ge 12) {
            $selectedProfile = "standard"
            Write-Host "    → GPU Profile: standard (${gpuVramGb}GB — single vLLM + Ollama)" -ForegroundColor Cyan
        }
        elseif ($gpuVramGb -ge 6) {
            $selectedProfile = "compact"
            Write-Host "    → GPU Profile: compact (${gpuVramGb}GB — Ollama only)" -ForegroundColor Cyan
        }
        else {
            $selectedProfile = "cpu-only"
            Write-Host "    → GPU Profile: cpu-only (no GPU or <6GB — Ollama CPU inference)" -ForegroundColor Cyan
        }
    }
    else {
        Write-Host "    → GPU Profile: $selectedProfile (manual override)" -ForegroundColor Cyan
    }

    $results.GpuProfile = $selectedProfile
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 2: ENVIRONMENT CONFIGURATION
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Configuration" -Description "Writing .env file with detected hardware" -Action {
    $envFile = Join-Path $projectRoot ".env"
    $hw = $results.HwDetected
    $gpuProf = $results.GpuProfile

    # Determine vLLM settings based on GPU profile AND intelligence module
    $hasIntelligence = 'intelligence' -in $moduleList
    $gpuCanVllm = $gpuProf -in @("balanced", "standard", "multimodel")
    $vllmEnabled = $hasIntelligence -and $gpuCanVllm
    $vllmUtil = switch ($gpuProf) {
        "balanced"   { "0.40" }
        "standard"   { "0.35" }
        "multimodel" { "0.19" }
        default      { "0.0" }
    }
    # vLLM URL: compose-internal when intelligence deployed, otherwise host
    $vllmUrl = if ($hasIntelligence) { 'http://vllm:8120' } else { 'http://host.docker.internal:8120' }

    $envContent = @"
# =============================================================================
# AitherOS Partner Deployment Configuration
# =============================================================================
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Re-run: pwsh -File ./AitherZero/library/automation-scripts/30-deploy/3030_Deploy-Partner.ps1
# =============================================================================

# Host Hardware (auto-detected)
AITHER_HOST_GPU_NAME=$($hw.GpuName)
AITHER_HOST_GPU_VRAM_GB=$($hw.GpuVramGb)
AITHER_HOST_CPU_NAME=$($hw.CpuName)
AITHER_HOST_CPU_CORES=$($hw.CpuCores)
AITHER_HOST_CPU_THREADS=$($hw.CpuThreads)
AITHER_HOST_RAM_GB=$($hw.RamGb)
AITHER_TIMEZONE=$($hw.Timezone)
TZ=$($hw.Timezone)

# Docker Settings
AITHER_DOCKER_MODE=true
AITHER_ENVIRONMENT=production
COMPOSE_PROFILES=$composeProfStr
AITHER_MODULES=$modulesStr
AITHER_LOG_LEVEL=INFO

# GPU Profile
AITHER_GPU_PROFILE=$gpuProf
AITHER_VLLM_ENABLED=$($vllmEnabled.ToString().ToLower())
AITHER_VLLM_GPU_UTIL=$vllmUtil

# Inference
AITHER_INFERENCE_MODE=$(if ($vllmEnabled) { 'hybrid' } else { 'ollama' })
OLLAMA_API_URL=http://host.docker.internal:11434
VLLM_URL=$vllmUrl

# Registry
AITHEROS_REGISTRY=$Registry
AITHEROS_IMAGE_TAG=$ImageTag

# Security
AITHER_MASTER_KEY=$(New-Guid)
POSTGRES_PASSWORD=$(New-Guid)
"@

    if (Test-Path $envFile) {
        if ($Force) {
            Write-Host "    Overwriting existing .env (--Force)" -ForegroundColor Yellow
        }
        else {
            Write-Host "    ✓ .env exists — merging hardware detection" -ForegroundColor Green
            # Read existing content and append/update hardware section
            $existing = Get-Content $envFile -Raw
            # Remove old hardware section if present
            $existing = $existing -replace "(?ms)# =+\r?\n# AitherOS Partner Deployment.*?POSTGRES_PASSWORD=[^\r\n]+\r?\n?", ""
            $existing = $existing -replace "(?ms)# =+\r?\n# HOST HARDWARE SPECS.*?AITHER_TIMEZONE=[^\r\n]+\r?\n?", ""
            $envContent = $existing.TrimEnd() + "`n`n" + $envContent
        }
    }

    Set-Content -Path $envFile -Value $envContent -Encoding UTF8 -NoNewline
    Write-Host "    ✓ .env written" -ForegroundColor Green

    # --- Create data directories ---
    $dataDirs = @('data', 'logs', 'cache', 'data/models', 'data/embeddings', 'data/chronicle')
    foreach ($dir in $dataDirs) {
        $fullPath = Join-Path $projectRoot $dir
        if (-not (Test-Path $fullPath)) {
            New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
        }
    }
    Write-Host "    ✓ Data directories ready" -ForegroundColor Green
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 3: GHCR AUTHENTICATION
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Registry Auth" -Description "Authenticating with $Registry" -ContinueOnError -Action {
    # Check if already authenticated
    $testPull = docker pull "$Registry/aitheros-core:$ImageTag" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    ✓ Already authenticated with $Registry" -ForegroundColor Green
        return
    }

    # Try GitHub CLI auth
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        Write-Host "    Authenticating via GitHub CLI..." -ForegroundColor Gray
        $token = gh auth token 2>$null
        if ($token) {
            $token | docker login ghcr.io -u USERNAME --password-stdin 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    ✓ Authenticated via gh CLI" -ForegroundColor Green
                return
            }
        }
    }

    # Try GITHUB_TOKEN env var
    if ($env:GITHUB_TOKEN) {
        Write-Host "    Authenticating via GITHUB_TOKEN..." -ForegroundColor Gray
        $env:GITHUB_TOKEN | docker login ghcr.io -u token --password-stdin 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ Authenticated via GITHUB_TOKEN" -ForegroundColor Green
            return
        }
    }

    Write-Host "    ⚠ Could not authenticate with GHCR" -ForegroundColor Yellow
    Write-Host "      If images are public, this is fine." -ForegroundColor DarkGray
    Write-Host "      If private, run: gh auth login  or set GITHUB_TOKEN" -ForegroundColor DarkGray
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 4: PULL COMPILED IMAGES
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Pull Images" -Description "Pulling Nuitka-compiled images from $Registry" -Action {
    if (-not (Test-Path $composeFile)) {
        throw "docker-compose.partner.yml not found at: $composeFile"
    }

    $env:COMPOSE_PROFILES = $composeProfStr
    $env:AITHEROS_REGISTRY = $Registry
    $env:AITHEROS_IMAGE_TAG = $ImageTag

    Write-Host "    Pulling images for modules: $modulesStr" -ForegroundColor Gray
    Write-Host "    Compose file: $composeFile" -ForegroundColor DarkGray
    Write-Host "    This may take 15-30 minutes on first run..." -ForegroundColor DarkGray

    $pullArgs = @("compose", "-f", $composeFile, "pull")
    if ($Force) {
        Write-Host "    --Force: pulling all layers fresh" -ForegroundColor Yellow
    }

    & docker @pullArgs 2>&1 | ForEach-Object {
        if ($_ -match 'Pulling|Downloaded|Pull complete|Already exists') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
        elseif ($_ -match 'error|Error|ERROR') {
            Write-Host "    $_" -ForegroundColor Red
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Image pull failed (exit code $LASTEXITCODE). Check registry access and internet connection."
    }
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 5: VOLUME SETUP
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Volume Setup" -Description "Creating persistent Docker volumes" -ContinueOnError -Action {
    $volumes = @(
        'aither-hf-cache',
        'aither-vllm-cache',
        'aither-optimized-models'
    )

    foreach ($vol in $volumes) {
        $exists = docker volume ls --format '{{.Name}}' 2>$null | Where-Object { $_ -eq $vol }
        if ($exists) {
            Write-Host "    ✓ $vol (exists)" -ForegroundColor Green
        }
        else {
            docker volume create $vol 2>&1 | Out-Null
            Write-Host "    ✓ $vol (created)" -ForegroundColor Green
        }
    }
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 6: START SERVICES
# ═══════════════════════════════════════════════════════════════

$ok = Invoke-Phase -Name "Service Startup" -Description "Starting AitherOS modules: $modulesStr" -Action {
    $env:COMPOSE_PROFILES = $composeProfStr

    $upArgs = @("compose", "-f", $composeFile, "up", "-d", "--remove-orphans")

    Write-Host "    Starting services..." -ForegroundColor Gray
    Write-Host "    docker $($upArgs -join ' ')" -ForegroundColor DarkGray

    & docker @upArgs 2>&1 | ForEach-Object {
        if ($_ -match 'Started|Created|Running') {
            Write-Host "    $_" -ForegroundColor Green
        }
        elseif ($_ -match 'error|Error') {
            Write-Host "    $_" -ForegroundColor Red
        }
        else {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Service startup failed (exit code $LASTEXITCODE)"
    }

    Write-Host "    Waiting for containers to initialize..." -ForegroundColor Gray
    Start-Sleep -Seconds 10
}
if (-not $ok) { exit 1 }

# ═══════════════════════════════════════════════════════════════
# PHASE 7: HEALTH VALIDATION
# ═══════════════════════════════════════════════════════════════

Invoke-Phase -Name "Health Check" -Description "Validating deployed services" -ContinueOnError -Action {
    $healthEndpoints = @{
        'Genesis' = 'http://localhost:8001/health'
        'Veil'    = 'http://localhost:3000'
    }

    if ('core' -in $moduleList) {
        $healthEndpoints['Chronicle'] = 'http://localhost:8121/health'
        $healthEndpoints['Node']      = 'http://localhost:8080/health'
        $healthEndpoints['Pulse']     = 'http://localhost:8081/health'
    }
    if ('intelligence' -in $moduleList) {
        $healthEndpoints['CognitionCore'] = 'http://localhost:8088/health'
    }
    if ('agents' -in $moduleList) {
        $healthEndpoints['Gateway'] = 'http://localhost:8777/health'
    }

    $maxRetries = 30
    $healthy = 0
    $total = $healthEndpoints.Count

    Write-Host "    Checking $total service(s)..." -ForegroundColor Gray

    foreach ($svc in $healthEndpoints.Keys) {
        $url = $healthEndpoints[$svc]
        $retries = 0
        $isOk = $false

        while (-not $isOk -and $retries -lt $maxRetries) {
            try {
                $response = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                if ($response.StatusCode -in 200..299) {
                    Write-Host "    ✓ $svc ($url)" -ForegroundColor Green
                    $isOk = $true
                    $healthy++
                }
            }
            catch {
                $retries++
                if ($retries % 10 -eq 0) {
                    Write-Host "    ⏳ $svc still starting... ($retries/$maxRetries)" -ForegroundColor DarkGray
                }
                Start-Sleep -Seconds 2
            }
        }

        if (-not $isOk) {
            Write-Host "    ✗ $svc ($url) — TIMEOUT" -ForegroundColor Red
            $results.Warnings += "$svc health check timed out"
        }
    }

    Write-Host ""
    $healthColor = if ($healthy -eq $total) { 'Green' } elseif ($healthy -gt 0) { 'Yellow' } else { 'Red' }
    Write-Host "    Health: $healthy/$total services responding" -ForegroundColor $healthColor
}

# ═══════════════════════════════════════════════════════════════
# PHASE 8: STATUS REPORT
# ═══════════════════════════════════════════════════════════════

Invoke-Phase -Name "Status" -Description "Deployment summary" -ContinueOnError -Action {
    Write-Host ""
    Write-Host "  Running containers:" -ForegroundColor Gray
    docker ps --filter "name=aither" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}" 2>&1 | ForEach-Object {
        Write-Host "    $_" -ForegroundColor White
    }
}

# ═══════════════════════════════════════════════════════════════
# FINAL REPORT
# ═══════════════════════════════════════════════════════════════

$totalDuration = (Get-Date) - $startTime
$successCount = ($results.Phase.Values | Where-Object { $_.Status -eq 'Success' }).Count
$failCount = ($results.Phase.Values | Where-Object { $_.Status -eq 'Failed' }).Count
$hw = $results.HwDetected

$statusColor = if ($failCount -eq 0) { 'Green' } elseif ($failCount -lt 3) { 'Yellow' } else { 'Red' }
$statusIcon = if ($failCount -eq 0) { '✓' } else { '⚠' }

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor $statusColor
Write-Host "║     $statusIcon AITHEROS PARTNER DEPLOYMENT COMPLETE                      ║" -ForegroundColor $statusColor
Write-Host "╠═══════════════════════════════════════════════════════════════════╣" -ForegroundColor $statusColor
Write-Host "║                                                                   ║" -ForegroundColor $statusColor
Write-Host "║  Duration:    $("$([math]::Round($totalDuration.TotalMinutes, 1)) minutes".PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║  Phases:      $("$successCount succeeded, $failCount failed".PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║  GPU Profile: $($results.GpuProfile.PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║  GPU:         $("$($hw.GpuName) ($($hw.GpuVramGb)GB)".PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║  CPU:         $("$($hw.CpuName)".Substring(0, [Math]::Min("$($hw.CpuName)".Length, 48)).PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║  RAM:         $("$($hw.RamGb) GB".PadRight(48))║" -ForegroundColor $statusColor
Write-Host "║                                                                   ║" -ForegroundColor $statusColor

if ($failCount -eq 0) {
    Write-Host "║  ACCESS POINTS:                                                   ║" -ForegroundColor $statusColor
    Write-Host "║  → Dashboard:    http://localhost:3000                             ║" -ForegroundColor $statusColor
    Write-Host "║  → Genesis API:  http://localhost:8001                             ║" -ForegroundColor $statusColor
    Write-Host "║  → API Docs:     http://localhost:8001/docs                        ║" -ForegroundColor $statusColor
}

if ($results.Warnings.Count -gt 0) {
    Write-Host "║                                                                   ║" -ForegroundColor Yellow
    Write-Host "║  WARNINGS:                                                        ║" -ForegroundColor Yellow
    foreach ($w in $results.Warnings | Select-Object -First 3) {
        $truncW = $w.Substring(0, [Math]::Min($w.Length, 56))
        Write-Host "║  ⚠ $($truncW.PadRight(56))║" -ForegroundColor Yellow
    }
}

Write-Host "║                                                                   ║" -ForegroundColor $statusColor
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor $statusColor
Write-Host ""

exit $(if ($failCount -eq 0) { 0 } else { 1 })
