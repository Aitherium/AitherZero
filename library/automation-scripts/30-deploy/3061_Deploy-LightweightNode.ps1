#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys a lightweight AitherNode (ADK + Ollama) to any machine.

.DESCRIPTION
    Minimal deployment for machines that just need to run agents and participate
    in the mesh. Does NOT require the full AitherOS stack.

    Three deployment options:
      adk     — pip install aither-adk only (Python agents, no containers)
      node    — AitherNode Docker container (mesh client, tools, discovery)
      edge    — EdgeNodeService standalone (no Docker, just Python + Ollama)

    Works on Windows, Linux, and macOS.

.PARAMETER Target
    Deployment target: adk | node | edge. Default: node.

.PARAMETER TargetHost
    Remote host (SSH). Omit for local deployment.

.PARAMETER UserName
    SSH user for remote. Default: current user.

.PARAMETER IdentityFile
    SSH key path.

.PARAMETER MeshKey
    Mesh PSK for joining an existing AitherMesh.

.PARAMETER ControllerUrl
    URL of the controller node (Elysium). E.g., http://10.0.1.50:8001

.PARAMETER Port
    Port for the node API. Default: 8080.

.PARAMETER OllamaUrl
    Ollama endpoint. Default: http://localhost:11434.

.PARAMETER Identity
    Agent identity to load. Default: genesis.

.EXAMPLE
    # Install ADK locally
    .\3061_Deploy-LightweightNode.ps1 -Target adk

    # Deploy AitherNode Docker container locally
    .\3061_Deploy-LightweightNode.ps1 -Target node -MeshKey "abc123..."

    # Deploy EdgeNodeService to a remote Raspberry Pi
    .\3061_Deploy-LightweightNode.ps1 -Target edge -TargetHost pi.local -UserName pi

.NOTES
    Category: deploy
    Dependencies: Python 3.10+ (adk/edge), Docker (node)
    Platform: Windows, Linux, macOS
    Tags: lightweight, adk, node, edge, mesh
#>

[CmdletBinding()]
param(
    [ValidateSet("adk", "node", "edge")]
    [string]$Target = "node",

    [string]$TargetHost,

    [string]$UserName = $env:USER ?? $env:USERNAME,

    [string]$IdentityFile,

    [string]$MeshKey,

    [string]$ControllerUrl,

    [int]$Port = 8080,

    [string]$OllamaUrl = "http://localhost:11434",

    [string]$Identity = "genesis",

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent

if (Test-Path "$scriptDir/_init.ps1") { . "$scriptDir/_init.ps1" }

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  AitherOS Lightweight Node Deployment" -ForegroundColor Cyan
Write-Host "  Target: $Target | Port: $Port" -ForegroundColor DarkCyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# OPTION 1: ADK (pip install)
# ═══════════════════════════════════════════════════════════════════════════════

if ($Target -eq "adk") {
    Write-Host "Installing AitherADK..." -ForegroundColor Yellow

    if ($DryRun) {
        Write-Host "  [DRY-RUN] pip install aither-adk" -ForegroundColor DarkGray
    } else {
        & pip install aither-adk
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install aither-adk"
            exit 1
        }
    }

    Write-Host ""
    Write-Host "  AitherADK installed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Quick start:" -ForegroundColor Cyan
    Write-Host "    aither init my-agent" -ForegroundColor DarkGray
    Write-Host "    adk-serve --identity $Identity --port $Port" -ForegroundColor DarkGray
    Write-Host "    adk-serve --agents aither,lyra,demiurge,hydra --port $Port" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# OPTION 2: NODE (Docker container)
# ═══════════════════════════════════════════════════════════════════════════════

if ($Target -eq "node") {
    Write-Host "Deploying AitherNode container..." -ForegroundColor Yellow

    $composeFile = Join-Path $workspaceRoot "AitherOS/apps/AitherNode/docker/docker-compose.node.yml"
    if (-not (Test-Path $composeFile)) {
        Write-Error "AitherNode compose file not found: $composeFile"
        exit 1
    }

    $env:AITHER_NODE_PORT = $Port
    if ($MeshKey)       { $env:AITHER_MESH_KEY = $MeshKey }
    if ($ControllerUrl) { $env:AITHER_CONTROLLER_URL = $ControllerUrl }
    $env:OLLAMA_HOST = $OllamaUrl

    if ($DryRun) {
        Write-Host "  [DRY-RUN] docker compose -f $composeFile up -d" -ForegroundColor DarkGray
    } else {
        & docker compose -f $composeFile up -d
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to start AitherNode container"
            exit 1
        }
    }

    Write-Host ""
    Write-Host "  AitherNode running!" -ForegroundColor Green
    Write-Host "  Health: http://localhost:${Port}/health" -ForegroundColor Cyan
    Write-Host "  Discovery: http://localhost:${Port}/.well-known/aitheros" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# OPTION 3: EDGE (standalone Python)
# ═══════════════════════════════════════════════════════════════════════════════

if ($Target -eq "edge") {
    Write-Host "Deploying EdgeNodeService (standalone)..." -ForegroundColor Yellow

    $edgeScript = Join-Path $workspaceRoot "AitherOS/lib/core/EdgeNodeService.py"
    if (-not (Test-Path $edgeScript)) {
        Write-Error "EdgeNodeService not found: $edgeScript"
        exit 1
    }

    $env:AITHER_STANDALONE = "1"
    $env:OLLAMA_HOST = $OllamaUrl

    if ($TargetHost) {
        # Remote deployment via SSH
        $sshOpts = @("-o", "StrictHostKeyChecking=no")
        if ($IdentityFile) { $sshOpts += @("-i", $IdentityFile) }

        Write-Host "  Copying files to $UserName@$TargetHost..." -ForegroundColor DarkCyan

        # Copy minimum required files
        $remotePath = "/home/$UserName/aither-edge"
        & ssh @sshOpts "$UserName@$TargetHost" "mkdir -p $remotePath"

        if (Get-Command rsync -ErrorAction SilentlyContinue) {
            & rsync -avz --include='lib/***' --include='config/***' --include='services/_bootstrap.py' --exclude='*' `
                "$workspaceRoot/AitherOS/" "${UserName}@${TargetHost}:${remotePath}/"
        } else {
            & scp @sshOpts -r "$workspaceRoot/AitherOS/lib" "${UserName}@${TargetHost}:${remotePath}/"
            & scp @sshOpts -r "$workspaceRoot/AitherOS/config" "${UserName}@${TargetHost}:${remotePath}/"
        }

        Write-Host "  Starting EdgeNodeService on remote..." -ForegroundColor DarkCyan
        & ssh @sshOpts "$UserName@$TargetHost" @"
cd $remotePath
export AITHER_STANDALONE=1
export OLLAMA_HOST=$OllamaUrl
nohup python3 -m lib.core.EdgeNodeService --identity $Identity --port $Port > /tmp/aither-edge.log 2>&1 &
echo "EdgeNodeService started (PID: `$!)"
"@
    } else {
        # Local deployment
        if ($DryRun) {
            Write-Host "  [DRY-RUN] python -m lib.core.EdgeNodeService --identity $Identity --port $Port" -ForegroundColor DarkGray
        } else {
            Push-Location "$workspaceRoot/AitherOS"
            & python -m lib.core.EdgeNodeService --identity $Identity --port $Port
            Pop-Location
        }
    }

    Write-Host ""
    Write-Host "  EdgeNodeService deployed!" -ForegroundColor Green
    Write-Host "  Health: http://localhost:${Port}/health" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}
