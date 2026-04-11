<#
.SYNOPSIS
    Sync AitherZero config to AitherOS environment file

.DESCRIPTION
    Reads configuration from AitherZero/config/config.psd1 and config.local.psd1
    and writes it to AitherOS/config/aitheros.env for Python services to consume.
    
    This ensures AitherOS services inherit configuration from AitherZero.

.PARAMETER OutputFile
    Path to output .env file. Defaults to AitherOS/config/aitheros.env

.PARAMETER Force
    Overwrite existing file without prompting

.EXAMPLE
    ./0012_Sync-AitherOSEnv.ps1
    
    Sync configuration to default location

.EXAMPLE
    ./0012_Sync-AitherOSEnv.ps1 -OutputFile "D:\test.env"
    
    Sync to custom location
#>

[CmdletBinding()]
param(
    [string]$OutputFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Get module root
$scriptDir = Split-Path -Parent $PSScriptRoot
$moduleRoot = Split-Path -Parent $scriptDir
$configDir = Join-Path $moduleRoot "config"
$aitherOSRoot = Join-Path (Split-Path -Parent $moduleRoot) "AitherOS"

if (-not $OutputFile) {
    $OutputFile = Join-Path $aitherOSRoot "config\aitheros.env"
}

Write-Host "ðŸ”„ Syncing AitherZero config to AitherOS environment..." -ForegroundColor Cyan

# Load configurations
$configPath = Join-Path $configDir "config.psd1"
$localConfigPath = Join-Path $configDir "config.local.psd1"

if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    return
}

# Use Invoke-Expression to allow dynamic content/variables in config
$config = Invoke-Expression (Get-Content -Path $configPath -Raw)

# Merge local overrides if exists
if (Test-Path $localConfigPath) {
    $localConfig = Invoke-Expression (Get-Content -Path $localConfigPath -Raw)
    Write-Host "  ✔ Loaded local config overrides" -ForegroundColor Green
    
    # Deep merge function
    function Merge-Hashtable {
        param($Base, $Override)
        $result = $Base.Clone()
        foreach ($key in $Override.Keys) {
            if ($result.Contains($key) -and $result[$key] -is [System.Collections.IDictionary] -and $Override[$key] -is [System.Collections.IDictionary]) {
                $result[$key] = Merge-Hashtable -Base $result[$key] -Override $Override[$key]
            } else {
                $result[$key] = $Override[$key]
            }
        }
        return $result
    }
    
    $config = Merge-Hashtable -Base $config -Override $localConfig
}

# Build environment variables
$envVars = [ordered]@{}

# Header
$header = @"
# ═══════════════════════════════════════════════════════════════════════════════
# AITHEROS ENVIRONMENT CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-GENERATED from AitherZero config.psd1 + config.local.psd1
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# ═══════════════════════════════════════════════════════════════════════════════

"@

# Core Paths
$envVars["AITHERZERO_ROOT"] = Split-Path -Parent $moduleRoot
$envVars["AITHEROS_ROOT"] = $aitherOSRoot

# Paths from config
if ($config.Paths) {
    $paths = $config.Paths
    
    if ($paths.Data.Backups) { $envVars["AITHER_BACKUP_DIR"] = $paths.Data.Backups }
    if ($paths.Data.Logs) { $envVars["AITHEROS_LOGS"] = $paths.Data.Logs }
    if ($paths.Data.Models) { $envVars["HF_HOME"] = $paths.Data.Models }
    if ($paths.Data.Cache) { $envVars["AITHER_CACHE_DIR"] = $paths.Data.Cache }
    
    # Application paths
    if ($paths.Applications.Ollama.ModelsPath) { $envVars["OLLAMA_MODELS"] = $paths.Applications.Ollama.ModelsPath }
    if ($paths.Applications.ComfyUI.ModelsPath) { $envVars["COMFYUI_MODELS_DIR"] = $paths.Applications.ComfyUI.ModelsPath }
    if ($paths.Applications.ComfyUI.OutputPath) { $envVars["COMFYUI_OUTPUT_DIR"] = $paths.Applications.ComfyUI.OutputPath }
    
    # Package managers
    if ($paths.PackageManagers.Npm) { $envVars["NPM_CONFIG_CACHE"] = $paths.PackageManagers.Npm }
    if ($paths.PackageManagers.Pip) { $envVars["PIP_CACHE_DIR"] = $paths.PackageManagers.Pip }
}

