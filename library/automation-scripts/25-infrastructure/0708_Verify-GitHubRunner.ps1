#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies the GitHub Actions self-hosted runner service is running and registered.

.DESCRIPTION
    Post-install / post-reboot health check for the self-hosted runner:
    1. Checks the Windows service exists and is running
    2. Verifies runner is registered with GitHub
    3. Optionally restarts the service if stopped

.PARAMETER RunnerName
    Runner display name. Default: hostname.

.PARAMETER InstallPath
    Runner installation directory. Default: D:\actions-runner

.PARAMETER Repository
    GitHub repository in "owner/repo" format. Default: Aitherium/AitherOS

.PARAMETER AutoRestart
    Automatically restart the service if it is stopped.

.PARAMETER ShowOutput
    Show detailed output during execution.

.EXAMPLE
    .\0708_Verify-GitHubRunner.ps1 -ShowOutput
    .\0708_Verify-GitHubRunner.ps1 -AutoRestart -ShowOutput

.NOTES
    Stage: Infrastructure
    Order: 0708
    Category: GitHub Actions
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [string]$RunnerName = $env:COMPUTERNAME,
    [string]$InstallPath = "D:\actions-runner",
    [string]$Repository = "Aitherium/AitherOS",
    [switch]$AutoRestart,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'
$exitCode = 0
$svcName = "actions.runner.Aitherium-AitherOS.$RunnerName"

function Write-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = "")
    $icon = if ($Pass) { "PASS" } else { "FAIL" }
    $color = if ($Pass) { "Green" } else { "Red" }
    if ($ShowOutput) {
        Write-Host "  [$icon] $Name" -ForegroundColor $color -NoNewline
        if ($Detail) { Write-Host " — $Detail" -ForegroundColor Gray } else { Write-Host "" }
    }
}

if ($ShowOutput) {
    Write-Host ""
    Write-Host "GitHub Actions Runner Health Check" -ForegroundColor Cyan
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  Runner: $RunnerName"
    Write-Host "  Path:   $InstallPath"
    Write-Host ""
}

# ── Check 1: Install directory exists ────────────────────────────────────────
$installExists = Test-Path $InstallPath
Write-Check "Install directory" $installExists $InstallPath
if (-not $installExists) {
    Write-Error "Runner not installed at $InstallPath. Run 3045_Setup-GitHubRunner.ps1 first."
}

# ── Check 2: Runner binary exists ────────────────────────────────────────────
$runnerExe = Join-Path $InstallPath "bin\Runner.Listener.exe"
$exeExists = Test-Path $runnerExe
Write-Check "Runner binary" $exeExists

# ── Check 3: Runner is configured ────────────────────────────────────────────
$configFile = Join-Path $InstallPath ".runner"
$isConfigured = Test-Path $configFile
Write-Check "Runner configured (.runner file)" $isConfigured

# ── Check 4: Windows service exists ──────────────────────────────────────────
$svcQuery = & sc.exe query $svcName 2>&1
$svcExists = $LASTEXITCODE -eq 0
Write-Check "Windows service exists" $svcExists $svcName

if (-not $svcExists) {
    if ($ShowOutput) {
        Write-Host ""
        Write-Host "  Service not found. To install:" -ForegroundColor Yellow
        Write-Host "    sc.exe create $svcName binpath= `"$InstallPath\bin\RunnerService.exe`" start= auto" -ForegroundColor White
    }
    $exitCode = 1
}

# ── Check 5: Service is running ──────────────────────────────────────────────
$svcRunning = $false
if ($svcExists) {
    $stateMatch = $svcQuery | Select-String "STATE\s+:\s+\d+\s+(\w+)"
    if ($stateMatch) {
        $state = $stateMatch.Matches[0].Groups[1].Value
        $svcRunning = $state -eq "RUNNING"
        Write-Check "Service running" $svcRunning "State: $state"

        if (-not $svcRunning -and $AutoRestart) {
            if ($ShowOutput) { Write-Host "  Attempting restart..." -ForegroundColor Yellow }
            & sc.exe start $svcName 2>&1 | Out-Null
            Start-Sleep -Seconds 3
            $recheckQuery = & sc.exe query $svcName 2>&1
            $recheckMatch = $recheckQuery | Select-String "STATE\s+:\s+\d+\s+(\w+)"
            if ($recheckMatch -and $recheckMatch.Matches[0].Groups[1].Value -eq "RUNNING") {
                if ($ShowOutput) { Write-Host "  Service restarted successfully." -ForegroundColor Green }
                $svcRunning = $true
            } else {
                if ($ShowOutput) { Write-Host "  Restart failed." -ForegroundColor Red }
            }
        }
    }

    # Check start type is auto
    $startType = & sc.exe qc $svcName 2>&1 | Select-String "START_TYPE\s+:\s+\d+\s+(\w+)"
    if ($startType) {
        $isAuto = $startType.Matches[0].Groups[1].Value -eq "AUTO_START"
        Write-Check "Service start=auto (survives reboot)" $isAuto
        if (-not $isAuto) { $exitCode = 1 }
    }
}

if (-not $svcRunning) { $exitCode = 1 }

# ── Check 6: GitHub registration ─────────────────────────────────────────────
$ghRegistered = $false
if (Get-Command gh -ErrorAction SilentlyContinue) {
    try {
        $runners = gh api "repos/$Repository/actions/runners" --jq ".runners[] | select(.name == `"$RunnerName`") | .status" 2>$null
        if ($runners) {
            $ghRegistered = $true
            Write-Check "GitHub registration" $true "Status: $runners"
        } else {
            Write-Check "GitHub registration" $false "Runner '$RunnerName' not found in repo runners"
            $exitCode = 1
        }
    } catch {
        Write-Check "GitHub registration" $false "gh API call failed"
        $exitCode = 1
    }
} else {
    if ($ShowOutput) { Write-Host "  [SKIP] GitHub registration check — gh CLI not available" -ForegroundColor Yellow }
}

# ── Summary ──────────────────────────────────────────────────────────────────
if ($ShowOutput) {
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "  Runner is healthy and will persist across reboots." -ForegroundColor Green
    } else {
        Write-Host "  Runner has issues. See failures above." -ForegroundColor Red
    }
    Write-Host ""
}

exit $exitCode
