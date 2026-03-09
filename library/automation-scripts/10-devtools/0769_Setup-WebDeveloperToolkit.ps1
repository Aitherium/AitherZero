#Requires -Version 7.0
# Stage: AI Tools
# Dependencies: 0761 (AitherNode), 0720 (AitherOS Venv)
# Description: Sets up Aither's Web Developer Toolkit (Neocities, Cloudflare Tunnel)
# Tags: ai, web, neocities, tunnel, deployment

<#
.SYNOPSIS
    Sets up Aither's Web Developer Toolkit for creating and deploying websites.

.DESCRIPTION
    This script configures the web development tools that allow Aither to:
    - Deploy static websites to Neocities
    - Expose local APIs via Cloudflare Tunnel
    - Use the neocities-starter template
    
    Components:
    - AitherTunnel: Cloudflare Tunnel integration (lib/network/)
    - mcp_neocities: Neocities deployment tools (AitherNode/tools/mcp/)
    - neocities-starter: HTML/CSS/JS template (templates/web/)
    - web-developer skill: Documentation and examples (skills/)
    
    Exit Codes:
    0   - Success
    1   - Configuration error
    2   - Missing dependencies

.PARAMETER InstallCloudflared
    Install cloudflared binary if not present. Default: $true

.PARAMETER SetupNeocitiesConfig
    Create neocities.yaml config template. Default: $true

.PARAMETER ApiKey
    Neocities API key to configure (optional, can be set later)

.PARAMETER SiteName
    Neocities site name (optional, can be set later)

.PARAMETER Force
    Overwrite existing configuration files. Default: $false

.PARAMETER SkipCloudflared
    Skip cloudflared installation check

.EXAMPLE
    ./0769_Setup-WebDeveloperToolkit.ps1
    Sets up all web developer tools with default settings.

.EXAMPLE
    ./0769_Setup-WebDeveloperToolkit.ps1 -ApiKey "your-key" -SiteName "aither"
    Sets up tools with Neocities credentials pre-configured.

.EXAMPLE
    ./0769_Setup-WebDeveloperToolkit.ps1 -SkipCloudflared
    Sets up tools without installing cloudflared.

.NOTES
    Author: AitherZero
    Stage: AI Tools
    Order: 0769
    Dependencies: 0761, 0720
    Tags: ai, web, neocities, deployment
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$InstallCloudflared = $true,
    [switch]$SetupNeocitiesConfig = $true,
    [string]$ApiKey = "",
    [string]$SiteName = "",
    [switch]$Force,
    [switch]$SkipCloudflared
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Initialize script context
. "$PSScriptRoot/../_init.ps1"

# ============================================================================
# CONFIGURATION
# ============================================================================

$aitherOSRoot = Join-Path $projectRoot "AitherOS"
$configDir = Join-Path $aitherOSRoot "config"
$secretsDir = Join-Path $configDir "secrets"
$networkLibDir = Join-Path $aitherOSRoot "lib/network"
$mcpToolsDir = Join-Path $aitherOSRoot "AitherNode/tools/mcp"
$templatesDir = Join-Path $aitherOSRoot "templates/web/neocities-starter"
$skillsDir = Join-Path $aitherOSRoot "skills/web-developer"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Test-CloudflaredInstalled {
    $cloudflared = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($cloudflared) {
        return $cloudflared.Source
    }
    
    # Check common paths
    $commonPaths = @(
        "$env:LOCALAPPDATA\cloudflared\cloudflared.exe",
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "$env:USERPROFILE\.cloudflared\cloudflared.exe"
    )
    
    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    return $null
}

function Install-Cloudflared {
    Write-Host "📦 Installing cloudflared..." -ForegroundColor Cyan
    
    if ($IsWindows) {
        # Try winget first
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host "   Using winget to install cloudflared..." -ForegroundColor Yellow
            winget install --id Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements
            return $true
        }
        
        # Fallback to direct download
        Write-Host "   Downloading cloudflared directly..." -ForegroundColor Yellow
        $downloadUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        $installDir = "$env:LOCALAPPDATA\cloudflared"
        $installPath = Join-Path $installDir "cloudflared.exe"
        
        if (-not (Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }
        
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installPath
        
        # Add to PATH for current session
        $env:PATH = "$installDir;$env:PATH"
        
        Write-Host "   Installed to: $installPath" -ForegroundColor Green
        return $true
    }
    elseif ($IsMacOS) {
        Write-Host "   Using Homebrew to install cloudflared..." -ForegroundColor Yellow
        & brew install cloudflared
        return $LASTEXITCODE -eq 0
    }
    else {
        Write-Host "   Please install cloudflared manually:" -ForegroundColor Yellow
        Write-Host "   https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/"
        return $false
    }
}

# ============================================================================
# MAIN SETUP
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║        🌐 AITHER WEB DEVELOPER TOOLKIT SETUP 🌐                   ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$setupSteps = @()
$warnings = @()

