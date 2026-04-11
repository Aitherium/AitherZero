# _init.ps1
# Common initialization for automation scripts
# Locates the project root and imports the core module

# 1. Find Project Root
$current = $PSScriptRoot
$found = $false

# Walk up the directory tree to find the repo root (marked by AitherZero/AitherZero.psd1)
while ($current -and -not $found) {
    if (Test-Path (Join-Path $current "AitherZero/AitherZero.psd1")) {
        $found = $true
        break
    }
    $parent = Split-Path $current -Parent
    if ($parent -eq $current) { break } # Root reached
    $current = $parent
}

if (-not $found) {
    # Fallback to env var if set
    if ($env:AITHERZERO_ROOT) {
        $current = $env:AITHERZERO_ROOT
    }
    else {
        Write-Warning "Could not locate AitherZero project root from $PSScriptRoot"
        # Don't exit, let the script fail naturally or handle it
    }
}

# Set $projectRoot in the caller's scope
$projectRoot = $current

# 2. Import Core Module
if ($projectRoot) {
    $modulePath = Join-Path $projectRoot "AitherZero/AitherZero.psd1"
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-FeatureEnabled {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Name
    )

    $Config = Get-AitherConfigs

    # Check if running in non-interactive mode (from config or environment)
    $isNonInteractive = $false
    if ($Config.Core -and $Config.Core.NonInteractive -eq $true) {
        $isNonInteractive = $true
    }
    if ($env:CI -eq 'true' -or $env:AITHERZERO_NONINTERACTIVE -eq '1' -or $env:AITHEROS_NONINTERACTIVE -eq '1') {
        $isNonInteractive = $true
    }

    # Helper to get nested value
    $val = $Config.$Section
    $parts = $Key.Split('.')
    foreach ($part in $parts) {
        if ($val -is [System.Collections.IDictionary] -and $val.Contains($part)) {
            $val = $val.$part
        }
        else {
            $val = $null
            break
        }
    }

    # Check if Enabled exists and is false
    $isEnabled = $true
    if ($val -is [System.Collections.IDictionary] -and $val.Contains('Enabled')) {
        $isEnabled = $val.Enabled
    }
    elseif ($val -is [bool]) {
        $isEnabled = $val
    }

    if (-not $isEnabled) {
        $msg = "Feature '$Name' ($Section.$Key) is disabled in configuration."

        # In non-interactive mode, auto-enable the feature
        if ($isNonInteractive) {
            Write-Host "[AUTO] $msg Auto-enabling for automation." -ForegroundColor Yellow
            try {
                Set-AitherConfig -Section $Section -Key "$Key.Enabled" -Value $true -ErrorAction Stop
                Write-Host "[OK] Enabled '$Name' in config.local.psd1" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not auto-enable feature. Continuing anyway..."
            }
            return
        }

        # Interactive mode - prompt user
        Write-Warning $msg
        if ($PSCmdlet.ShouldContinue("Enable '$Name' in local configuration?", "Feature Disabled")) {
            Set-AitherConfig -Section $Section -Key "$Key.Enabled" -Value $true -ErrorAction Stop
            Write-Host "[OK] Enabled '$Name' in config.local.psd1" -ForegroundColor Green
        }
        else {
            throw "Execution aborted: Feature '$Name' is disabled. To enable, run: Set-AitherConfig -Section '$Section' -Key '$Key.Enabled' -Value `$true"
        }
    }
}
