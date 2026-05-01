#Requires -Version 7.0

<#
.SYNOPSIS
    Setup complete Roboflow development environment for the 3D Asset Pipeline project

.DESCRIPTION
    Automates full environment setup: Python venv, Docker inference server,
    Roboflow SDK/CLI, folder structure, API key configuration, and health checks.

    IDEMPOTENT: Safe to run multiple times. Skips already-completed steps.
    ATOMIC CLEANUP: -Clean removes everything this script created.

    Exit Codes:
    0 - Success
    1 - Prerequisites missing
    2 - Docker/inference server failed

.PARAMETER ApiKey
    Roboflow API key (optional — only needed for cloud training/upload)

.PARAMETER SkipDocker
    Skip Docker inference server setup

.PARAMETER SkipVenv
    Skip Python virtual environment creation

.PARAMETER GpuPort
    Port for inference server (default: 9001)

.PARAMETER ForceCpu
    Force CPU inference server even if GPU is available

.PARAMETER Force
    Force re-creation of venv and container even if they exist

.PARAMETER Clean
    ATOMIC CLEANUP: Tear down inference container, venv, generated scripts, .env, state file.
    Does NOT remove training data, outputs, custom blocks, or docs.

.PARAMETER CleanAll
    FULL CLEANUP: Remove the entire .roboflow directory tree

.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7030
    Dependencies: none
    Tags: roboflow, computer-vision, 3d-pipeline, setup
    AllowParallel: false

.EXAMPLE
    .\7030_Setup-Roboflow.ps1

.EXAMPLE
    .\7030_Setup-Roboflow.ps1 -Clean

.EXAMPLE
    .\7030_Setup-Roboflow.ps1 -ForceCpu
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ApiKey,
    [switch]$SkipDocker,
    [switch]$SkipVenv,
    [int]$GpuPort = 9002,
    [switch]$ForceCpu,
    [switch]$Force,
    [switch]$Clean,
    [switch]$CleanAll,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$venvPath     = Join-Path $roboflowRoot ".venv"
$envFile      = Join-Path $roboflowRoot ".env"
$scriptsDir   = Join-Path $roboflowRoot "scripts"
$containerGpu = "roboflow-inference-gpu"
$containerCpu = "roboflow-inference-cpu"

