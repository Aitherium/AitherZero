# _init.ps1
# Common initialization for automation scripts
# Locates the project root and imports the core module

# 1. Find Project Root
$current = $PSScriptRoot
$found = $false

# Locate the module manifest, supporting BOTH shipped layouts (2026-07-25):
#   monorepo   <root>/.PRODUCTS/.AITHERZERO/AitherZero.psd1
#   standalone <root>/AitherZero.psd1     <- the public Aitherium/AitherZero repo
# Only the monorepo marker used to be accepted. The public repo has no
# .PRODUCTS/ directory at all, so this walk-up ran to the drive root, found
# nothing, and threw "FATAL: Could not locate AitherZero project root" — and
# because EVERY automation script dot-sources this file, not one of the
# published scripts could run. Monorepo is probed first so a nested checkout
# still binds to the outer root rather than to itself.
$manifestRel = $null
while ($current -and -not $found) {
    if (Test-Path (Join-Path $current ".PRODUCTS/.AITHERZERO/AitherZero.psd1")) {
        $manifestRel = ".PRODUCTS/.AITHERZERO/AitherZero.psd1"
        $found = $true
        break
    }
    if (Test-Path (Join-Path $current "AitherZero.psd1")) {
        $manifestRel = "AitherZero.psd1"
        $found = $true
        break
    }
    $parent = Split-Path $current -Parent
    if ($parent -eq $current) { break } # Root reached
    $current = $parent
}

if (-not $found) {
    # Fallback to env var if set — again accepting either layout.
    if ($env:AITHERZERO_ROOT -and (Test-Path (Join-Path $env:AITHERZERO_ROOT ".PRODUCTS/.AITHERZERO/AitherZero.psd1"))) {
        $current = $env:AITHERZERO_ROOT
        $manifestRel = ".PRODUCTS/.AITHERZERO/AitherZero.psd1"
    }
    elseif ($env:AITHERZERO_ROOT -and (Test-Path (Join-Path $env:AITHERZERO_ROOT "AitherZero.psd1"))) {
        $current = $env:AITHERZERO_ROOT
        $manifestRel = "AitherZero.psd1"
    }
    else {
        $errMsg = "FATAL: Could not locate AitherZero project root from $PSScriptRoot"
        if ($env:AITHERZERO_ROOT) {
            $errMsg += " (AITHERZERO_ROOT='$env:AITHERZERO_ROOT' contains neither .PRODUCTS/.AITHERZERO/AitherZero.psd1 nor AitherZero.psd1)"
        } else {
            $errMsg += " (set AITHERZERO_ROOT to the repo root, or run build.ps1 to generate AitherZero.psd1)"
        }
        Write-Error $errMsg
        throw $errMsg
    }
}

# Set $projectRoot in the caller's scope
$projectRoot = $current

# 2. Import Core Module
#
# D-848 / root cause of D-844 - DO NOT restore the unconditional `-Force`.
#   Every automation script dot-sources this file, and `Import-Module -Force`
#   REMOVES the module before re-importing it. When a script is run BY the
#   module (Invoke-AitherPlaybook lives inside AitherZero while it invokes each
#   step), that removal destroys the session state of the code that is still
#   running: the in-flight runner loses every module-PRIVATE function and every
#   `$script:` variable it had, and dies at its next such reference with
#   "The term '<X>' is not recognized" - AFTER the step itself completed fine.
#   Exported functions survive, which is why the failure looked so arbitrary.
#
#   So: import only when THIS module is not already loaded. A standalone script
#   run (nothing loaded) still gets the module exactly as before. `-Force` is
#   kept for the case where a DIFFERENT AitherZero is loaded from another
#   checkout, which genuinely must be replaced.
#
#   Trade-off, deliberately accepted: if you rebuild the module mid-session, a
#   script run in that same session keeps the already-loaded copy. Run
#   `Import-Module <path>\AitherZero.psd1 -Force` yourself, or use a new
#   session, to pick up a rebuild.
if ($projectRoot) {
    # $manifestRel was resolved above for whichever layout matched.
    $modulePath = Join-Path $projectRoot ($manifestRel ?? ".PRODUCTS/.AITHERZERO/AitherZero.psd1")
    if (Test-Path $modulePath) {
        $expectedBase = Split-Path $modulePath -Parent
        $alreadyLoaded = Get-Module -Name 'AitherZero' |
            Where-Object { $_.ModuleBase -and ($_.ModuleBase.TrimEnd('\', '/') -eq $expectedBase.TrimEnd('\', '/')) }
        if (-not $alreadyLoaded) {
            Import-Module $modulePath -Force -ErrorAction SilentlyContinue
        }
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