# ============================================================================
# STEP 1: Verify Components Exist
# ============================================================================

Write-Host "📋 Step 1: Verifying toolkit components..." -ForegroundColor Cyan

$components = @(
    @{ Name = "AitherTunnel"; Path = "$networkLibDir/AitherTunnel.py"; Required = $true },
    @{ Name = "mcp_neocities"; Path = "$mcpToolsDir/mcp_neocities.py"; Required = $true },
    @{ Name = "Starter Template"; Path = "$templatesDir/index.html"; Required = $true },
    @{ Name = "Web Developer Skill"; Path = "$skillsDir/SKILL.md"; Required = $false }
)

$missingRequired = @()
foreach ($component in $components) {
    if (Test-Path $component.Path) {
        Write-Host "   ✅ $($component.Name)" -ForegroundColor Green
        $setupSteps += "Component verified: $($component.Name)"
    }
    else {
        if ($component.Required) {
            Write-Host "   ❌ $($component.Name) - MISSING" -ForegroundColor Red
            $missingRequired += $component.Name
        }
        else {
            Write-Host "   ⚠️  $($component.Name) - Optional, not found" -ForegroundColor Yellow
            $warnings += "Optional component missing: $($component.Name)"
        }
    }
}

if ($missingRequired.Count -gt 0) {
    Write-Host ""
    Write-Host "❌ Missing required components: $($missingRequired -join ', ')" -ForegroundColor Red
    Write-Host "   Please ensure the web developer toolkit files have been created." -ForegroundColor Yellow
    exit 2
}

# ============================================================================
# STEP 2: Check/Install Cloudflared
# ============================================================================

Write-Host ""
Write-Host "📋 Step 2: Checking cloudflared installation..." -ForegroundColor Cyan

