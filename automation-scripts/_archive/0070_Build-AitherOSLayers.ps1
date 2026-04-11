<#
.SYNOPSIS
    Builds AitherOS Atomic container images (bootc layers).
    
.DESCRIPTION
    This script builds the layered container images for AitherOS Atomic:
    - Base layer (RockyLinux 9 bootc)
    - Desktop layer (Minimal X11 + Openbox + AitherDesktop PyQt6)
    - GPU layer (NVIDIA drivers + container toolkit)
    - AitherOS layer (full service stack with 70+ containerized services)
    
    Services included in AitherOS layer:
    - Core: Chronicle, Pulse, Node, Watch, Secrets, Events, Strata, Veil
    - Intelligence: LLM, Mind, Reasoning, Judge, Flow, Will, Council, Tag, etc.
    - Perception: Vision, Voice, Portal, Sense, Browser, Reflex, TimeSense
    - Memory: WorkingMemory, Chain, Context, Spirit, Active, Conduit, Nexus, etc.
    - Training: Prism, Trainer, Harvest, Evolution
    - Autonomic: Autonomic, Scheduler, Demand, Force, Sandbox, Scope
    - Security: Identity, Recover, Sentry, Inspector, Flux, Chaos, Jail
    - Agents: Demiurge, Orchestrator, Forge, Intent, Director
    - Gateway: Gateway, A2A, Mesh, Deployer, AitherNet, Comet
    - GPU: Parallel, Accel, Exo, ExoNodes
    - MCP: MCPVision, MCPCanvas, MCPMind, MCPMemory
    - External: Ollama, Redis, PostgreSQL, ComfyUI
    
.PARAMETER Layer
    Which layer to build: base, desktop, gpu, aitheros, or all

.PARAMETER DesktopMode
    Desktop mode for AitherDesktop:
    - aither: Minimal X11 + Openbox (default, recommended)
    - hybrid: Adds file manager, terminal, browser
    - kiosk: Fullscreen AitherDesktop only

.PARAMETER Push
    Push images to registry after building

.PARAMETER Registry
    Container registry (default: ghcr.io/aitherium)

.PARAMETER Tag
    Image tag (default: latest)

.PARAMETER NoBuildCache
    Disable build cache for clean builds

.PARAMETER ShowOutput
    Show verbose build output

.PARAMETER CloudTarget
    Deploy to cloud after build: gke, gce, hyperv, or none (default)

.PARAMETER NodeRole
    Node role for deployment: controller, gpu-worker, cpu-worker, edge, full

.EXAMPLE
    ./0070_Build-AitherOSLayers.ps1 -Layer all -ShowOutput
    
.EXAMPLE
    ./0070_Build-AitherOSLayers.ps1 -Layer desktop -DesktopMode hybrid
    
.EXAMPLE
    ./0070_Build-AitherOSLayers.ps1 -Layer gpu -Push

.EXAMPLE
    ./0070_Build-AitherOSLayers.ps1 -Layer all -Push -CloudTarget gke

.EXAMPLE
    ./0070_Build-AitherOSLayers.ps1 -Layer all -CloudTarget hyperv -NodeRole gpu-worker
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('base', 'desktop', 'gpu', 'aitheros', 'all')]
    [string]$Layer = 'all',
    
    [Parameter()]
    [ValidateSet('aither', 'hybrid', 'kiosk')]
    [string]$DesktopMode = 'aither',
    
    [Parameter()]
    [switch]$Push,
    
    [Parameter()]
    [string]$Registry = 'ghcr.io/aitherium',
    
    [Parameter()]
    [string]$Tag = 'latest',
    
    [Parameter()]
    [switch]$NoBuildCache,
    
    [Parameter()]
    [switch]$ShowOutput,
    
    [Parameter()]
    [ValidateSet('none', 'gke', 'gce', 'hyperv')]
    [string]$CloudTarget = 'none',
    
    [Parameter()]
    [ValidateSet('controller', 'gpu-worker', 'cpu-worker', 'edge', 'full')]
    [string]$NodeRole = 'full'
)

