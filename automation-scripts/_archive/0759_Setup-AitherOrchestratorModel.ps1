#Requires -Version 7.0

<#
.SYNOPSIS
    Sets up the custom Aither Orchestrator model for AitherOS.

.DESCRIPTION
    Creates the aither-orchestrator-v5 model from the custom Modelfile.
    This model builds on top of nvidia/nemotron-orchestrator-8b with AitherOS-specific:
    - System prompts for context awareness
    - Anti-sycophancy rules
    - Emotional intelligence
    - Memory integration
    - AitherNeurons integration
    
    Prerequisites:
    - Ollama installed and running
    - Base nvidia-orchestrator model (run 0753_Setup-Orchestrator8B.ps1 first)
    
    The script is IDEMPOTENT - safe to run multiple times.

.PARAMETER Force
    Force recreation of the model even if it already exists.

.PARAMETER ModelVersion
    Which version of the Modelfile to use. Default: v4

.PARAMETER BaseModel
    Base model to use. Default: nvidia-orchestrator (falls back to llama3.2:3b if unavailable)

.PARAMETER ShowOutput
    Display detailed progress output.

.EXAMPLE
    ./0754_Setup-AitherOrchestratorModel.ps1
    # Creates aither-orchestrator-8b-v4 if it doesn't exist

.EXAMPLE
    ./0754_Setup-AitherOrchestratorModel.ps1 -Force
    # Recreates the model even if it exists

.EXAMPLE
    ./0754_Setup-AitherOrchestratorModel.ps1 -BaseModel llama3.2:3b
    # Uses llama3.2 as base (for systems without GPU)

.NOTES
    Stage: AI Tools
    Order: 0754
    Dependencies: Ollama, 0753_Setup-Orchestrator8B.ps1 (optional but recommended)
    Tags: aither, orchestrator, llm, ollama, model
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [ValidateSet("v3", "v4", "v5")]
    [string]$ModelVersion = "v5",

    [Parameter()]
    [string]$BaseModel,

    [Parameter()]
    [switch]$ShowOutput,
    
    [Parameter()]
    [switch]$SkipBaseModelCheck,
    
    [Parameter()]
    [switch]$SetDefault = $true,  # Default: yes, set as default model
    
    [Parameter()]
    [switch]$SkipSetDefault       # Skip setting as default (for testing)
)

$ErrorActionPreference = 'Stop'

# Initialize
. "$PSScriptRoot/_init.ps1"

# Configuration - v5 uses simplified name format
$ModelName = if ($ModelVersion -eq "v5") { "aither-orchestrator-v5" } else { "aither-orchestrator-8b-$ModelVersion" }
$ModelDisplayName = "Aither Orchestrator $($ModelVersion.ToUpper())"

# Paths - Robust resolution that works from _archive or active tree
function Find-AitherZeroRoot {
    $current = $PSScriptRoot
    for ($i = 0; $i -lt 10; $i++) {
        $manifestPath = Join-Path $current "AitherZero.psd1"
        if (Test-Path $manifestPath) { return (Split-Path $current -Parent) }
        $aitherzeroDir = Join-Path $current "AitherZero"
        if (Test-Path (Join-Path $aitherzeroDir "AitherZero.psd1")) { return $current }
        $current = Split-Path $current -Parent
        if (-not $current -or $current -eq (Split-Path $current -Parent)) { break }
    }
    return $null
}

$RepoRoot = $env:AITHERZERO_ROOT
if (-not $RepoRoot) { $RepoRoot = Find-AitherZeroRoot }
if (-not $RepoRoot) { Write-Error "Could not find AitherZero repository root"; exit 1 }

# Try multiple Modelfile locations
$ModelfileLocations = @(
    (Join-Path $RepoRoot "AitherOS/modelfiles/aither-orchestrator-$ModelVersion.Modelfile"),
    (Join-Path $RepoRoot "AitherOS/modelfiles/aither-orchestrator-8b-$ModelVersion.Modelfile"),
    (Join-Path $RepoRoot "AitherOS/Library/Models/aither-orchestrator-8b-$ModelVersion.Modelfile")
)
$ModelfilePath = $ModelfileLocations | Where-Object { Test-Path $_ } | Select-Object -First 1
$ModelsDir = Join-Path $RepoRoot "AitherOS/modelfiles"
if (-not (Test-Path $ModelsDir)) { $ModelsDir = Join-Path $RepoRoot "AitherOS/Library/Models" }

