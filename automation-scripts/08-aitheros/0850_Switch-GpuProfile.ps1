#Requires -Version 7.0

<#
.SYNOPSIS
    Switch between GPU profiles (dev, production, creative).
.DESCRIPTION
    Manages GPU profile switching for AitherOS vLLM fleet configuration.
    Controls VRAM allocation, model routing, and cloud API fallback chains.

    Profiles:
      dev        — All models local. Shared VRAM (35%+40%+18%+12%+5% = ~80%).
      production — Orchestrator 92% VRAM local. R1/coding/vision/img/3D → cloud.
      creative   — Orchestrator 35% + ComfyUI/Hunyuan3D local. R1/coding → cloud.
      standard   — Single orchestrator + Ollama reasoning (for 12-16 GB GPUs).
      gaming     — All AI models stopped. Maximum VRAM for gaming.

    Exit Codes:
      0 - Success
      1 - Invalid profile or missing dependencies
      2 - Missing required API keys
      3 - Docker Compose failure

.PARAMETER Profile
    The GPU profile to activate. Valid: dev, production, creative, gaming, standard.

.PARAMETER DryRun
    Show what would happen without making changes.

.PARAMETER SkipKeyCheck
    Skip API key validation (for offline testing).

.PARAMETER Force
    Force switch even if already on the requested profile.

.PARAMETER Status
    Show current profile status and exit.

.EXAMPLE
    # Switch to production profile (orchestrator 92% VRAM, fleet → cloud)
    ./0850_Switch-GpuProfile.ps1 -Profile production

.EXAMPLE
    # Switch back to dev (all models local)
    ./0850_Switch-GpuProfile.ps1 -Profile dev

.EXAMPLE
    # Check current status
    ./0850_Switch-GpuProfile.ps1 -Status

.EXAMPLE
    # Dry run — see what would change
    ./0850_Switch-GpuProfile.ps1 -Profile production -DryRun

.NOTES
    Stage: AitherOS
    Order: 0850
    Dependencies: none
    Tags: gpu, vram, profile, vllm, cloud, production, creative
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('dev', 'production', 'creative', 'gaming', 'standard')]
    [string]$Profile,

    [switch]$DryRun,
    [switch]$SkipKeyCheck,
    [switch]$Force,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Constants ─────────────────────────────────────────────────────────────────
$ProjectRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$ComposeFile = Join-Path $ProjectRoot 'docker-compose.aitheros.yml'
$GpuProfilesConfig = Join-Path $ProjectRoot 'AitherOS' 'config' 'gpu_profiles.yaml'