# Environment variables from config
if ($config.EnvironmentConfiguration.EnvironmentVariables.Applications) {
    foreach ($key in $config.EnvironmentConfiguration.EnvironmentVariables.Applications.Keys) {
        $envVars[$key] = $config.EnvironmentConfiguration.EnvironmentVariables.Applications[$key]
    }
}

# Features - Genesis
if ($config.Features.AitherOS.Genesis) {
    $genesis = $config.Features.AitherOS.Genesis
    if ($genesis.Port) { $envVars["GENESIS_PORT"] = $genesis.Port }
    if ($genesis.BootProfile) { $envVars["GENESIS_BOOT_PROFILE"] = $genesis.BootProfile }
}

# Ollama
if ($config.Features.AI.Ollama) {
    $ollama = $config.Features.AI.Ollama
    if ($ollama.Host -and $ollama.Port) { 
        $envVars["OLLAMA_HOST"] = "$($ollama.Host):$($ollama.Port)"
    }
}

# Service Ports (hardcoded defaults - could be read from services.yaml)
$envVars["AITHERNODE_PORT"] = "8080"
$envVars["AITHERPULSE_PORT"] = "8081"
$envVars["AITHERVEIL_PORT"] = "3000"
$envVars["AITHERA2A_PORT"] = "8119"
$envVars["AITHER_RECOVER_URL"] = "http://localhost:8115"

# Python config
$envVars["PYTHONIOENCODING"] = "utf-8"
$envVars["AITHERNODE_LAZY_LOAD"] = "1"

# SASE Safety
$envVars["SASE_PROTECTED_BRANCHES"] = "main,master,production,release"
$envVars["SASE_REQUIRE_SNAPSHOTS"] = "1"

# Build output content
$content = $header

$sections = @{
    "CORE PATHS" = @("AITHERZERO_ROOT", "AITHEROS_ROOT", "AITHEROS_LOGS", "AITHER_CACHE_DIR")
    "BACKUP & RECOVERY" = @("AITHER_BACKUP_DIR", "AITHER_RECOVER_URL")
    "SERVICE PORTS" = @("GENESIS_PORT", "GENESIS_BOOT_PROFILE", "AITHERNODE_PORT", "AITHERPULSE_PORT", "AITHERVEIL_PORT", "AITHERA2A_PORT")
    "OLLAMA / LLM" = @("OLLAMA_HOST", "OLLAMA_MODELS")
    "GPU / AI PATHS" = @("COMFYUI_MODELS_DIR", "COMFYUI_OUTPUT_DIR", "HF_HOME", "TRANSFORMERS_CACHE")
    "CACHE PATHS" = @("NPM_CONFIG_CACHE", "PIP_CACHE_DIR")
    "PYTHON CONFIGURATION" = @("PYTHONIOENCODING", "AITHERNODE_LAZY_LOAD")
    "SASE / SAFETY" = @("SASE_PROTECTED_BRANCHES", "SASE_REQUIRE_SNAPSHOTS")
}

$written = @{}
foreach ($section in $sections.Keys) {
    $content += "`n# =============================================================================`n"
    $content += "# $section`n"
    $content += "# =============================================================================`n"
    
    foreach ($key in $sections[$section]) {
        if ($envVars.Contains($key)) {
            $content += "$key=$($envVars[$key])`n"
            $written[$key] = $true
        }
    }
}

# Add any remaining vars
$remaining = $envVars.Keys | Where-Object { -not $written.ContainsKey($_) }
if ($remaining) {
    $content += "`n# =============================================================================`n"
    $content += "# OTHER`n"
    $content += "# =============================================================================`n"
    foreach ($key in $remaining) {
        $content += "$key=$($envVars[$key])`n"
    }
}

# Write file
$outputDir = Split-Path -Parent $OutputFile
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$content | Set-Content -Path $OutputFile -Encoding UTF8 -Force

Write-Host "✅ Synced $($envVars.Count) environment variables to: $OutputFile" -ForegroundColor Green

# Also set them in current session
foreach ($key in $envVars.Keys) {
    [Environment]::SetEnvironmentVariable($key, $envVars[$key], 'Process')
}

Write-Host "✅ Applied to current PowerShell session" -ForegroundColor Green

return @{
    Success = $true
    OutputFile = $OutputFile
    VariableCount = $envVars.Count
    Variables = $envVars
}