# Initialize script
$ErrorActionPreference = 'Stop'

# Source shared utilities
$initPath = Join-Path $PSScriptRoot '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

# ==============================================================================
# Configuration
# ==============================================================================

$AtomicRoot = Join-Path $PSScriptRoot '..\..\..\..\AitherOS\AitherDesktop\atomic'
$LayersDir = Join-Path $AtomicRoot 'layers'
$CloudDir = Join-Path $AtomicRoot 'cloud'
$SystemdDir = Join-Path $AtomicRoot 'systemd'

$Images = @{
    base = @{
        Name = "aitheros-base"
        File = "Containerfile.base"
        Args = @{}
    }
    desktop = @{
        Name = "aitheros-desktop"
        File = "Containerfile.desktop"
        Args = @{ DESKTOP_MODE = $DesktopMode }
    }
    gpu = @{
        Name = "aitheros-gpu-nvidia"
        File = "Containerfile.gpu-nvidia"
        Args = @{}
    }
    aitheros = @{
        Name = "aitheros"
        File = "Containerfile.aitheros"
        Args = @{}
        ServiceCount = 70  # Core + Intelligence + Perception + Memory + Training + Autonomic + Security + Agents + Gateway + GPU + MCP + External
    }
}

# Build order (dependencies)
$BuildOrder = @('base', 'desktop', 'gpu', 'aitheros')

# Service manifest for documentation
$ServiceManifest = @{
    Core = @('chronicle', 'pulse', 'node', 'watch', 'secrets', 'events', 'strata', 'veil')
    Intelligence = @('llm', 'mind', 'reasoning', 'judge', 'flow', 'will', 'council', 'tag', 'faculties', 'cortex', 'search', 'daydream', 'safety')
    Perception = @('vision', 'voice', 'portal', 'sense', 'browser', 'reflex', 'timesense')
    Memory = @('workingmemory', 'chain', 'enviro', 'context', 'spiritmem', 'sensorybuffer', 'conduit', 'persona', 'nexus', 'memory')
    Training = @('prism', 'trainer', 'harvest', 'evolution')
    Autonomic = @('autonomic', 'scheduler', 'demand', 'force', 'sandbox', 'scope')
    Security = @('identity', 'recover', 'sentry', 'inspector', 'flux', 'chaos', 'jail')
    Agents = @('demiurge', 'orchestrator', 'forge', 'intent', 'director')
    Gateway = @('gateway', 'a2a', 'mesh', 'deployer', 'aithernet', 'comet')
    GPU = @('parallel', 'accel', 'exo', 'exonodes')
    MCP = @('mcpvision', 'mcpcanvas', 'mcpmind', 'mcpmemory')
    External = @('ollama', 'redis', 'postgres', 'comfyui')
}

# ==============================================================================
# Functions
# ==============================================================================

function Build-Layer {
    param(
        [string]$LayerName
    )
    
    $config = $Images[$LayerName]
    $imageName = "$Registry/$($config.Name):$Tag"
    $containerfile = Join-Path $LayersDir $config.File
    
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host "  Building: $imageName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    
    if (-not (Test-Path $containerfile)) {
        Write-Error "Containerfile not found: $containerfile"
        return $false
    }
    
    # Build arguments
    $buildArgs = @(
        'build'
        '-f', $containerfile
        '-t', $imageName
    )
    
    # Add build args
    foreach ($key in $config.Args.Keys) {
        $buildArgs += '--build-arg'
        $buildArgs += "$key=$($config.Args[$key])"
    }
    
    if ($NoBuildCache) {
        $buildArgs += '--no-cache'
    }
    
    $buildArgs += $AtomicRoot
    
    Write-Host "  Command: podman $($buildArgs -join ' ')" -ForegroundColor DarkGray
    
    # Execute build
    $process = Start-Process -FilePath 'podman' -ArgumentList $buildArgs -NoNewWindow -Wait -PassThru
    
    if ($process.ExitCode -ne 0) {
        Write-Host "  ✗ Build failed for $LayerName" -ForegroundColor Red
        return $false
    }
    
    Write-Host "  ✓ Built: $imageName" -ForegroundColor Green
    return $true
}