$ProfileConfigs = @{
    dev = @{
        Description     = 'Shared VRAM — all models local (35%+40%+18%+12%+5%)'
        ComposeOverride = $null
        ComposeProfiles = @()
        VramLayout      = @{
            orchestrator = '35%'; reasoning = '40%'; coding = '18%'
            vision = '12%'; embeddings = '5%'; free = '~6.5 GiB'
        }
        RequiredKeys    = @()
        Containers      = @{
            start = @('aither-vllm', 'aither-vllm-reasoning', 'aither-vllm-coding', 'aither-vllm-vision', 'aither-vllm-embeddings')
            stop  = @()
        }
        EnvOverrides    = @{
            AITHER_GPU_PROFILE    = 'dev'
            AITHER_INFERENCE_MODE = 'local'
        }
    }
    production = @{
        Description     = 'Max VRAM orchestrator (92%) — fleet → cloud APIs'
        ComposeOverride = Join-Path $ProjectRoot 'docker-compose.gpu-production.yml'
        ComposeProfiles = @()
        VramLayout      = @{
            orchestrator = '92%'; embeddings = '5%'
            reasoning = 'CLOUD (DeepSeek R1)'; coding = 'CLOUD (DeepSeek Coder)'
            vision = 'CLOUD (Gemini 3 Flash)'; free = '~1 GiB'
        }
        RequiredKeys    = @('DEEPSEEK_API_KEY', 'GOOGLE_API_KEY', 'REPLICATE_API_TOKEN')
        Containers      = @{
            start = @('aither-vllm', 'aither-vllm-embeddings')
            stop  = @('aither-vllm-reasoning', 'aither-vllm-coding', 'aither-vllm-vision')
        }
        EnvOverrides    = @{
            AITHER_GPU_PROFILE    = 'production'
            AITHER_INFERENCE_MODE = 'hybrid'
        }
    }
    creative = @{
        Description     = 'Creative pipeline — orchestrator 35% + ComfyUI/3D local'
        ComposeOverride = Join-Path $ProjectRoot 'docker-compose.gpu-creative.yml'
        ComposeProfiles = @('creative')
        VramLayout      = @{
            orchestrator = '35%'; embeddings = '5%'
            reasoning = 'CLOUD'; coding = 'CLOUD'; vision = 'CLOUD'
            comfyui = '~19 GiB'; free = '~1 GiB'
        }
        RequiredKeys    = @('DEEPSEEK_API_KEY', 'GOOGLE_API_KEY')
        Containers      = @{
            start = @('aither-vllm', 'aither-vllm-embeddings', 'comfyui', 'comfyui-3d', 'aitheros-hunyuan3d')
            stop  = @('aither-vllm-reasoning', 'aither-vllm-coding', 'aither-vllm-vision')
        }
        EnvOverrides    = @{
            AITHER_GPU_PROFILE    = 'creative'
            AITHER_INFERENCE_MODE = 'hybrid'
        }
    }
    gaming = @{
        Description     = 'All AI models stopped — maximum VRAM for gaming'
        ComposeOverride = $null
        ComposeProfiles = @()
        VramLayout      = @{
            orchestrator = 'STOPPED'; reasoning = 'STOPPED'; coding = 'STOPPED'
            vision = 'STOPPED'; embeddings = 'STOPPED'; free = '32 GiB'
        }
        RequiredKeys    = @()
        Containers      = @{
            start = @()
            stop  = @('aither-vllm', 'aither-vllm-reasoning', 'aither-vllm-coding', 'aither-vllm-vision', 'aither-vllm-embeddings')
        }
        EnvOverrides    = @{
            AITHER_GPU_PROFILE    = 'gaming'
            AITHER_INFERENCE_MODE = 'offline'
        }
    }
    standard = @{
        Description     = 'Single orchestrator + Ollama reasoning (12-16 GB GPUs)'
        ComposeOverride = $null
        ComposeProfiles = @()
        VramLayout      = @{
            orchestrator = '40%'; embeddings = '5%'
            reasoning = 'CPU Ollama'; coding = 'N/A'; vision = 'N/A'
            free = '~8 GiB'
        }
        RequiredKeys    = @()
        Containers      = @{
            start = @('aither-vllm', 'aither-vllm-embeddings')
            stop  = @('aither-vllm-reasoning', 'aither-vllm-coding', 'aither-vllm-vision')
        }
        EnvOverrides    = @{
            AITHER_GPU_PROFILE    = 'standard'
            AITHER_INFERENCE_MODE = 'local'
        }
    }
}

# ── Helper Functions ──────────────────────────────────────────────────────────

