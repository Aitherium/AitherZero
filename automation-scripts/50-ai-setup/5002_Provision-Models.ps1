#Requires -Version 7.0
<#
.SYNOPSIS
    Provision AI models for the vLLM multi-model stack.

.DESCRIPTION
    Cross-platform script that ensures all required models are downloaded
    and cached in the Docker volumes used by the vLLM workers.

    This script delegates to 3022_Provision-Models.ps1 for the actual
    model provisioning logic, but provides a clean entry point from the
    50-ai-setup category and playbook FeatureDependencies.

    Models provisioned:
      - cerebras/GLM-4.7-Flash-REAP-23B-A3B    (Orchestrator)
      - cerebras/Qwen3-Coder-REAP-25B-A3B      (Reasoning)
      - Qwen/Qwen2.5-VL-7B-Instruct            (Vision)
      - deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct  (Coding)

.PARAMETER Profile
    Model provisioning profile: minimal, core, full. Default: core.

.PARAMETER Force
    Force re-download of already cached models.

.PARAMETER NonInteractive
    Run without prompts (for CI/automation).

.PARAMETER ShowOutput
    Display verbose output.

.EXAMPLE
    .\5002_Provision-Models.ps1
    # Provisions models for the core profile

.EXAMPLE
    .\5002_Provision-Models.ps1 -Profile full -Force
    # Force re-downloads all models

.NOTES
    Category: ai-setup
    Dependencies: Docker, 3022_Provision-Models.ps1
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [ValidateSet("minimal", "core", "full", "qwen")]
    [string]$Profile = "core",

    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Continue'

# ============================================================================
# PLATFORM DETECTION
# ============================================================================

$platform = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'Windows' }
             elseif ($IsLinux) { 'Linux' }
             elseif ($IsMacOS) { 'macOS' }
             else { 'Unknown' }

Write-Host "[Model Provisioning] Platform: $platform | Profile: $Profile" -ForegroundColor Cyan

# ============================================================================
# LOCATE DELEGATE SCRIPT
# ============================================================================

$scriptDir = $PSScriptRoot
$automationRoot = Split-Path $scriptDir -Parent
$delegateScript = Join-Path $automationRoot "30-deploy" "3022_Provision-Models.ps1"

if (-not (Test-Path $delegateScript)) {
    Write-Host "[ERROR] Delegate script not found: $delegateScript" -ForegroundColor Red
    Write-Host "  Expected at: 30-deploy/3022_Provision-Models.ps1" -ForegroundColor Gray
    exit 1
}

# ============================================================================
# DELEGATE TO 3022
# ============================================================================

Write-Host "[Model Provisioning] Delegating to 3022_Provision-Models.ps1..." -ForegroundColor Yellow

$delegateProfile = if ($Profile -eq 'qwen') { 'core' } else { $Profile }

$params = @{
    Profile = $delegateProfile
}
if ($Force) { $params['Force'] = $true }
if ($NonInteractive) { $params['NonInteractive'] = $true }
if ($ShowOutput) { $params['ShowOutput'] = $true }

& $delegateScript @params

$exitCode = $LASTEXITCODE

# ============================================================================
# QWEN 3.5 35B PROVISIONING
# ============================================================================
if ($Profile -in @('full', 'qwen')) {
    Write-Host "`n[Model Provisioning] Setting up Qwen 3.5 35B (vLLM)..." -ForegroundColor Cyan
    
    $qwenScript = Join-Path $scriptDir "5003_Setup-Qwen35-35B.ps1"
    
    if (Test-Path $qwenScript) {
        $qwenParams = @{}
        if ($Force) { $qwenParams['Force'] = $true }
        
        & $qwenScript @qwenParams
    } else {
        Write-Warning "[ERROR] Qwen setup script not found: $qwenScript"
    }
}

if ($exitCode -eq 0) {
    Write-Host "[Model Provisioning] All models provisioned successfully" -ForegroundColor Green
} else {
    Write-Host "[Model Provisioning] Provisioning completed with exit code: $exitCode" -ForegroundColor Yellow
}

exit $exitCode