# =====================================================================
# Banner
# =====================================================================
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        Aither Orchestrator Model Setup                        ║" -ForegroundColor Cyan
Write-Host "║                                                               ║" -ForegroundColor Cyan
Write-Host "║  Custom AitherOS orchestration model with:                    ║" -ForegroundColor Cyan
Write-Host "║  • Context-aware responses (time, state, memory)              ║" -ForegroundColor Cyan
Write-Host "║  • Anti-sycophancy (corrects misinformation)                  ║" -ForegroundColor Cyan
Write-Host "║  • Emotional intelligence                                     ║" -ForegroundColor Cyan
Write-Host "║  • AitherNeurons integration                                  ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if ($ShowOutput) {
    Write-Host "Configuration:" -ForegroundColor Yellow
    Write-Host "  Model Name:     $ModelName"
    Write-Host "  Model Version:  $ModelVersion"
    Write-Host "  Modelfile:      $ModelfilePath"
    Write-Host ""
}

# =====================================================================
# Step 1: Check Prerequisites
# =====================================================================
Write-Host "[1/5] Checking prerequisites..." -ForegroundColor Cyan

# Check Ollama installed
$ollamaCheck = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaCheck) {
    Write-Error "Ollama is not installed. Run: ./0740_Install-Ollama.ps1"
    exit 1
}

# Check Ollama is running
$ollamaRunning = $false
try {
    $ollamaVersion = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -Method GET -TimeoutSec 5 -ErrorAction Stop
    $ollamaRunning = $true
    if ($ShowOutput) { Write-Host "  ✓ Ollama running (v$($ollamaVersion.version))" -ForegroundColor Green }
} catch {
    Write-Host "  Starting Ollama..." -ForegroundColor Yellow
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
    
    try {
        $ollamaVersion = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -Method GET -TimeoutSec 5 -ErrorAction Stop
        $ollamaRunning = $true
        if ($ShowOutput) { Write-Host "  ✓ Ollama started" -ForegroundColor Green }
    } catch {
        Write-Error "Failed to start Ollama. Run 'ollama serve' manually."
        exit 1
    }
}

# Check Modelfile exists
if (-not (Test-Path $ModelfilePath)) {
    Write-Error "Modelfile not found: $ModelfilePath"
    exit 1
}
if ($ShowOutput) { Write-Host "  ✓ Modelfile found" -ForegroundColor Green }

# =====================================================================
# Step 2: Check if model already exists
# =====================================================================
Write-Host "[2/5] Checking existing models..." -ForegroundColor Cyan

$existingModels = & ollama list 2>&1 | Out-String
$modelExists = $existingModels -match $ModelName

if ($modelExists -and -not $Force) {
    Write-Host ""
    Write-Host "  ✓ Model '$ModelName' already exists!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Use -Force to recreate, or run directly:" -ForegroundColor Yellow
    Write-Host "    ollama run $ModelName" -ForegroundColor White
    Write-Host ""
    exit 0
}

if ($modelExists -and $Force) {
    Write-Host "  Removing existing model (Force specified)..." -ForegroundColor Yellow
    & ollama rm $ModelName 2>$null
}

# =====================================================================
# Step 3: Determine base model
# =====================================================================
Write-Host "[3/5] Determining base model..." -ForegroundColor Cyan

# Read the Modelfile to find the expected base model
$modelfileContent = Get-Content $ModelfilePath -Raw
$fromMatch = [regex]::Match($modelfileContent, '^FROM\s+(.+?)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
$expectedBase = if ($fromMatch.Success) { $fromMatch.Groups[1].Value.Trim() } else { "nvidia-orchestrator:latest" }

# Clean up expected base (remove :latest if present for comparison)
$expectedBaseClean = $expectedBase -replace ':latest$', ''

if ($ShowOutput) { Write-Host "  Modelfile expects: $expectedBase" -ForegroundColor Gray }

# Determine actual base model to use
$actualBase = $expectedBase

if ($BaseModel) {
    # User specified a base model
    $actualBase = $BaseModel
    Write-Host "  Using user-specified base: $actualBase" -ForegroundColor Yellow
} elseif (-not $SkipBaseModelCheck) {
    # Check if expected base model exists
    $hasExpectedBase = $existingModels -match $expectedBaseClean
    
    if (-not $hasExpectedBase) {
        Write-Host "  Base model '$expectedBaseClean' not found in Ollama" -ForegroundColor Yellow
        
        # Check for alternatives (priority order)
        $alternatives = @(
            "nemotron-orchestrator-8b",
            "nvidia-orchestrator",
            "orchestrator-8b",
            "llama3.2:3b",
            "llama3.1:8b",
            "mistral-nemo"
        )
        
        $foundAlt = $null
        foreach ($alt in $alternatives) {
            if ($existingModels -match $alt) {
                $foundAlt = $alt
                break
            }
        }
        
        if ($foundAlt) {
            Write-Host "  Found alternative: $foundAlt" -ForegroundColor Yellow
            $actualBase = $foundAlt
        } else {
            # Need to pull a base model
            Write-Host "  No suitable base model found. Pulling llama3.2:3b..." -ForegroundColor Yellow
            & ollama pull llama3.2:3b
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to pull base model. Run 0753_Setup-Orchestrator8B.ps1 first."
                exit 1
            }
            $actualBase = "llama3.2:3b"
        }
    } else {
        if ($ShowOutput) { Write-Host "  ✓ Base model available: $expectedBaseClean" -ForegroundColor Green }
    }
}

