#Requires -Version 7.0
<#
.SYNOPSIS
    Set up a partner profile — interactive wizard or config file.

.DESCRIPTION
    Handles the partner profile creation step of AitherOS installation.
    Three modes:
      1. Interactive wizard: launches AitherVeil installer at localhost:3000
      2. Non-interactive with existing profile: validates and uses it
      3. Non-interactive without profile: generates a sensible default

    After this script runs, $env:AITHER_PARTNER_PROFILE points to the
    active profile directory (config/profiles/{slug}/).

.PARAMETER ProfilePath
    Path to an existing partner profile directory. If set and valid,
    skips creation and uses this profile directly.

.PARAMETER Interactive
    Force launch of the AitherVeil installer wizard (requires Node.js).
    The wizard runs at localhost:3000 in installer mode.

.PARAMETER NonInteractive
    Skip all prompts. If no profile exists, generate a default one.

.PARAMETER PartnerName
    Partner name for non-interactive default profile creation.

.EXAMPLE
    .\3033_Setup-PartnerInteractive.ps1 -Interactive
    # Launches the web-based installer wizard

.EXAMPLE
    .\3033_Setup-PartnerInteractive.ps1 -NonInteractive -PartnerName "Acme Corp"
    # Creates a default profile for Acme Corp

.EXAMPLE
    .\3033_Setup-PartnerInteractive.ps1 -ProfilePath config/profiles/acme-corp
    # Uses an existing profile

.NOTES
    Category: deploy
    Dependencies: Python 3.10+, Node.js 18+ (for interactive mode)
    Platform: Windows, Linux, macOS
    Script: 3033
#>

[CmdletBinding()]
param(
    [string]$ProfilePath = '',
    [switch]$Interactive,
    [switch]$NonInteractive,
    [string]$PartnerName = ''
)

$ErrorActionPreference = 'Stop'

# ─── Resolve AitherOS root ───────────────────────────────────────────────────
$ScriptRoot = $PSScriptRoot
$AitherOSRoot = (Get-Item "$ScriptRoot/../../..").FullName

# Fallback: try common relative locations
if (-not (Test-Path "$AitherOSRoot/config/services.yaml")) {
    $candidates = @(
        (Get-Item "$ScriptRoot/../../../AitherOS" -ErrorAction SilentlyContinue),
        (Get-Item "$env:AITHEROS_ROOT" -ErrorAction SilentlyContinue)
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path "$($c.FullName)/config/services.yaml")) {
            $AitherOSRoot = $c.FullName
            break
        }
    }
}

$ProfilesDir = Join-Path $AitherOSRoot "config/profiles"
$python = if ($env:AITHEROS_PYTHON) { $env:AITHEROS_PYTHON } else { 'python' }
$setupScript = Join-Path $AitherOSRoot "scripts/partner-setup.py"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          AitherOS Partner Profile Setup          ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# ─── Case 1: Existing profile path provided ──────────────────────────────────

if ($ProfilePath) {
    # Resolve relative paths
    if (-not (Test-Path "$ProfilePath/profile.yaml")) {
        $fullPath = Join-Path $AitherOSRoot $ProfilePath
        if (Test-Path "$fullPath/profile.yaml") {
            $ProfilePath = $fullPath
        }
    }

    if (Test-Path "$ProfilePath/profile.yaml") {
        Write-Host "  Using existing profile: $ProfilePath" -ForegroundColor Green
        $env:AITHER_PARTNER_PROFILE = (Resolve-Path $ProfilePath).Path
        Write-Host "  AITHER_PARTNER_PROFILE=$env:AITHER_PARTNER_PROFILE" -ForegroundColor DarkGray
        return
    }
    else {
        Write-Host "  WARN: Profile not found at $ProfilePath" -ForegroundColor Yellow
    }
}

# ─── Case 2: Auto-detect existing profile ────────────────────────────────────

