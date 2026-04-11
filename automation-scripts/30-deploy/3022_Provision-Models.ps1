#Requires -Version 7.0
<#
.SYNOPSIS
    Auto-provision AI models based on config.psd1 and services.yaml.

.DESCRIPTION
    Downloads, configures, and registers AI models required by AitherOS.
    Reads model requirements from services.yaml and provisions them via
    Ollama or container-bundled inference engines.

    Model tiers:
    - reflex:    Fast, small models for quick responses (1-3B)
    - agent:     General-purpose models for agent tasks (7-8B)
    - reasoning: Deep reasoning models for complex tasks (14B+)
    - coding:    Specialized code generation models
    - embedding: Text embedding models
    - vision:    Multimodal vision models

    Provisioning strategy:
    1. Check what's already installed
    2. Pull missing models in priority order
    3. Create custom Modelfiles (aither-orchestrator-v5)
    4. Register models with running services

.PARAMETER Profile
    Deployment profile controls which models are pulled:
    - "minimal" : Only default model (llama3.2 or configured default)
    - "core"    : Default + reflex + agent models
    - "full"    : All model tiers including reasoning + coding

.PARAMETER NonInteractive
    Suppress prompts.

.PARAMETER Force
    Force re-pull even if model exists.

.PARAMETER ModelOverride
    Override the default model. Example: "mistral-nemo"

.EXAMPLE
    .\3022_Provision-Models.ps1

.EXAMPLE
    .\3022_Provision-Models.ps1 -Profile full -Force

.NOTES
    Category: deploy
    Dependencies: Ollama (optional)
    Platform: Windows, Linux, macOS
    Script: 3022
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("minimal", "core", "full", "headless", "gpu", "agents")]
    [string]$Profile = "core",

    [switch]$NonInteractive,
    [switch]$Force,
    [string]$ModelOverride
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

. "$PSScriptRoot/../_init.ps1"

Write-Host "`n  AI Model Provisioning" -ForegroundColor Cyan
Write-Host "  Profile: $Profile" -ForegroundColor Gray
Write-Host ""

# ── Check Ollama availability ──────────────────────────────────
$ollamaAvailable = $false
if (Get-Command ollama -ErrorAction SilentlyContinue) {
    try {
        $ollamaList = ollama list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ollamaAvailable = $true
        }
    }
    catch { }
}

if (-not $ollamaAvailable) {
    Write-Host "  Ollama not available — checking Docker-based Ollama..." -ForegroundColor Yellow

    # Check for Docker-based Ollama
    try {
        $ollamaContainer = docker ps --filter "name=ollama" --format "{{.Names}}" 2>&1
        if ($ollamaContainer) {
            Write-Host "  Found Docker Ollama container: $ollamaContainer" -ForegroundColor Gray
            # Use docker exec for Ollama commands
            $ollamaAvailable = $true
            $script:useDockerOllama = $true
        }
    }
    catch { }

    if (-not $ollamaAvailable) {
        Write-Host "  ⚠ No Ollama instance found" -ForegroundColor Yellow
        Write-Host "  → AitherOS will use container-bundled inference (OpenAI-compatible API)" -ForegroundColor DarkGray
        Write-Host "  → To enable local models: install Ollama from https://ollama.com" -ForegroundColor DarkGray
        Write-Host ""
        return
    }
}

# ── Read model configuration from services.yaml ────────────────
$servicesYaml = Join-Path $projectRoot "AitherOS" "config" "services.yaml"
$modelConfig = @{}

if (Test-Path $servicesYaml) {
    Write-Host "  Reading model config from services.yaml..." -ForegroundColor Gray
    # Parse YAML for model section (simple extraction)
    $yamlContent = Get-Content $servicesYaml -Raw

    # Extract default model
    if ($yamlContent -match 'default_model:\s*"?([^\s"]+)"?') {
        $modelConfig.Default = $Matches[1]
    }

    # Extract model tiers
    $tiers = @('reflex', 'agent', 'reasoning', 'coding', 'embedding', 'vision')
    foreach ($tier in $tiers) {
        if ($yamlContent -match "${tier}:\s*\n\s*-\s*name:\s*""?([^\s""]+)""?") {
            $modelConfig[$tier] = $Matches[1]
        }
        elseif ($yamlContent -match "${tier}_model:\s*""?([^\s""]+)""?") {
            $modelConfig[$tier] = $Matches[1]
        }
    }
}