# ═══════════════════════════════════════════════════════════════════════
#  CLEANUP PATH
# ═══════════════════════════════════════════════════════════════════════
if ($Clean -or $CleanAll) {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║       Roboflow Pipeline — Atomic Cleanup                  ║" -ForegroundColor Red
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""

    foreach ($name in @($containerGpu, $containerCpu)) {
        $exists = docker ps -a --filter "name=^${name}$" --format "{{.Names}}" 2>$null
        if ($exists) {
            if (-not $DryRun) {
                docker stop $name 2>$null | Out-Null
                docker rm -f $name 2>$null | Out-Null
            }
            Write-Host "  ✓ Removed container: $name" -ForegroundColor Yellow
        } else {
            Write-Host "  ○ Container not found: $name" -ForegroundColor Gray
        }
    }

    if (Test-Path $venvPath) {
        if (-not $DryRun) { Remove-Item -Recurse -Force $venvPath }
        Write-Host "  ✓ Removed venv" -ForegroundColor Yellow
    }

    if (Test-Path $scriptsDir) {
        $generated = Get-ChildItem $scriptsDir -File -Filter "_*.py" -ErrorAction SilentlyContinue
        foreach ($f in $generated) {
            if (-not $DryRun) { Remove-Item $f.FullName -Force }
            Write-Host "  ✓ Removed: $($f.Name)" -ForegroundColor Yellow
        }
        foreach ($f in @("start_inference.ps1", "stop_inference.ps1", "health_check.ps1", "add_images.ps1", "start_model.ps1", "test_inference.ps1", "validate_workflow.ps1", "run_workflow.ps1")) {
            $fp = Join-Path $scriptsDir $f
            if (Test-Path $fp) {
                if (-not $DryRun) { Remove-Item $fp -Force }
                Write-Host "  ✓ Removed: $f" -ForegroundColor Yellow
            }
        }
    }

    foreach ($f in @($envFile, (Join-Path $roboflowRoot "pipeline_state.json"))) {
        if (Test-Path $f) {
            if (-not $DryRun) { Remove-Item $f -Force }
            Write-Host "  ✓ Removed: $(Split-Path $f -Leaf)" -ForegroundColor Yellow
        }
    }

    if ($CleanAll -and (Test-Path $roboflowRoot)) {
        if (-not $DryRun) { Remove-Item -Recurse -Force $roboflowRoot }
        Write-Host "  ✓ Removed entire .roboflow directory" -ForegroundColor Red
    }

    Write-Host "`n  Cleanup complete. Run without -Clean to set up again.`n" -ForegroundColor Green
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════
#  SETUP PATH
# ═══════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow 3D Asset Pipeline — Environment Setup      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Prerequisites ────────────────────────────────────────────
Write-Host "Step 1: Checking prerequisites..." -ForegroundColor Yellow

$prerequisites = @(
    @{ Name = "Python";  Command = "python --version"; Required = $true },
    @{ Name = "Docker";  Command = "docker --version"; Required = (-not $SkipDocker) },
    @{ Name = "Git";     Command = "git --version";    Required = $false },
    @{ Name = "ffmpeg";  Command = "ffmpeg -version";  Required = $false }
)

$failed = $false
foreach ($prereq in $prerequisites) {
    try {
        $null = Invoke-Expression $prereq.Command 2>$null
        Write-Host "  ✓ $($prereq.Name)" -ForegroundColor Green
    } catch {
        if ($prereq.Required) { Write-Host "  ✗ $($prereq.Name) — REQUIRED" -ForegroundColor Red; $failed = $true }
        else { Write-Host "  ○ $($prereq.Name) — optional" -ForegroundColor Gray }
    }
}
if ($failed) { Write-Host "`nInstall missing prerequisites and re-run." -ForegroundColor Red; exit 1 }

$dockerOk = $false
$gpuInDocker = $false
if (-not $SkipDocker) {
    try { docker info 2>$null | Out-Null; Write-Host "  ✓ Docker daemon running" -ForegroundColor Green; $dockerOk = $true }
    catch { Write-Host "  ✗ Docker daemon not running" -ForegroundColor Red; exit 1 }

    $freeVramMb = 0
    try {
        $freeVramRaw = (nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null).Trim()
        $freeVramMb = [int]$freeVramRaw
        Write-Host "  ✓ GPU free VRAM: ${freeVramMb} MB" -ForegroundColor Green
    } catch { Write-Host "  ○ No NVIDIA GPU detected" -ForegroundColor Gray }

    if ($ForceCpu) {
        Write-Host "  → Forcing CPU inference server" -ForegroundColor Yellow
    } elseif ($freeVramMb -lt 2048) {
        Write-Host "  ⚠ Low VRAM (${freeVramMb} MB) — falling back to CPU" -ForegroundColor Yellow
        $ForceCpu = $true
    } else {
        try {
            $gpuTest = docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi 2>$null
            if ($gpuTest) { $gpuInDocker = $true; Write-Host "  ✓ NVIDIA Container Toolkit available" -ForegroundColor Green }
        } catch { Write-Host "  ⚠ NVIDIA Container Toolkit not detected — using CPU" -ForegroundColor Yellow; $ForceCpu = $true }
    }
}
Write-Host ""

# ── Step 2: Folder Structure (idempotent) ────────────────────────────
Write-Host "Step 2: Folder structure..." -ForegroundColor Yellow
$folders = @(
    "project", "custom_blocks", "workflow",
    "training_data/raw", "training_data/annotated", "training_data/augmented",
    "outputs/models_3d", "outputs/masks", "outputs/logs", "outputs/renders",
    "presentation/slides", "presentation/demo_recordings", "presentation/assets",
    "scripts", "notebooks"
)
$created = 0
foreach ($folder in $folders) {
    $fp = Join-Path $roboflowRoot $folder
    if (-not (Test-Path $fp)) { if (-not $DryRun) { New-Item -ItemType Directory -Path $fp -Force | Out-Null }; $created++ }
}
Write-Host "  ✓ $created new / $($folders.Count) total folders" -ForegroundColor Green
Write-Host ""

# ── Step 3: Config (.env) ────────────────────────────────────────────
Write-Host "Step 3: Environment config..." -ForegroundColor Yellow
$existingKey = ""
if ($ApiKey) { $existingKey = $ApiKey }
elseif ($env:ROBOFLOW_API_KEY) { $existingKey = $env:ROBOFLOW_API_KEY }
elseif (Test-Path $envFile) {
    $raw = Get-Content $envFile -Raw -ErrorAction SilentlyContinue
    if ($raw -match 'ROBOFLOW_API_KEY=(.+)') { $existingKey = $matches[1].Trim() }
}
if (-not $existingKey) {
    $rfEnv = Join-Path $roboflowRoot "roboflow.env"
    if (Test-Path $rfEnv) {
        $raw = Get-Content $rfEnv -Raw -ErrorAction SilentlyContinue
        if ($raw -match 'ROBOFLOW_API_KEY=(.+)') { $existingKey = $matches[1].Trim() }
    }
}

$useGpu = (-not $ForceCpu) -and $gpuInDocker
$containerName = if ($useGpu) { $containerGpu } else { $containerCpu }

if (-not $DryRun) {
    @"
# Roboflow 3D Asset Pipeline Configuration
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

ROBOFLOW_API_KEY=$existingKey
ROBOFLOW_WORKSPACE=wsnzs-workspace
ROBOFLOW_PROJECT=3d-asset-pipeline

INFERENCE_HOST=localhost
INFERENCE_PORT=$GpuPort
INFERENCE_GPU=$($useGpu.ToString().ToLower())
INFERENCE_CONTAINER=$containerName
ALLOW_CUSTOM_PYTHON_EXECUTION_IN_WORKFLOWS=True

MODEL_ID=3d-asset-pipeline/1
CONFIDENCE_THRESHOLD=0.5
IOU_THRESHOLD=0.45

AITHEROS_GENESIS=http://localhost:8001
AITHEROS_STRATA=http://localhost:8136
AITHEROS_MESHGEN=http://localhost:8788
AITHEROS_CANVAS=http://localhost:8108
AITHEROS_AUTORIG=http://localhost:8794
"@ | Set-Content $envFile -Force
}
Write-Host "  ✓ .env written (API key: $(if ($existingKey) {'set'} else {'none — local only'}))" -ForegroundColor Green
Write-Host ""

# ── Step 4: Python venv (idempotent) ─────────────────────────────────
if (-not $SkipVenv) {
    Write-Host "Step 4: Python venv..." -ForegroundColor Yellow
    if ((-not (Test-Path $venvPath)) -or $Force) {
        if ($Force -and (Test-Path $venvPath)) { if (-not $DryRun) { Remove-Item -Recurse -Force $venvPath } }
        if (-not $DryRun) { python -m venv $venvPath }
        Write-Host "  ✓ Venv created" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Venv exists" -ForegroundColor Gray
    }

    $pipPath = Join-Path $venvPath "Scripts/pip.exe"
    if (-not (Test-Path $pipPath)) { $pipPath = Join-Path $venvPath "bin/pip" }

    $packages = @("inference", "inference-sdk", "inference-cli", "roboflow", "supervision",
                   "opencv-python", "trimesh", "open3d", "numpy", "requests", "httpx", "Pillow", "matplotlib")

    if (-not $DryRun) {
        Write-Host "  Installing packages (idempotent — skips installed)..." -ForegroundColor Gray
        & $pipPath install --upgrade pip --quiet 2>$null
        & $pipPath install @packages --quiet 2>&1 | Out-Null
        Write-Host "  ✓ Packages ready" -ForegroundColor Green
    }
} else {
    Write-Host "Step 4: Skipping venv" -ForegroundColor Gray
}
Write-Host ""

# ── Step 5: Docker Inference Server (idempotent) ─────────────────────
if (-not $SkipDocker -and $dockerOk) {
    Write-Host "Step 5: Docker inference server..." -ForegroundColor Yellow
    $imageName = if ($useGpu) { "roboflow/roboflow-inference-server-gpu:latest" } else { "roboflow/roboflow-inference-server-cpu:latest" }
    $modeLabel = if ($useGpu) { "GPU" } else { "CPU" }
    Write-Host "  Mode: $modeLabel" -ForegroundColor $(if ($useGpu) {'Green'} else {'Yellow'})

    # Remove conflicting container type
    $otherName = if ($useGpu) { $containerCpu } else { $containerGpu }
    $otherExists = docker ps -a --filter "name=^${otherName}$" --format "{{.Names}}" 2>$null
    if ($otherExists) {
        if (-not $DryRun) { docker rm -f $otherName 2>$null | Out-Null }
        Write-Host "  Removed conflicting $otherName" -ForegroundColor Yellow
    }

    $existing = docker ps -a --filter "name=^${containerName}$" --format "{{.Names}}" 2>$null
    if ($existing -eq $containerName -and -not $Force) {
        $status = docker inspect $containerName --format "{{.State.Status}}" 2>$null
        if ($status -eq "running") {
            Write-Host "  ✓ Already running on port $GpuPort" -ForegroundColor Green
        } else {
            if (-not $DryRun) { docker start $containerName 2>$null | Out-Null }
            Write-Host "  ✓ Started existing container" -ForegroundColor Green
        }
    } else {
        if (-not $DryRun) {
            docker pull $imageName 2>$null
            if ($Force -and $existing) { docker rm -f $containerName 2>$null | Out-Null }
            $dockerArgs = @('run', '-d', '--name', $containerName, '--restart', 'unless-stopped',
                           '-p', "${GpuPort}:9001", '-v', "${HOME}/.inference/cache:/tmp/cache",
                           '-e', 'ALLOW_CUSTOM_PYTHON_EXECUTION_IN_WORKFLOWS=True')
            if ($useGpu) { $dockerArgs += @('--gpus', 'all') }
            if ($existingKey) { $dockerArgs += @('-e', "ROBOFLOW_API_KEY=$existingKey") }
            $dockerArgs += $imageName
            docker @dockerArgs 2>$null | Out-Null
        }
        Write-Host "  ✓ Started $containerName on port $GpuPort" -ForegroundColor Green
    }

    Write-Host "  Waiting for health..." -ForegroundColor Gray
    $healthy = $false
    for ($i = 0; $i -lt 30; $i++) {
        try { $r = Invoke-RestMethod -Uri "http://localhost:$GpuPort/healthz" -TimeoutSec 3 -ErrorAction SilentlyContinue; if ($r) { $healthy = $true; break } } catch { }
        Start-Sleep -Seconds 2
    }
    if ($healthy) { Write-Host "  ✓ Healthy" -ForegroundColor Green }
    else { Write-Host "  ⚠ Not responding yet — check: docker logs $containerName" -ForegroundColor Yellow }
} else {
    Write-Host "Step 5: Skipping Docker" -ForegroundColor Gray
}
Write-Host ""

# ── Step 6: Helper Scripts (always overwrite) ────────────────────────
Write-Host "Step 6: Helper scripts..." -ForegroundColor Yellow
if (-not $DryRun) {
    @'
#!/usr/bin/env pwsh
# Start Roboflow inference server (idempotent)
param([switch]$Gpu, [int]$Port = 9001)
$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$name = $env:INFERENCE_CONTAINER ?? $(if ($Gpu) {"roboflow-inference-gpu"} else {"roboflow-inference-cpu"})
$status = docker inspect $name --format "{{.State.Status}}" 2>$null
if ($status -eq "running") { Write-Host "Already running" -ForegroundColor Green; exit 0 }
$exists = docker ps -a --filter "name=^${name}$" --format "{{.Names}}" 2>$null
if ($exists) { docker start $name | Out-Null; Write-Host "Started $name" -ForegroundColor Green; exit 0 }
$img = if ($Gpu) {"roboflow/roboflow-inference-server-gpu:latest"} else {"roboflow/roboflow-inference-server-cpu:latest"}
$a = @('run','-d','--name',$name,'--restart','unless-stopped','-p',"${Port}:9001",'-v',"${HOME}/.inference/cache:/tmp/cache",'-e','ALLOW_CUSTOM_PYTHON_EXECUTION_IN_WORKFLOWS=True')
if ($Gpu) { $a += @('--gpus','all') }
if ($env:ROBOFLOW_API_KEY) { $a += @('-e',"ROBOFLOW_API_KEY=$($env:ROBOFLOW_API_KEY)") }
$a += $img; docker @a | Out-Null
Write-Host "Created $name on port $Port" -ForegroundColor Green
'@ | Set-Content (Join-Path $scriptsDir "start_inference.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Stop Roboflow inference (idempotent)
param([switch]$Remove)
foreach ($n in @("roboflow-inference-gpu","roboflow-inference-cpu")) {
    $e = docker ps -a --filter "name=^${n}$" --format "{{.Names}}" 2>$null
    if ($e) { docker stop $n 2>$null | Out-Null; if ($Remove) { docker rm $n 2>$null | Out-Null }; Write-Host "Stopped $n" -ForegroundColor Yellow }
}
'@ | Set-Content (Join-Path $scriptsDir "stop_inference.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Health check (read-only, idempotent)
$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$port = $env:INFERENCE_PORT ?? "9001"
Write-Host "Roboflow Health" -ForegroundColor Cyan
try { $null = Invoke-RestMethod "http://localhost:$port/healthz" -TimeoutSec 5; Write-Host "  ✓ Inference (:$port)" -ForegroundColor Green } catch { Write-Host "  ✗ Inference (:$port)" -ForegroundColor Red }
foreach ($n in @("roboflow-inference-gpu","roboflow-inference-cpu")) { $s = docker inspect $n --format "{{.State.Status}}" 2>$null; if ($s) { Write-Host "  $n: $s" -ForegroundColor Gray } }
try { $v = (nvidia-smi --query-gpu=memory.free --format=csv,noheader 2>$null).Trim(); Write-Host "  VRAM free: $v" -ForegroundColor Gray } catch {}
'@ | Set-Content (Join-Path $scriptsDir "health_check.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Add one or more images into .roboflow/training_data/raw (idempotent by name)
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path,
    [switch]$Recurse,
    [switch]$Force
)

$targetRoot = Join-Path $PSScriptRoot "../training_data/raw"
New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

$extensions = '.jpg', '.jpeg', '.png', '.webp'
$candidates = @()
foreach ($item in $Path) {
    if (Test-Path $item -PathType Container) {
        $searchArgs = @{ Path = $item; File = $true }
        if ($Recurse) { $searchArgs.Recurse = $true }
        $candidates += Get-ChildItem @searchArgs | Where-Object { $_.Extension.ToLower() -in $extensions }
    } elseif (Test-Path $item -PathType Leaf) {
        $candidates += Get-Item $item
    } else {
        Write-Warning "Not found: $item"
    }
}

foreach ($file in $candidates | Sort-Object FullName -Unique) {
    $destination = Join-Path $targetRoot $file.Name
    if ((Test-Path $destination) -and -not $Force) {
        Write-Host "Skipped existing $($file.Name)" -ForegroundColor Gray
        continue
    }
    Copy-Item $file.FullName $destination -Force:$Force
    Write-Host "Added $($file.Name)" -ForegroundColor Green
}
'@ | Set-Content (Join-Path $scriptsDir "add_images.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Start/load the configured model into local Roboflow inference
[CmdletBinding()]
param(
    [string]$ModelId,
    [string]$ApiKey
)

$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$port = $env:INFERENCE_PORT ?? '9002'
$model = if ($ModelId) { $ModelId } else { $env:MODEL_ID }
if (-not $model) { throw 'MODEL_ID not set. Update .roboflow/.env or pass -ModelId.' }

$parts = $model -split '/'
if ($parts.Count -lt 2) { throw "ModelId must look like dataset/version, got: $model" }

$effectiveApiKey = if ($ApiKey) { $ApiKey } else { $env:ROBOFLOW_API_KEY }
$uri = "http://localhost:$port/start/$($parts[0])/$($parts[1])"
if ($effectiveApiKey) { $uri += "?api_key=$effectiveApiKey" }

$response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 180
$response | ConvertTo-Json -Depth 8
'@ | Set-Content (Join-Path $scriptsDir "start_model.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Run object detection against local Roboflow inference
[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$ModelId,
    [double]$Confidence = 0.5,
    [switch]$SaveJson
)

$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$port = $env:INFERENCE_PORT ?? '9002'
$model = if ($ModelId) { $ModelId } else { $env:MODEL_ID }
if (-not $ImagePath) {
    $ImagePath = Get-ChildItem (Join-Path $PSScriptRoot '../training_data/raw') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLower() -in '.jpg', '.jpeg', '.png', '.webp' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ImagePath -or -not (Test-Path $ImagePath)) { throw 'No image found. Pass -ImagePath or stage one with add_images.ps1.' }
if (-not $model) { throw 'MODEL_ID not set. Update .roboflow/.env or pass -ModelId.' }

$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ImagePath))
$base64 = [Convert]::ToBase64String($bytes)
$body = @{
    id = [guid]::NewGuid().ToString()
    model_id = $model
    image = @{ type = 'base64'; value = $base64 }
    confidence = $Confidence
} | ConvertTo-Json -Depth 8