# =====================================================================
# Step 4: Create temporary Modelfile with correct base
# =====================================================================
Write-Host "[4/5] Preparing model configuration..." -ForegroundColor Cyan

$tempModelfile = Join-Path $ModelsDir "Modelfile.aither-temp"

# If base model differs from expected, create modified Modelfile
if ($actualBase -ne $expectedBase) {
    Write-Host "  Adjusting base model: $expectedBase → $actualBase" -ForegroundColor Yellow
    
    $modifiedContent = $modelfileContent -replace "^FROM\s+.+$", "FROM $actualBase"
    Set-Content -Path $tempModelfile -Value $modifiedContent -Encoding UTF8
    $useModelfile = $tempModelfile
} else {
    $useModelfile = $ModelfilePath
}

if ($ShowOutput) { Write-Host "  ✓ Configuration ready" -ForegroundColor Green }

# =====================================================================
# Step 5: Create the model
# =====================================================================
Write-Host "[5/5] Creating Ollama model..." -ForegroundColor Cyan

Push-Location $ModelsDir
try {
    if ($PSCmdlet.ShouldProcess($ModelName, "Create Ollama model")) {
        Write-Host "  Running: ollama create $ModelName -f $(Split-Path $useModelfile -Leaf)" -ForegroundColor Gray
        
        & ollama create $ModelName -f $useModelfile
        
        if ($LASTEXITCODE -ne 0) {
            throw "ollama create failed with exit code $LASTEXITCODE"
        }
    }
} catch {
    Write-Error "Failed to create model: $_"
    exit 1
} finally {
    Pop-Location
    
    # Cleanup temp file
    if (Test-Path $tempModelfile) {
        Remove-Item $tempModelfile -Force
    }
}

# =====================================================================
# Verify model
# =====================================================================
$newModels = & ollama list 2>&1 | Out-String
if (-not ($newModels -match $ModelName)) {
    Write-Error "Model verification failed - model not found in Ollama"
    exit 1
}

Write-Host "  ✓ Model created and verified" -ForegroundColor Green