if (-not $SkipCloudflared) {
    $cloudflaredPath = Test-CloudflaredInstalled
    
    if ($cloudflaredPath) {
        Write-Host "   ✅ cloudflared found at: $cloudflaredPath" -ForegroundColor Green
        $setupSteps += "cloudflared verified at $cloudflaredPath"
        
        # Get version
        try {
            $version = & $cloudflaredPath --version 2>&1 | Select-Object -First 1
            Write-Host "   Version: $version" -ForegroundColor Gray
        }
        catch {
            Write-Host "   Could not determine version" -ForegroundColor Yellow
        }
    }
    elseif ($InstallCloudflared) {
        if ($PSCmdlet.ShouldProcess("cloudflared", "Install")) {
            $installed = Install-Cloudflared
            if ($installed) {
                $setupSteps += "cloudflared installed"
                Write-Host "   ✅ cloudflared installed successfully" -ForegroundColor Green
            }
            else {
                $warnings += "cloudflared installation failed - tunnel features will be unavailable"
                Write-Host "   ⚠️  cloudflared installation failed" -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host "   ⚠️  cloudflared not found (tunnel features will be unavailable)" -ForegroundColor Yellow
        $warnings += "cloudflared not installed - tunnel features unavailable"
    }
}
else {
    Write-Host "   ⏭️  Skipping cloudflared check (--SkipCloudflared)" -ForegroundColor Gray
}

# ============================================================================
# STEP 3: Setup Neocities Configuration
# ============================================================================

Write-Host ""
Write-Host "📋 Step 3: Setting up Neocities configuration..." -ForegroundColor Cyan

if ($SetupNeocitiesConfig) {
    # Ensure secrets directory exists
    if (-not (Test-Path $secretsDir)) {
        if ($PSCmdlet.ShouldProcess($secretsDir, "Create directory")) {
            New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
            Write-Host "   Created secrets directory" -ForegroundColor Yellow
        }
    }
    
    $neocitiesConfigPath = Join-Path $secretsDir "neocities.yaml"
    
    if ((Test-Path $neocitiesConfigPath) -and -not $Force) {
        Write-Host "   ✅ neocities.yaml already exists" -ForegroundColor Green
        $setupSteps += "Neocities config already configured"
        
        # Check if it has an API key configured
        $existingConfig = Get-Content $neocitiesConfigPath -Raw
        if ($existingConfig -match 'api_key:\s*"[^"]+"|api_key:\s*[^\s#]+') {
            Write-Host "   API key appears to be configured" -ForegroundColor Gray
        }
        else {
            Write-Host "   ⚠️  API key not configured - edit $neocitiesConfigPath" -ForegroundColor Yellow
            $warnings += "Neocities API key not configured"
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($neocitiesConfigPath, "Create Neocities config")) {
            $configContent = @"
# Neocities Configuration
# =======================
# 
# Get your API key from: https://neocities.org/settings/api_key
#
# IMPORTANT: Keep this file secret! Don't commit to git.
#

# Your Neocities API key
api_key: "$ApiKey"

# Your site name (for display purposes)
site_name: "$SiteName"
"@
            Set-Content -Path $neocitiesConfigPath -Value $configContent
            Write-Host "   ✅ Created neocities.yaml" -ForegroundColor Green
            $setupSteps += "Created Neocities configuration"
            
            if (-not $ApiKey) {
                Write-Host "   ⚠️  Remember to add your API key to: $neocitiesConfigPath" -ForegroundColor Yellow
                $warnings += "Neocities API key not set - add it to neocities.yaml"
            }
        }
    }
    
    # Add to .gitignore if not already there
    $gitignorePath = Join-Path $secretsDir ".gitignore"
    if (-not (Test-Path $gitignorePath)) {
        if ($PSCmdlet.ShouldProcess($gitignorePath, "Create .gitignore")) {
            Set-Content -Path $gitignorePath -Value "# Ignore all secrets`n*`n!.gitignore`n!README.md"
            Write-Host "   Created .gitignore for secrets" -ForegroundColor Gray
        }
    }
}

# ============================================================================
# STEP 4: Verify MCP Tool Registration
# ============================================================================

Write-Host ""
Write-Host "📋 Step 4: Verifying MCP tool registration..." -ForegroundColor Cyan

$mcpInitPath = Join-Path $mcpToolsDir "__init__.py"
if (Test-Path $mcpInitPath) {
    $mcpInit = Get-Content $mcpInitPath -Raw
    if ($mcpInit -match "mcp_neocities") {
        Write-Host "   ✅ mcp_neocities registered in MCP tools" -ForegroundColor Green
        $setupSteps += "MCP tool registration verified"
    }
    else {
        Write-Host "   ⚠️  mcp_neocities not found in __init__.py" -ForegroundColor Yellow
        $warnings += "mcp_neocities may not be registered in MCP __init__.py"
    }
}

# ============================================================================
# STEP 5: Verify Tools Registry
# ============================================================================

Write-Host ""
Write-Host "📋 Step 5: Verifying tools registry..." -ForegroundColor Cyan

$toolsRegistryPath = Join-Path $configDir "tools_registry.yaml"
if (Test-Path $toolsRegistryPath) {
    $registry = Get-Content $toolsRegistryPath -Raw
    if ($registry -match "neocities") {
        Write-Host "   ✅ Neocities tools registered in tools_registry.yaml" -ForegroundColor Green
        $setupSteps += "Tools registry verified"
    }
    else {
        Write-Host "   ⚠️  Neocities tools not found in tools_registry.yaml" -ForegroundColor Yellow
        $warnings += "Neocities tools may not be registered in tools_registry.yaml"
    }
}

# ============================================================================
# STEP 6: Python Dependencies Check
# ============================================================================

Write-Host ""
Write-Host "📋 Step 6: Checking Python dependencies..." -ForegroundColor Cyan

$requirementsPath = Join-Path $aitherOSRoot "AitherNode/requirements.txt"
if (Test-Path $requirementsPath) {
    $requirements = Get-Content $requirementsPath -Raw
    $requiredPkgs = @("aiohttp", "pyyaml")
    $missingPkgs = @()
    
    foreach ($pkg in $requiredPkgs) {
        if ($requirements -match $pkg) {
            Write-Host "   ✅ $pkg in requirements.txt" -ForegroundColor Green
        }
        else {
            $missingPkgs += $pkg
            Write-Host "   ⚠️  $pkg not found in requirements.txt" -ForegroundColor Yellow
        }
    }
    
    if ($missingPkgs.Count -gt 0) {
        $warnings += "Some Python packages may need to be added to requirements.txt: $($missingPkgs -join ', ')"
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              🌐 WEB DEVELOPER TOOLKIT SETUP COMPLETE 🌐           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Host "✅ COMPLETED STEPS:" -ForegroundColor Green
foreach ($step in $setupSteps) {
    Write-Host "   • $step" -ForegroundColor Gray
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "⚠️  WARNINGS:" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "   • $warning" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "📋 NEXT STEPS:" -ForegroundColor Cyan
Write-Host ""
Write-Host "   1. Configure Neocities API key:" -ForegroundColor White
Write-Host "      Edit: $secretsDir/neocities.yaml" -ForegroundColor Gray
Write-Host "      Get key from: https://neocities.org/settings/api_key" -ForegroundColor Gray
Write-Host ""
Write-Host "   2. Deploy the starter template:" -ForegroundColor White
Write-Host "      neocities_upload_directory('$templatesDir')" -ForegroundColor Gray
Write-Host ""
Write-Host "   3. Start a tunnel for chat API:" -ForegroundColor White
Write-Host "      from lib.network.AitherTunnel import AitherTunnel" -ForegroundColor Gray
Write-Host "      tunnel = AitherTunnel(local_port=8118)" -ForegroundColor Gray
Write-Host "      url = await tunnel.start()" -ForegroundColor Gray
Write-Host ""
Write-Host "   4. Read the skill documentation:" -ForegroundColor White
Write-Host "      $skillsDir/SKILL.md" -ForegroundColor Gray
Write-Host ""

exit 0