$response = Invoke-RestMethod -Uri "http://localhost:$port/infer/object_detection" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
if ($SaveJson) {
    $outputPath = Join-Path $PSScriptRoot '../outputs/logs/last_inference.json'
    New-Item -ItemType Directory -Path (Split-Path $outputPath -Parent) -Force | Out-Null
    $response | ConvertTo-Json -Depth 12 | Set-Content $outputPath -Force
    Write-Host "Saved $outputPath" -ForegroundColor Green
}
$response | ConvertTo-Json -Depth 12
'@ | Set-Content (Join-Path $scriptsDir "test_inference.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Validate the local workflow JSON against Roboflow inference
[CmdletBinding()]
param(
    [string]$WorkflowPath
)

$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$port = $env:INFERENCE_PORT ?? '9002'
$pathToUse = if ($WorkflowPath) { $WorkflowPath } else { Join-Path $PSScriptRoot '../workflow/asset_pipeline.json' }
if (-not (Test-Path $pathToUse)) { throw "Workflow file not found: $pathToUse" }

$body = Get-Content $pathToUse -Raw
$modelId = $env:MODEL_ID
if ($modelId) { $body = $body.Replace('${MODEL_ID}', $modelId) }
$response = Invoke-RestMethod -Uri "http://localhost:$port/workflows/validate" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
$response | ConvertTo-Json -Depth 12
'@ | Set-Content (Join-Path $scriptsDir "validate_workflow.ps1") -Force

    @'