# =====================================================================
# Step 6: Set as default model for AitherOS components
# =====================================================================
if ($SetDefault -and -not $SkipSetDefault) {
    Write-Host ""
    Write-Host "[6/6] Setting as default model for AitherOS..." -ForegroundColor Cyan
    
    $configsUpdated = @()
    $configsFailed = @()
    
    # ─────────────────────────────────────────────────────────────────
    # 1. Update personas.yaml (Agent default model)
    # ─────────────────────────────────────────────────────────────────
    $personasPath = Join-Path $RepoRoot "AitherOS/config/personas.yaml"
    if (Test-Path $personasPath) {
        try {
            $content = Get-Content $personasPath -Raw
            
            # Update default_model in aither persona
            if ($content -match 'default_model:\s*[^\n]+') {
                $content = $content -replace '(aither:[\s\S]*?default_model:\s*)[^\n]+', "`$1$ModelName"
            }
            
            # Update orchestrator model references
            $content = $content -replace 'model:\s*(nvidia-orchestrator|orchestrator-8b|llama3\.2)[^\n]*', "model: $ModelName"
            
            Set-Content -Path $personasPath -Value $content -Encoding UTF8 -NoNewline
            $configsUpdated += "personas.yaml"
            if ($ShowOutput) { Write-Host "  ✓ Updated: personas.yaml" -ForegroundColor Green }
        } catch {
            $configsFailed += "personas.yaml: $_"
            if ($ShowOutput) { Write-Host "  ✗ Failed: personas.yaml - $_" -ForegroundColor Red }
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 2. Update identity.yaml (Aither's core identity)
    # ─────────────────────────────────────────────────────────────────
    $identityPath = Join-Path $RepoRoot "AitherOS/config/identity.yaml"
    if (Test-Path $identityPath) {
        try {
            $content = Get-Content $identityPath -Raw
            
            # Update model references
            $content = $content -replace 'default_model:\s*[^\n]+', "default_model: $ModelName"
            $content = $content -replace 'orchestrator_model:\s*[^\n]+', "orchestrator_model: $ModelName"
            
            Set-Content -Path $identityPath -Value $content -Encoding UTF8 -NoNewline
            $configsUpdated += "identity.yaml"
            if ($ShowOutput) { Write-Host "  ✓ Updated: identity.yaml" -ForegroundColor Green }
        } catch {
            $configsFailed += "identity.yaml: $_"
            if ($ShowOutput) { Write-Host "  ✗ Failed: identity.yaml - $_" -ForegroundColor Red }
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 3. Update AitherCouncil .env (if exists)
    # ─────────────────────────────────────────────────────────────────
    $councilEnvPath = Join-Path $RepoRoot "AitherOS/AitherNode/.env"
    if (Test-Path $councilEnvPath) {
        try {
            $content = Get-Content $councilEnvPath -Raw
            
            # Update or add AITHER_MODEL
            if ($content -match 'AITHER_MODEL=') {
                $content = $content -replace 'AITHER_MODEL=[^\n]*', "AITHER_MODEL=$ModelName"
            } else {
                $content += "`nAITHER_MODEL=$ModelName"
            }
            
            # Update or add ORCHESTRATOR_MODEL
            if ($content -match 'ORCHESTRATOR_MODEL=') {
                $content = $content -replace 'ORCHESTRATOR_MODEL=[^\n]*', "ORCHESTRATOR_MODEL=$ModelName"
            } else {
                $content += "`nORCHESTRATOR_MODEL=$ModelName"
            }
            
            # Update or add DEFAULT_LLM_MODEL
            if ($content -match 'DEFAULT_LLM_MODEL=') {
                $content = $content -replace 'DEFAULT_LLM_MODEL=[^\n]*', "DEFAULT_LLM_MODEL=$ModelName"
            } else {
                $content += "`nDEFAULT_LLM_MODEL=$ModelName"
            }
            
            Set-Content -Path $councilEnvPath -Value $content.Trim() -Encoding UTF8
            $configsUpdated += "AitherNode/.env"
            if ($ShowOutput) { Write-Host "  ✓ Updated: AitherNode/.env" -ForegroundColor Green }
        } catch {
            $configsFailed += "AitherNode/.env: $_"
            if ($ShowOutput) { Write-Host "  ✗ Failed: AitherNode/.env - $_" -ForegroundColor Red }
        }
    } else {
        # Create .env if it doesn't exist
        try {
            $envContent = @"
# AitherOS Model Configuration
# Auto-generated by 0754_Setup-AitherOrchestratorModel.ps1

# Default orchestration model
AITHER_MODEL=$ModelName
ORCHESTRATOR_MODEL=$ModelName
DEFAULT_LLM_MODEL=$ModelName

# Ollama settings
OLLAMA_HOST=http://localhost:11434
OLLAMA_KEEP_ALIVE=5m
"@
            Set-Content -Path $councilEnvPath -Value $envContent -Encoding UTF8
            $configsUpdated += "AitherNode/.env (created)"
            if ($ShowOutput) { Write-Host "  ✓ Created: AitherNode/.env" -ForegroundColor Green }
        } catch {
            $configsFailed += "AitherNode/.env (create): $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 4. Update NarrativeAgent .env (if exists)
    # ─────────────────────────────────────────────────────────────────
    $narrativeEnvPath = Join-Path $RepoRoot "AitherOS/agents/NarrativeAgent/.env"
    if (Test-Path $narrativeEnvPath) {
        try {
            $content = Get-Content $narrativeEnvPath -Raw
            
            # Update LOCAL_MODEL_NAME
            if ($content -match 'LOCAL_MODEL_NAME=') {
                $content = $content -replace 'LOCAL_MODEL_NAME=[^\n]*', "LOCAL_MODEL_NAME=$ModelName"
            } else {
                $content += "`nLOCAL_MODEL_NAME=$ModelName"
            }
            
            Set-Content -Path $narrativeEnvPath -Value $content.Trim() -Encoding UTF8
            $configsUpdated += "NarrativeAgent/.env"
            if ($ShowOutput) { Write-Host "  ✓ Updated: NarrativeAgent/.env" -ForegroundColor Green }
        } catch {
            $configsFailed += "NarrativeAgent/.env: $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 5. Update aither.yaml (Aither's Will)
    # ─────────────────────────────────────────────────────────────────
    $aitherWillPath = Join-Path $RepoRoot "AitherOS/AitherNode/services/cognition/wills/aither.yaml"
    if (Test-Path $aitherWillPath) {
        try {
            $content = Get-Content $aitherWillPath -Raw
            
            # Update model references
            $content = $content -replace 'model:\s*(nvidia-orchestrator|orchestrator-8b|llama3\.2)[^\n]*', "model: $ModelName"
            $content = $content -replace 'default_model:\s*[^\n]+', "default_model: $ModelName"
            
            Set-Content -Path $aitherWillPath -Value $content -Encoding UTF8 -NoNewline
            $configsUpdated += "wills/aither.yaml"
            if ($ShowOutput) { Write-Host "  ✓ Updated: wills/aither.yaml" -ForegroundColor Green }
        } catch {
            $configsFailed += "wills/aither.yaml: $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 6. Update orchestrator.yaml (Orchestrator Will)
    # ─────────────────────────────────────────────────────────────────
    $orchestratorWillPath = Join-Path $RepoRoot "AitherOS/AitherNode/services/cognition/wills/orchestrator.yaml"
    if (Test-Path $orchestratorWillPath) {
        try {
            $content = Get-Content $orchestratorWillPath -Raw
            
            # Update model references
            $content = $content -replace 'model:\s*(nvidia-orchestrator|orchestrator-8b|llama3\.2)[^\n]*', "model: $ModelName"
            
            Set-Content -Path $orchestratorWillPath -Value $content -Encoding UTF8 -NoNewline
            $configsUpdated += "wills/orchestrator.yaml"
            if ($ShowOutput) { Write-Host "  ✓ Updated: wills/orchestrator.yaml" -ForegroundColor Green }
        } catch {
            $configsFailed += "wills/orchestrator.yaml: $_"
        }
    }
    
    # ─────────────────────────────────────────────────────────────────
    # 7. Update AitherZero config.psd1 (if writable)
    # ─────────────────────────────────────────────────────────────────
    $configPsd1Path = Join-Path $RepoRoot "AitherZero/config/config.psd1"
    if (Test-Path $configPsd1Path) {
        try {
            $content = Get-Content $configPsd1Path -Raw
            
            # Update DefaultModel in Agents.LLM section
            $content = $content -replace "(Agents[\s\S]*?LLM[\s\S]*?DefaultModel\s*=\s*)'[^']*'", "`$1'$ModelName'"
            
            # Update default model in Features.AI.Ollama
            $content = $content -replace "(Features[\s\S]*?AI[\s\S]*?Ollama[\s\S]*?DefaultModel\s*=\s*)'[^']*'", "`$1'$ModelName'"
            
            Set-Content -Path $configPsd1Path -Value $content -Encoding UTF8 -NoNewline
            $configsUpdated += "config.psd1"
            if ($ShowOutput) { Write-Host "  ✓ Updated: config.psd1" -ForegroundColor Green }
        } catch {
            $configsFailed += "config.psd1: $_"
        }
    }
    
    # Summary
    Write-Host ""
    if ($configsUpdated.Count -gt 0) {
        Write-Host "  Updated $($configsUpdated.Count) configuration(s):" -ForegroundColor Green
        foreach ($cfg in $configsUpdated) {
            Write-Host "    • $cfg" -ForegroundColor Gray
        }
    }
    
    if ($configsFailed.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failed to update $($configsFailed.Count) configuration(s):" -ForegroundColor Yellow
        foreach ($cfg in $configsFailed) {
            Write-Host "    • $cfg" -ForegroundColor Gray
        }
    }
}

# =====================================================================
# Success Summary
# =====================================================================
Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                      Setup Complete!                          ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Model:      $ModelName" -ForegroundColor White
Write-Host "  Base:       $actualBase" -ForegroundColor White
Write-Host "  Version:    $ModelVersion" -ForegroundColor White
if ($SetDefault -and -not $SkipSetDefault) {
    Write-Host "  Default:    YES (for all AitherOS components)" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Usage:" -ForegroundColor Cyan
Write-Host "    ollama run $ModelName" -ForegroundColor White
Write-Host ""
Write-Host "  AitherOS components now using this model:" -ForegroundColor Cyan
Write-Host "    • Aither (Prime Agent)" -ForegroundColor White
Write-Host "    • AitherCouncil (Multi-Agent Chat)" -ForegroundColor White
Write-Host "    • Demiurge (Agent Orchestration)" -ForegroundColor White
Write-Host "    • NarrativeAgent (Storytelling)" -ForegroundColor White
Write-Host ""

exit 0