function Push-Layer {
    param(
        [string]$LayerName
    )
    
    $config = $Images[$LayerName]
    $imageName = "$Registry/$($config.Name):$Tag"
    
    Write-Host "  Pushing: $imageName" -ForegroundColor Cyan
    
    $process = Start-Process -FilePath 'podman' -ArgumentList @('push', $imageName) -NoNewWindow -Wait -PassThru
    
    if ($process.ExitCode -ne 0) {
        Write-Host "  ✗ Push failed for $imageName" -ForegroundColor Red
        return $false
    }
    
    Write-Host "  ✓ Pushed: $imageName" -ForegroundColor Green
    return $true
}

# ==============================================================================
# Main
# ==============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS Atomic Layer Builder                       ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Verify podman is available
if (-not (Get-Command 'podman' -ErrorAction SilentlyContinue)) {
    Write-Error "Podman is required but not found in PATH"
    exit 1
}

# Determine which layers to build
$layersToBuild = if ($Layer -eq 'all') {
    $BuildOrder
} else {
    @($Layer)
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Layers:       $($layersToBuild -join ', ')"
Write-Host "  Desktop Mode: $DesktopMode (aither=minimal, hybrid=with extras, kiosk=fullscreen)"
Write-Host "  Registry:     $Registry"
Write-Host "  Tag:          $Tag"
Write-Host "  Push:         $Push"

# Build each layer
$success = $true
$builtLayers = @()

foreach ($layerName in $layersToBuild) {
    if (Build-Layer -LayerName $layerName) {
        $builtLayers += $layerName
        
        if ($Push) {
            if (-not (Push-Layer -LayerName $layerName)) {
                $success = $false
            }
        }
    } else {
        $success = $false
        break
    }
}

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue

foreach ($layerName in $builtLayers) {
    $config = $Images[$layerName]
    Write-Host "  ✓ $Registry/$($config.Name):$Tag" -ForegroundColor Green
}

if ($success) {
    Write-Host ""
    Write-Host "  All layers built successfully!" -ForegroundColor Green
    
    # Cloud deployment if requested
    if ($CloudTarget -ne 'none') {
        Write-Host ""
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
        Write-Host "  Cloud Deployment: $CloudTarget" -ForegroundColor Cyan
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
        
        $cloudScript = switch ($CloudTarget) {
            'gke' { Join-Path $CloudDir 'gcp-init.sh' }
            'gce' { Join-Path $CloudDir 'gcp-init.sh' }
            'hyperv' { Join-Path $CloudDir 'hyperv-deploy.ps1' }
        }
        
        if (Test-Path $cloudScript) {
            Write-Host "  Deploying to $CloudTarget with role: $NodeRole" -ForegroundColor Yellow
            
            if ($CloudTarget -eq 'hyperv') {
                & $cloudScript -Role $NodeRole -StartVM
            } else {
                Write-Host "  Run: $cloudScript --$CloudTarget --role $NodeRole" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  Cloud deployment script not found: $cloudScript" -ForegroundColor Yellow
            Write-Host "  Run manually from: $CloudDir" -ForegroundColor DarkGray
        }
    }
    
    # Show service summary
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    Write-Host "  Service Summary (70+ containerized services)" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
    foreach ($category in $ServiceManifest.Keys | Sort-Object) {
        $services = $ServiceManifest[$category]
        Write-Host "  $category ($($services.Count)): $($services[0..2] -join ', ')..." -ForegroundColor DarkGray
    }
    
    exit 0
} else {
    Write-Host ""
    Write-Host "  Build failed. Check output above." -ForegroundColor Red
    exit 1
}