# ── Define models per profile ──────────────────────────────────
$defaultModel = if ($ModelOverride) { $ModelOverride }
               elseif ($modelConfig.Default) { $modelConfig.Default }
               else { 'llama3.2' }

$modelsByProfile = @{
    minimal  = @($defaultModel)
    headless = @($defaultModel)
    core     = @($defaultModel) + @(
        if ($modelConfig.reflex) { $modelConfig.reflex }
        if ($modelConfig.agent) { $modelConfig.agent }
    ) | Select-Object -Unique
    gpu      = @($defaultModel) + @(
        if ($modelConfig.agent) { $modelConfig.agent }
        if ($modelConfig.reasoning) { $modelConfig.reasoning }
    ) | Select-Object -Unique
    agents   = @($defaultModel) + @(
        if ($modelConfig.agent) { $modelConfig.agent }
        if ($modelConfig.coding) { $modelConfig.coding }
    ) | Select-Object -Unique
    full     = @($defaultModel) + @(
        if ($modelConfig.reflex) { $modelConfig.reflex }
        if ($modelConfig.agent) { $modelConfig.agent }
        if ($modelConfig.reasoning) { $modelConfig.reasoning }
        if ($modelConfig.coding) { $modelConfig.coding }
        if ($modelConfig.embedding) { $modelConfig.embedding }
    ) | Select-Object -Unique
}

$modelsToInstall = $modelsByProfile[$Profile]
if (-not $modelsToInstall -or $modelsToInstall.Count -eq 0) {
    $modelsToInstall = @($defaultModel)
}

# Filter out empty values
$modelsToInstall = @($modelsToInstall | Where-Object { $_ -and $_.Trim() })

Write-Host "  Models to provision ($Profile profile):" -ForegroundColor Gray
foreach ($m in $modelsToInstall) {
    Write-Host "    • $m" -ForegroundColor White
}
Write-Host ""

# ── Helper: Run Ollama command ─────────────────────────────────
function Invoke-Ollama {
    param([string[]]$Arguments)
    if ($script:useDockerOllama) {
        docker exec ollama ollama @Arguments 2>&1
    }
    else {
        ollama @Arguments 2>&1
    }
}

# ── Get installed models ───────────────────────────────────────
$installedModels = @()
try {
    $listOutput = Invoke-Ollama @('list')
    if ($listOutput) {
        $installedModels = @($listOutput | ForEach-Object {
            if ($_ -match '^(\S+)\s') { $Matches[1] }
        } | Where-Object { $_ -and $_ -ne 'NAME' })
    }
}
catch { }

Write-Host "  Currently installed: $($installedModels.Count) model(s)" -ForegroundColor Gray

# ── Pull missing models ───────────────────────────────────────
$pulled = 0
$skippedModels = 0
$failedModels = 0

foreach ($model in $modelsToInstall) {
    # Check if already installed (match by base name)
    $modelBase = ($model -split ':')[0]
    $isInstalled = $installedModels | Where-Object {
        $_ -eq $model -or $_ -like "$modelBase*"
    }

    if ($isInstalled -and -not $Force) {
        Write-Host "    ✓ $model (already installed)" -ForegroundColor Green
        $skippedModels++
        continue
    }

    Write-Host "    ↓ Pulling $model..." -ForegroundColor Yellow
    try {
        $pullOutput = Invoke-Ollama @('pull', $model)
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    ✓ $model pulled successfully" -ForegroundColor Green
            $pulled++
        }
        else {
            Write-Host "    ⚠ $model pull returned non-zero exit" -ForegroundColor Yellow
            $failedModels++
        }
    }
    catch {
        Write-Host "    ✗ Failed to pull $model : $($_.Exception.Message)" -ForegroundColor Red
        $failedModels++
    }
}

# ── Summary ────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Models: $pulled pulled, $skippedModels skipped, $failedModels failed" -ForegroundColor $(
    if ($failedModels -eq 0) { 'Green' } else { 'Yellow' }
)

if ($pulled -gt 0) {
    Write-Host "  Default model: $defaultModel" -ForegroundColor Cyan
}

Write-Host ""
