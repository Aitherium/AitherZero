#Requires -Version 7.0
<#
.SYNOPSIS
    Guided setup for AitherOS environment (Secrets, Hardware, API Keys)
.DESCRIPTION
    Interactively configures the AitherOS environment by:
    1. Generating a unique Master Key
    2. Detecting hardware capabilities
    3. Collecting API keys for external services
    4. Writing configuration to .env file
.PARAMETER Interactive
    Run in interactive mode (default: true)
.PARAMETER Force
    Overwrite existing configuration
#>

[CmdletBinding()]
param(
    [switch]$Interactive = $true,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$RepoRoot = "$ScriptDir\..\..\..\.."  # Back to root
$EnvFile = "$RepoRoot\.env"

# Colors
$HeaderColor = "Cyan"
$InfoColor = "White"
$SuccessColor = "Green"
$WarningColor = "Yellow"
$ErrorColor = "Red"

function Write-Header {
    param([string]$Title)
    Write-Host "`n============================================================" -ForegroundColor $HeaderColor
    Write-Host "   $Title" -ForegroundColor $InfoColor
    Write-Host "============================================================" -ForegroundColor $HeaderColor
}

function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor "Gray" }
function Write-Success { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor $SuccessColor }
function Write-Warning { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor $WarningColor }

function Get-UserInput {
    param(
        [string]$Prompt,
        [bool]$IsSecret = $false,
        [string]$DefaultValue = ""
    )
    if (-not $Interactive) { return $DefaultValue }

    $msg = "$Prompt"
    if ($DefaultValue) { $msg += " [$DefaultValue]" }
    $msg += ": "
    
    if ($IsSecret) {
        # Secure string handling for secrets (masked input)
        Write-Host -NoNewline $msg
        $input = Read-Host -AsSecureString
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($input))
    } else {
        $plain = Read-Host -Prompt $msg
    }

    if (-not $plain -and $DefaultValue) { return $DefaultValue }
    return $plain
}

function Set-EnvVar {
    param(
        [string]$Name,
        [string]$Value
    )
    if (-not $Value) { return }

    # Read existing content
    if (Test-Path $EnvFile) {
        $content = Get-Content $EnvFile -Raw
    } else {
        $content = ""
    }

    # Check if exists
    if ($content -match "(?m)^$Name=") {
        # Update existing
        $content = $content -replace "(?m)^$Name=.*", "$Name=$Value"
    } else {
        # Append new
        $content += "`n$Name=$Value"
    }
    
    $content | Set-Content $EnvFile -Encoding UTF8 -NoNewline
    Write-Success "Configured $Name"
}

# ============================================================================
# 1. WELCOME
# ============================================================================
Write-Header "AitherOS Guided Environment Setup"
Write-Info "This wizard will help you set up your environment configuration."
Write-Info "Configuration will be saved to: $EnvFile"

if (-not (Test-Path $EnvFile)) {
    New-Item -ItemType File -Path $EnvFile -Force | Out-Null
    Write-Info "Created new .env file."
} elseif ($Force) {
    Write-Warning "Existing .env file will be updated."
}

# ============================================================================
# 2. MASTER KEY GENERATION
# ============================================================================
Write-Header "Security Configuration"

$currentKey = Select-String -Path $EnvFile -Pattern "^AITHER_MASTER_KEY=" -SimpleMatch -quiet
if (-not $currentKey -or $Force) {
    Write-Info "Generating unique Aither Master Key (AES-256)..."
    # Generate 32 bytes of entropy encoded as hex
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $key = ("{0:x2}" -f $bytes -join "").Replace(" ", "")
    Set-EnvVar "AITHER_MASTER_KEY" $key
    Write-Success "Master Key generated and saved."
} else {
    Write-Info "Master Key already configured. Skipping generation."
}

# ============================================================================
# 3. HARDWARE DETECTION
# ============================================================================
Write-Header "Hardware Profile"
Write-Info "Detecting host hardware to optimize Docker resource limits..."

$detectScript = "$RepoRoot\scripts\detect-host-hardware.ps1"
if (Test-Path $detectScript) {
    pwsh -File $detectScript
    Write-Success "Hardware profile updated in .env"
} else {
    Write-Warning "Hardware detection script not found at $detectScript. Skipping."
}

# ============================================================================
# 4. API KEYS & SECRETS
# ============================================================================
Write-Header "External Integrations"
Write-Info "Enter your API keys for external services. Press Enter to skip any you don't use."

$secrets = @(
    @{ Name="GITHUB_TOKEN"; Prompt="GitHub Token (for private repos/backup)"; Secret=$true },
    @{ Name="GITHUB_ORG_TOKEN"; Prompt="GitHub Org Token (if different)"; Secret=$true },
    @{ Name="OPENAI_API_KEY"; Prompt="OpenAI API Key (GPT-4)"; Secret=$true },
    @{ Name="ANTHROPIC_API_KEY"; Prompt="Anthropic API Key (Claude)"; Secret=$true },
    @{ Name="REPLICATE_API_TOKEN"; Prompt="Replicate Token (Image Gen)"; Secret=$true },
    @{ Name="TWILIO_ACCOUNT_SID"; Prompt="Twilio SID (SMS)"; Secret=$false },
    @{ Name="TWILIO_AUTH_TOKEN"; Prompt="Twilio Auth Token"; Secret=$true },
    @{ Name="HUGGINGFACE_TOKEN"; Prompt="HuggingFace Token (Model Downloads)"; Secret=$true },
     @{ Name="STRIPE_SECRET_KEY"; Prompt="Stripe Secret Key (Billing)"; Secret=$true },
    @{ Name="PATREON_CLIENT_ID"; Prompt="Patreon Client ID"; Secret=$false },
    @{ Name="PATREON_CLIENT_SECRET"; Prompt="Patreon Client Secret"; Secret=$true }
)

foreach ($s in $secrets) {
    # Check if already set
    $exists = Select-String -Path $EnvFile -Pattern "^$($s.Name)=" -SimpleMatch -quiet
    if ($exists -and -not $Force) {
        Write-Info "$($s.Name) is already configured."
        continue
    }

    $val = Get-UserInput -Prompt $s.Prompt -IsSecret $s.Secret
    if ($val) {
        Set-EnvVar $s.Name $val
    }
}

# ============================================================================
# 5. CONFIGURATION
# ============================================================================
Write-Header "System Configuration"
$tzDefault = if ([System.TimeZoneInfo]::Local.Id) { [System.TimeZoneInfo]::Local.Id } else { "America/Los_Angeles" }
$tz = Get-UserInput -Prompt "System Timezone" -DefaultValue $tzDefault
Set-EnvVar "AITHER_TIMEZONE" $tz

$mode = Get-UserInput -Prompt "Inference Mode (hybrid/cloud-only/local-only)" -DefaultValue "hybrid"
Set-EnvVar "AITHER_INFERENCE_MODE" $mode

Write-Success "Configuration complete!"