function Write-ProfileLog {
    param([string]$Message, [string]$Level = 'Info')
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'White' }
    }
    $prefix = switch ($Level) {
        'Info'    { '🔧' }
        'Success' { '✅' }
        'Warning' { '⚠️ ' }
        'Error'   { '❌' }
        default   { '  ' }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Get-CurrentProfile {
    # Check env var first
    $envProfile = $env:AITHER_GPU_PROFILE
    if ($envProfile) { return $envProfile }

    # Check running containers to infer profile
    try {
        $containers = docker ps --format '{{.Names}}' 2>$null
        if (-not $containers) { return 'unknown' }

        $hasReasoning = $containers -match 'aither-vllm-reasoning'
        $hasCoding = $containers -match 'aither-vllm-coding'
        $hasVision = $containers -match 'aither-vllm-vision'
        $hasComfyui = $containers -match 'comfyui'

        if ($hasReasoning -and $hasCoding -and $hasVision) { return 'dev' }
        if ($hasComfyui -and -not $hasReasoning) { return 'creative' }
        if (-not $hasReasoning -and -not $hasCoding -and -not $hasVision) { return 'production' }
        return 'dev'
    } catch {
        return 'unknown'
    }
}

function Test-ApiKeys {
    param([string[]]$RequiredKeys)

    $missing = @()
    foreach ($key in $RequiredKeys) {
        $value = [System.Environment]::GetEnvironmentVariable($key)
        if (-not $value) {
            # Also check .env file in project root
            $envFile = Join-Path $ProjectRoot '.env'
            if (Test-Path $envFile) {
                $envContent = Get-Content $envFile -Raw
                if ($envContent -match "$key=(.+)") {
                    continue
                }
            }
            $missing += $key
        }
    }
    return $missing
}

function Show-ProfileStatus {
    $current = Get-CurrentProfile
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║           🎮 GPU Profile Status                        ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan

    foreach ($name in @('dev', 'production', 'creative', 'standard', 'gaming')) {
        $config = $ProfileConfigs[$name]
        $active = if ($name -eq $current) { ' ◀ ACTIVE' } else { '' }
        $marker = if ($name -eq $current) { '🟢' } else { '⚪' }
        Write-Host "║  $marker $($name.PadRight(12)) $($config.Description.PadRight(38))$active" -ForegroundColor $(if ($name -eq $current) { 'Green' } else { 'Gray' })
    }

    Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  VRAM Layout ($current):" -ForegroundColor Cyan

    if ($ProfileConfigs.ContainsKey($current)) {
        $layout = $ProfileConfigs[$current].VramLayout
        foreach ($role in $layout.Keys | Sort-Object) {
            $value = $layout[$role]
            $color = if ($value -match 'CLOUD') { 'Magenta' } elseif ($value -match '%') { 'Green' } else { 'DarkGray' }
            Write-Host "║    $($role.PadRight(16)) $value" -ForegroundColor $color
        }
    }

    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # Show running vLLM containers
    Write-Host "  Running vLLM containers:" -ForegroundColor DarkGray
    try {
        docker ps --filter "name=aither-vllm" --format "    {{.Names}}  {{.Status}}" 2>$null | ForEach-Object {
            Write-Host $_ -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "    (docker not available)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Show-VramComparison {
    param([string]$FromProfile, [string]$ToProfile)

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
    Write-Host "  │  VRAM Allocation Change: $FromProfile → $ToProfile" -ForegroundColor DarkCyan
    Write-Host "  ├─────────────┬──────────────────┬────────────────────────┤" -ForegroundColor DarkCyan
    Write-Host "  │ Role        │ $($FromProfile.PadRight(16)) │ $($ToProfile.PadRight(22)) │" -ForegroundColor DarkCyan
    Write-Host "  ├─────────────┼──────────────────┼────────────────────────┤" -ForegroundColor DarkCyan

    $from = $ProfileConfigs[$FromProfile].VramLayout
    $to = $ProfileConfigs[$ToProfile].VramLayout
    $allRoles = ($from.Keys + $to.Keys) | Sort-Object -Unique

    foreach ($role in $allRoles) {
        $fromVal = if ($from.ContainsKey($role)) { $from[$role] } else { '—' }
        $toVal = if ($to.ContainsKey($role)) { $to[$role] } else { '—' }
        $changed = $fromVal -ne $toVal
        $color = if ($changed) { 'Yellow' } else { 'DarkGray' }
        Write-Host "  │ $($role.PadRight(11)) │ $($fromVal.PadRight(16)) │ $($toVal.PadRight(22)) │" -ForegroundColor $color
    }

    Write-Host "  └─────────────┴──────────────────┴────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
}

# ── Main Logic ────────────────────────────────────────────────────────────────

if ($Status) {
    Show-ProfileStatus
    exit 0
}

if (-not $Profile) {
    Write-ProfileLog "No profile specified. Use -Profile <dev|production|creative|standard|gaming> or -Status" 'Warning'
    Show-ProfileStatus
    exit 1
}

$currentProfile = Get-CurrentProfile
$targetConfig = $ProfileConfigs[$Profile]

Write-Host ""
Write-Host "  ⚡ GPU Profile Switch" -ForegroundColor Cyan
Write-Host "  ─────────────────────" -ForegroundColor DarkGray
Write-ProfileLog "$currentProfile → $Profile" 'Info'
Write-ProfileLog $targetConfig.Description 'Info'

# Check if already on target profile
if ($currentProfile -eq $Profile -and -not $Force) {
    Write-ProfileLog "Already on '$Profile' profile. Use -Force to re-apply." 'Warning'
    exit 0
}

# Show VRAM comparison
if ($currentProfile -ne 'unknown') {
    Show-VramComparison -FromProfile $currentProfile -ToProfile $Profile
}

# Validate API keys for cloud-routed profiles
if ($targetConfig.RequiredKeys.Count -gt 0 -and -not $SkipKeyCheck) {
    Write-ProfileLog "Validating required API keys..." 'Info'
    $missingKeys = Test-ApiKeys -RequiredKeys $targetConfig.RequiredKeys
    if ($missingKeys.Count -gt 0) {
        Write-ProfileLog "Missing required API keys for '$Profile' profile:" 'Error'
        foreach ($key in $missingKeys) {
            Write-Host "    ❌ $key" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "  Set keys via:" -ForegroundColor Yellow
        Write-Host "    `$env:$($missingKeys[0]) = 'your-key-here'" -ForegroundColor DarkYellow
        Write-Host "    # Or add to .env file in project root" -ForegroundColor DarkGray
        Write-Host ""
        exit 2
    }
    Write-ProfileLog "All required API keys present." 'Success'
}

if ($DryRun) {
    Write-ProfileLog "[DRY RUN] Would execute the following:" 'Warning'
    Write-Host ""

    if ($targetConfig.Containers.stop.Count -gt 0) {
        Write-Host "  Stop containers:" -ForegroundColor Yellow
        $targetConfig.Containers.stop | ForEach-Object { Write-Host "    docker stop $_" -ForegroundColor DarkYellow }
    }

    $composeCmd = "docker compose -f docker-compose.aitheros.yml"
    if ($targetConfig.ComposeOverride) {
        $overrideName = Split-Path $targetConfig.ComposeOverride -Leaf
        $composeCmd += " -f $overrideName"
    }
    foreach ($p in $targetConfig.ComposeProfiles) {
        $composeCmd += " --profile $p"
    }
    $composeCmd += " up -d"

    Write-Host "  Compose command:" -ForegroundColor Yellow
    Write-Host "    $composeCmd" -ForegroundColor DarkYellow

    Write-Host "  Environment:" -ForegroundColor Yellow
    foreach ($kv in $targetConfig.EnvOverrides.GetEnumerator()) {
        Write-Host "    $($kv.Key) = $($kv.Value)" -ForegroundColor DarkYellow
    }
    Write-Host ""
    exit 0
}

# ── Execute Profile Switch ────────────────────────────────────────────────────

if ($PSCmdlet.ShouldProcess("GPU Profile", "Switch to $Profile")) {
    # Step 1: Set environment variable
    Write-ProfileLog "Setting AITHER_GPU_PROFILE=$Profile" 'Info'
    $env:AITHER_GPU_PROFILE = $Profile
    foreach ($kv in $targetConfig.EnvOverrides.GetEnumerator()) {
        [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Process')
    }

    # Step 2: Stop containers that should not run in new profile
    if ($targetConfig.Containers.stop.Count -gt 0) {
        Write-ProfileLog "Stopping disabled containers..." 'Info'
        foreach ($container in $targetConfig.Containers.stop) {
            try {
                docker stop $container 2>$null | Out-Null
                Write-Host "    Stopped: $container" -ForegroundColor DarkGray
            } catch {
                # Container may not be running — that's fine
            }
        }
    }

    # Step 3: Build compose command
    $composeArgs = @('-f', $ComposeFile)

    if ($targetConfig.ComposeOverride -and (Test-Path $targetConfig.ComposeOverride)) {
        $composeArgs += @('-f', $targetConfig.ComposeOverride)
        Write-ProfileLog "Using compose override: $(Split-Path $targetConfig.ComposeOverride -Leaf)" 'Info'
    }

    foreach ($p in $targetConfig.ComposeProfiles) {
        $composeArgs += @('--profile', $p)
    }

    $composeArgs += @('up', '-d')

    # Step 4: Apply compose configuration
    Write-ProfileLog "Applying compose configuration..." 'Info'
    Write-Host "    docker compose $($composeArgs -join ' ')" -ForegroundColor DarkGray

    $result = & docker compose @composeArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        Write-ProfileLog "Docker Compose failed (exit code: $exitCode)" 'Error'
        $result | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
        exit 3
    }

    # Step 5: Wait for health checks
    Write-ProfileLog "Waiting for orchestrator health..." 'Info'
    $maxWait = 120
    $waited = 0
    $healthy = $false

    while ($waited -lt $maxWait) {
        try {
            $health = Invoke-RestMethod -Uri 'http://localhost:8120/health' -TimeoutSec 5 -ErrorAction SilentlyContinue
            if ($health) {
                $healthy = $true
                break
            }
        } catch { }
        Start-Sleep -Seconds 5
        $waited += 5
        Write-Host "    Waiting... ($waited/$maxWait s)" -ForegroundColor DarkGray
    }

    if ($healthy) {
        Write-ProfileLog "Orchestrator healthy on port 8120" 'Success'
    } else {
        Write-ProfileLog "Orchestrator health check timed out (may still be loading model)" 'Warning'
    }

    # Step 6: Update .env file with profile
    $envFile = Join-Path $ProjectRoot '.env'
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        if ($envContent -match 'AITHER_GPU_PROFILE=') {
            $envContent = $envContent -replace 'AITHER_GPU_PROFILE=\w+', "AITHER_GPU_PROFILE=$Profile"
        } else {
            $envContent += "`nAITHER_GPU_PROFILE=$Profile`n"
        }
        Set-Content $envFile $envContent -NoNewline
        Write-ProfileLog "Updated .env: AITHER_GPU_PROFILE=$Profile" 'Info'
    }

    # Step 7: Summary
    Write-Host ""
    Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Green
    Write-ProfileLog "GPU Profile switched to: $Profile" 'Success'
    Write-Host "  ═══════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

    Show-ProfileStatus
}
