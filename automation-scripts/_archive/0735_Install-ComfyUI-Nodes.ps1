#Requires -Version 7.0
<#
.SYNOPSIS
    Installs recommended ComfyUI custom nodes for Wan 2.1 optimization.
.DESCRIPTION
    Installs ComfyUI-MagCache (Speed) and ComfyUI-NAG (Quality/Negative Prompts).
    Checks for Git and ComfyUI installation.
.NOTES
    Stage: AI Tools
    Order: 0735
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Path to ComfyUI root directory")]
    [string]$InstallPath
)

. "$PSScriptRoot/_init.ps1"

# Ensure Feature is Enabled
Ensure-FeatureEnabled -Section "Features" -Key "AI.ComfyUI" -Name "ComfyUI"

$Config = Get-AitherConfigs -ErrorAction SilentlyContinue

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

# 1. Locate ComfyUI
if ([string]::IsNullOrEmpty($InstallPath)) {
    # Try Config first
    if ($Config.Features.AI.ComfyUI.InstallPath) {
        $InstallPath = $Config.Features.AI.ComfyUI.InstallPath
    }
}

if ([string]::IsNullOrEmpty($InstallPath)) {
    $PossiblePaths = @(
        "C:\ComfyUI_windows_portable\ComfyUI",
        "C:\ComfyUI",
        "$env:USERPROFILE\ComfyUI",
        "E:\ComfyUI",
        "D:\ComfyUI"
    )

    foreach ($path in $PossiblePaths) {
        if (Test-Path "$path\custom_nodes") {
            $InstallPath = $path
            break
        }
    }
}

if (-not $InstallPath -or -not (Test-Path "$InstallPath\custom_nodes")) {
    Write-Error "ComfyUI custom_nodes directory not found. Please specify -InstallPath."
}

Write-Log "Found ComfyUI at: $InstallPath" "Cyan"
$CustomNodesPath = Join-Path $InstallPath "custom_nodes"

# 2. Define Nodes to Install
$Nodes = @(
    @{
        Name = "ComfyUI-MagCache"
        Url  = "https://github.com/Zehong-Ma/ComfyUI-MagCache.git"
        Desc = "Speed up Wan 2.1 generation by caching attention (2x faster)"
    },
    @{
        Name = "ComfyUI-NAG"
        Url  = "https://github.com/ChenDarYen/Normalized-Attention-Guidance.git"
        Desc = "Normalized Attention Guidance - Enables negative prompts for Wan"
    },
    @{
        Name = "DLoRAL"
        Url  = "https://github.com/yjsunnn/DLoRAL.git"
        Desc = "DLoRAL - Decoupled Low-Rank Adaptation for Layout-Aware Video Generation"
    }
)

# 3. Install Nodes
foreach ($node in $Nodes) {
    $NodePath = Join-Path $CustomNodesPath $node.Name

    if (Test-Path $NodePath) {
        Write-Log "Updating $($node.Name)..." "Yellow"
        Push-Location $NodePath
        try {
            git pull
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Log "Installing $($node.Name) ($($node.Desc))..." "Green"
        git clone $node.Url $NodePath
    }
}

Write-Log "Installation complete!" "Green"
Write-Log "PLEASE RESTART COMFYUI for changes to take effect." "Magenta"
