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
#>

[CmdletBinding()]
param(
    [string]$OutputFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# ROBUST PATH RESOLUTION - Works from _archive or active tree
# ============================================================================

function Find-AitherZeroRoot {
    # Strategy 1: Check AITHERZERO_ROOT env var
    if ($env:AITHERZERO_ROOT -and (Test-Path (Join-Path $env:AITHERZERO_ROOT "AitherZero\AitherZero.psd1"))) {
        return (Join-Path $env:AITHERZERO_ROOT "AitherZero")
    }

    # Strategy 2: Walk up from script location looking for AitherZero.psd1
    $searchPath = $PSScriptRoot
    for ($i = 0; $i -lt 10; $i++) {
        $candidate = Join-Path $searchPath "AitherZero.psd1"
        if (Test-Path $candidate) {
            return $searchPath
        }
        $searchPath = Split-Path -Parent $searchPath
        if (-not $searchPath) { break }
    }

    # Strategy 3: Walk up looking for AitherZero subdirectory with manifest
    $searchPath = $PSScriptRoot
    for ($i = 0; $i -lt 10; $i++) {
        $candidate = Join-Path $searchPath "AitherZero\AitherZero.psd1"
        if (Test-Path $candidate) {
            return (Join-Path $searchPath "AitherZero")
        }
        $searchPath = Split-Path -Parent $searchPath
        if (-not $searchPath) { break }
    }

    throw "Could not locate AitherZero module root. Ensure AitherZero.psd1 exists."
}

$moduleRoot = Find-AitherZeroRoot
$configDir = Join-Path $moduleRoot "config"
$repoRoot = Split-Path -Parent $moduleRoot
$aitherOSRoot = Join-Path $repoRoot "AitherOS"

if (-not $OutputFile) {
    $OutputFile = Join-Path $aitherOSRoot "config\aitheros.env"
}

Write-Host "Syncing AitherZero config to AitherOS environment..." -ForegroundColor Cyan
Write-Host "  Module root: $moduleRoot" -ForegroundColor Gray
Write-Host "  Config dir:  $configDir" -ForegroundColor Gray

# Load configurations
$configPath = Join-Path $configDir "config.psd1"
$localConfigPath = Join-Path $configDir "config.local.psd1"

if (-not (Test-Path $configPath)) {
    Write-Error "Config file not found: $configPath"
    return
}

$config = Invoke-Expression (Get-Content -Path $configPath -Raw)

# Merge local overrides if exists
if (Test-Path $localConfigPath) {
    $localConfig = Invoke-Expression (Get-Content -Path $localConfigPath -Raw)
    Write-Host "  Loaded local config overrides" -ForegroundColor Green
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
$envVars["AITHERZERO_ROOT"] = $repoRoot
$envVars["AITHEROS_ROOT"] = $aitherOSRoot

if ($config.Paths) {
    $paths = $config.Paths
    if ($paths.Data.Backups) { $envVars["AITHER_BACKUP_DIR"] = $paths.Data.Backups }
    if ($paths.Data.Logs) { $envVars["AITHEROS_LOGS"] = $paths.Data.Logs }
    if ($paths.Data.Models) { $envVars["HF_HOME"] = $paths.Data.Models }
    if ($paths.Data.Cache) { $envVars["AITHER_CACHE_DIR"] = $paths.Data.Cache }
    if ($paths.Applications.Ollama.ModelsPath) { $envVars["OLLAMA_MODELS"] = $paths.Applications.Ollama.ModelsPath }
    if ($paths.Applications.ComfyUI.ModelsPath) { $envVars["COMFYUI_MODELS_DIR"] = $paths.Applications.ComfyUI.ModelsPath }
    if ($paths.PackageManagers.Npm) { $envVars["NPM_CONFIG_CACHE"] = $paths.PackageManagers.Npm }
    if ($paths.PackageManagers.Pip) { $envVars["PIP_CACHE_DIR"] = $paths.PackageManagers.Pip }
}

if ($config.Features.AitherOS.Genesis) {
    $genesis = $config.Features.AitherOS.Genesis
    if ($genesis.Port) { $envVars["GENESIS_PORT"] = $genesis.Port }
    if ($genesis.BootProfile) { $envVars["GENESIS_BOOT_PROFILE"] = $genesis.BootProfile }
}

if ($config.Features.AI.Ollama) {
    $ollama = $config.Features.AI.Ollama
    if ($ollama.Host -and $ollama.Port) {
        $envVars["OLLAMA_HOST"] = "$($ollama.Host):$($ollama.Port)"
    }
}

$envVars["AITHERNODE_PORT"] = "8080"
$envVars["AITHERVEIL_PORT"] = "3000"
$envVars["PYTHONIOENCODING"] = "utf-8"
$envVars["AITHERNODE_LAZY_LOAD"] = "1"

# Write file
$outputDir = Split-Path -Parent $OutputFile
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$content = "# AITHEROS ENVIRONMENT - Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
foreach ($key in $envVars.Keys) {
    $content += "$key=$($envVars[$key])`n"
}
$content | Set-Content -Path $OutputFile -Encoding UTF8 -Force

Write-Host "Synced $($envVars.Count) environment variables to: $OutputFile" -ForegroundColor Green

foreach ($key in $envVars.Keys) {
    [Environment]::SetEnvironmentVariable($key, $envVars[$key], 'Process')
}
Write-Host "Applied to current PowerShell session" -ForegroundColor Green

return @{ Success = $true; OutputFile = $OutputFile; VariableCount = $envVars.Count }