#!/usr/bin/env pwsh
# Run the local workflow against a staged image
[CmdletBinding()]
param(
    [string]$ImagePath,
    [string]$WorkflowPath,
    [switch]$SaveJson
)

$envFile = Join-Path $PSScriptRoot "../.env"
if (Test-Path $envFile) { Get-Content $envFile | ForEach-Object { if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] } } }
$port = $env:INFERENCE_PORT ?? '9002'
$pathToUse = if ($WorkflowPath) { $WorkflowPath } else { Join-Path $PSScriptRoot '../workflow/asset_pipeline.json' }
if (-not (Test-Path $pathToUse)) { throw "Workflow file not found: $pathToUse" }
if (-not $ImagePath) {
    $ImagePath = Get-ChildItem (Join-Path $PSScriptRoot '../training_data/raw') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLower() -in '.jpg', '.jpeg', '.png', '.webp' } |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ImagePath -or -not (Test-Path $ImagePath)) { throw 'No image found. Pass -ImagePath or stage one with add_images.ps1.' }

$workflowJson = Get-Content $pathToUse -Raw
$modelId = $env:MODEL_ID
if ($modelId) { $workflowJson = $workflowJson.Replace('${MODEL_ID}', $modelId) }
$workflow = $workflowJson | ConvertFrom-Json
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ImagePath))
$base64 = [Convert]::ToBase64String($bytes)
$body = @{
    specification = $workflow
    inputs = @{
        image = @{ type = 'base64'; value = $base64 }
    }
} | ConvertTo-Json -Depth 40

$response = Invoke-RestMethod -Uri "http://localhost:$port/workflows/run" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 240
if ($SaveJson) {
    $outputPath = Join-Path $PSScriptRoot '../outputs/logs/last_workflow_run.json'
    New-Item -ItemType Directory -Path (Split-Path $outputPath -Parent) -Force | Out-Null
    $response | ConvertTo-Json -Depth 20 | Set-Content $outputPath -Force
    Write-Host "Saved $outputPath" -ForegroundColor Green
}
$response | ConvertTo-Json -Depth 20
'@ | Set-Content (Join-Path $scriptsDir "run_workflow.ps1") -Force
    Write-Host "  ✓ Generated" -ForegroundColor Green
}
Write-Host ""

# ── Summary ──────────────────────────────────────────────────────────
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    Setup Complete                          ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Inference:  http://localhost:$GpuPort ($(if ($useGpu){'GPU'}else{'CPU'}))" -ForegroundColor White
Write-Host "  Cleanup:    .\7030_Setup-Roboflow.ps1 -Clean" -ForegroundColor Gray
Write-Host "  Next:       .\7033_Build-Workflow.ps1 -Action Full" -ForegroundColor Yellow
Write-Host ""
exit 0