if (Test-Path $ProfilesDir) {
    $existingProfiles = Get-ChildItem -Path $ProfilesDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_*' -and (Test-Path "$($_.FullName)/profile.yaml") }

    if ($existingProfiles.Count -eq 1) {
        $found = $existingProfiles[0].FullName
        Write-Host "  Found existing profile: $($existingProfiles[0].Name)" -ForegroundColor Green
        $env:AITHER_PARTNER_PROFILE = $found
        Write-Host "  AITHER_PARTNER_PROFILE=$env:AITHER_PARTNER_PROFILE" -ForegroundColor DarkGray
        return
    }
    elseif ($existingProfiles.Count -gt 1) {
        Write-Host "  Multiple profiles found:" -ForegroundColor Yellow
        foreach ($p in $existingProfiles) {
            Write-Host "    - $($p.Name)" -ForegroundColor White
        }
        if ($NonInteractive) {
            $first = $existingProfiles[0].FullName
            Write-Host "  Non-interactive: using first profile ($($existingProfiles[0].Name))" -ForegroundColor Yellow
            $env:AITHER_PARTNER_PROFILE = $first
            return
        }
        else {
            Write-Host ""
            $idx = 1
            foreach ($p in $existingProfiles) {
                Write-Host "  [$idx] $($p.Name)" -ForegroundColor Cyan
                $idx++
            }
            $choice = Read-Host "  Select profile (1-$($existingProfiles.Count))"
            $selected = [int]$choice - 1
            if ($selected -ge 0 -and $selected -lt $existingProfiles.Count) {
                $env:AITHER_PARTNER_PROFILE = $existingProfiles[$selected].FullName
                return
            }
            Write-Host "  Invalid selection, continuing to create new profile..." -ForegroundColor Yellow
        }
    }
}

# ─── Case 3: Interactive wizard ──────────────────────────────────────────────

if ($Interactive) {
    Write-Host "  Launching AitherVeil installer wizard..." -ForegroundColor Cyan

    $veilDir = Join-Path $AitherOSRoot "apps/AitherVeil"
    if (-not (Test-Path "$veilDir/package.json")) {
        Write-Host "  ERROR: AitherVeil not found at $veilDir" -ForegroundColor Red
        Write-Host "  Falling back to CLI mode..." -ForegroundColor Yellow
        $Interactive = $false
    }
    else {
        # Check Node.js
        $nodeAvailable = $false
        try {
            $nodeVersion = & node --version 2>$null
            if ($nodeVersion) { $nodeAvailable = $true }
        }
        catch {}

        if (-not $nodeAvailable) {
            Write-Host "  Node.js not found — installing..." -ForegroundColor Yellow
            if ($IsWindows -or (-not (Test-Path variable:/IsWindows) -and $env:OS -eq 'Windows_NT')) {
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    & winget install --id OpenJS.NodeJS.LTS --source winget --accept-source-agreements --accept-package-agreements --silent
                }
                elseif (Get-Command choco -ErrorAction SilentlyContinue) {
                    & choco install nodejs-lts -y
                }
                else {
                    Write-Host "  ERROR: Cannot auto-install Node.js. Install from https://nodejs.org" -ForegroundColor Red
                    $Interactive = $false
                }
            }
            elseif ($IsMacOS) {
                if (Get-Command brew -ErrorAction SilentlyContinue) {
                    & brew install node@20
                }
            }
            else {
                # Linux — try NodeSource
                try {
                    & curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
                    & sudo apt-get install -y nodejs
                }
                catch {
                    Write-Host "  ERROR: Cannot auto-install Node.js. Install from https://nodejs.org" -ForegroundColor Red
                    $Interactive = $false
                }
            }

            # Refresh PATH
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            }
        }

        if ($Interactive) {
            # Install deps and start wizard
            Write-Host "  Installing AitherVeil dependencies..." -ForegroundColor DarkGray
            Push-Location $veilDir
            try {
                & npm install --silent 2>$null
                Write-Host ""
                Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Green
                Write-Host "  │  Installer wizard starting at:                   │" -ForegroundColor Green
                Write-Host "  │  http://localhost:3000                           │" -ForegroundColor Green
                Write-Host "  │                                                  │" -ForegroundColor Green
                Write-Host "  │  Complete all 8 steps, then close the wizard.    │" -ForegroundColor Green
                Write-Host "  │  Press Ctrl+C here when done.                    │" -ForegroundColor Green
                Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Green
                Write-Host ""

                $env:NEXT_PUBLIC_INSTALLER_MODE = "true"
                try {
                    & npm run dev 2>$null
                }
                catch {
                    # User hit Ctrl+C — that's the expected exit
                }
                finally {
                    Remove-Item Env:\NEXT_PUBLIC_INSTALLER_MODE -ErrorAction SilentlyContinue
                }
            }
            finally {
                Pop-Location
            }

            # Re-scan for the profile that was just created
            if (Test-Path $ProfilesDir) {
                $newProfiles = Get-ChildItem -Path $ProfilesDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike '_*' -and (Test-Path "$($_.FullName)/profile.yaml") }

                if ($newProfiles.Count -ge 1) {
                    $newest = $newProfiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    $env:AITHER_PARTNER_PROFILE = $newest.FullName
                    Write-Host "  Profile created: $($newest.Name)" -ForegroundColor Green
                    return
                }
            }

            Write-Host "  WARN: No profile found after wizard. Generating default..." -ForegroundColor Yellow
        }
    }
}

# ─── Case 4: CLI interactive mode ────────────────────────────────────────────

if (-not $NonInteractive -and -not $Interactive) {
    Write-Host "  How would you like to configure AitherOS?" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] Quick setup (default name, default settings)" -ForegroundColor Cyan
    Write-Host "  [2] CLI guided setup (name, colors, tier)" -ForegroundColor Cyan
    Write-Host "  [3] Web wizard (full interactive installer)" -ForegroundColor Cyan
    Write-Host ""
    $modeChoice = Read-Host "  Choice (1/2/3) [1]"

    switch ($modeChoice) {
        '3' {
            # Recursive call with -Interactive
            & $PSCommandPath -Interactive -ProfilePath $ProfilePath -PartnerName $PartnerName
            return
        }
        '2' {
            # CLI guided via partner-setup.py
            if (Test-Path $setupScript) {
                if (-not $PartnerName) {
                    $PartnerName = Read-Host "  Partner/Company name"
                }
                if (-not $PartnerName) { $PartnerName = "My AitherOS" }

                & $python $setupScript init --name $PartnerName --interactive
                if ($LASTEXITCODE -eq 0) {
                    # Find the just-created profile
                    $slug = ($PartnerName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
                    $createdPath = Join-Path $ProfilesDir $slug
                    if (Test-Path "$createdPath/profile.yaml") {
                        $env:AITHER_PARTNER_PROFILE = $createdPath
                        Write-Host "  Profile created: $slug" -ForegroundColor Green
                        return
                    }
                }
                Write-Host "  WARN: Profile creation failed, generating default..." -ForegroundColor Yellow
            }
        }
        default {
            # Fall through to default generation
        }
    }
}

# ─── Case 5: Generate default profile ────────────────────────────────────────

Write-Host "  Generating default profile..." -ForegroundColor Cyan

if (-not $PartnerName) {
    $PartnerName = if ($env:COMPUTERNAME) { "$env:COMPUTERNAME AitherOS" }
                   elseif ($env:HOSTNAME) { "$env:HOSTNAME AitherOS" }
                   else { "My AitherOS" }
}

if (Test-Path $setupScript) {
    & $python $setupScript init --name $PartnerName
    if ($LASTEXITCODE -eq 0) {
        $slug = ($PartnerName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        $createdPath = Join-Path $ProfilesDir $slug
        if (Test-Path "$createdPath/profile.yaml") {
            $env:AITHER_PARTNER_PROFILE = $createdPath
            Write-Host "  Default profile created: $slug" -ForegroundColor Green
            return
        }
    }
}

# Absolute fallback: create minimal profile manually
$slug = ($PartnerName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
if (-not $slug) { $slug = "default" }
$fallbackDir = Join-Path $ProfilesDir $slug

if (-not (Test-Path $fallbackDir)) {
    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
}

$profileYaml = @"
version: "1.0"
partner:
  name: "$PartnerName"
  slug: "$slug"
  license_key: ""
  plan_tier: "professional"
  contact_email: ""
branding:
  system_name: "AitherOS"
  primary_color: "#0ea5e9"
  secondary_color: "#6366f1"
  accent_color: "#22d3ee"
  tagline: "AI-Powered Operations"
deployment:
  target: "docker"
  modules: ["core", "intelligence", "agents"]
  gpu_profile: "auto"
created_at: "$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ')"
installer_version: "1.0.0"
"@

Set-Content -Path (Join-Path $fallbackDir "profile.yaml") -Value $profileYaml
$env:AITHER_PARTNER_PROFILE = $fallbackDir
Write-Host "  Fallback profile created: $fallbackDir" -ForegroundColor Green
