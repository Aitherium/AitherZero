#Requires -Version 7.0

<#
.SYNOPSIS
    Live-verify the full Aitherium developer stack (toolchain, awdk 4.0+, awsh 2.0+, aw* bricks, Antigravity, awrise).
.DESCRIPTION
    Every component is proved by invoking its real binary / CLI and checking its
    output and version floor (adk >= 4.0.0, awsh >= 2.0.0). Guards version-gated
    probes (`awsh avatar --probe` requires awsh >= 2.0; `adk antigravity doctor`
    requires adk >= 4.0) so verifying an older host never hangs. Throws if any
    required check fails.
.PARAMETER RequireGitHubCLI
    Treat `gh` as required (default: optional).
.PARAMETER CheckAntigravity
    Include `adk antigravity doctor` in the verification table (non-fatal if Antigravity isn't installed).
.PARAMETER DryRun
    List every check without executing them.
.EXAMPLE
    ./3273_Test-DevStack.ps1
.NOTES
    Stage: Onboarding
    Dependencies: 3260_Install-AWDK, 3261_Install-AWSH, 3270_Install-AwBrickStack
    Tags: verify, dev-stack, awdk, awsh, awrise
#>

[CmdletBinding()]
param(
    [switch]$RequireGitHubCLI,
    [switch]$CheckAntigravity,
    [switch]$CheckAwnix,
    [string]$AwnixDistroName = 'awnix',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }

$pyCmd = if ($IsWindows) { 'python' } else { 'python3' }
$CoreBricks = @('awrise', 'awgit', 'awm', 'awrelay', 'awdecide', 'awask', 'awrun', 'awfocus', 'awsettings', 'awmine', 'awbrain', 'awrtifact')
$RequiredBricks = @('awrise', 'awgit', 'awm', 'awrelay')

$checks = @(
    @{ Name = 'python';  Command = $pyCmd;   Args = @('--version'); Required = $true;  MinMajor = 3 }
    @{ Name = 'git';     Command = 'git';    Args = @('--version'); Required = $true;  MinMajor = 0 }
    @{ Name = 'node';    Command = 'node';   Args = @('--version'); Required = $true;  MinMajor = 20 }
    @{ Name = 'npm';     Command = 'npm';    Args = @('--version'); Required = $true;  MinMajor = 0 }
    @{ Name = 'gh';      Command = 'gh';     Args = @('--version'); Required = [bool]$RequireGitHubCLI; MinMajor = 0 }
    @{ Name = 'adk';     Command = 'adk';    Args = @('--version'); Required = $true;  MinMajor = 4 }
    @{ Name = 'awsh';    Command = 'awsh';   Args = @('--version'); Required = $true;  MinMajor = 2 }
    @{ Name = 'awrise';  Command = 'awrise'; Args = @('doctor');    Required = $true;  MinMajor = 0 }
)

if ($DryRun) {
    $checks | ForEach-Object { Write-Host "[DRY RUN] would run: $($_.Command) $($_.Args -join ' ')" }
    Write-Host "[DRY RUN] would probe aw* brick versions: $($CoreBricks -join ', ')"
    Write-Host "[DRY RUN] would run: awsh avatar list (when awsh >= 2.0)"
    if ($CheckAntigravity) { Write-Host "[DRY RUN] would run: adk antigravity doctor (when adk >= 4.0)" }
    if ($CheckAwnix -and $IsWindows) { Write-Host "[DRY RUN] would verify WSL2 distro '$AwnixDistroName'" }
    return
}

$rows = New-Object System.Collections.Generic.List[object]
$adkMajor = 0
$awshMajor = 0

if ($CheckAwnix -and $IsWindows) {
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    $ok = $false; $detail = 'wsl.exe not found'
    if ($wsl) {
        $rawList = (& $wsl.Source -l -q 2>$null | Out-String) -replace "`0", ''
        $distros = @($rawList -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($distros -contains $AwnixDistroName) {
            $osRel = (& $wsl.Source -d $AwnixDistroName -- cat /etc/os-release 2>&1 | Out-String)
            $ok = ($LASTEXITCODE -eq 0)
            $pretty = (($osRel -split "`r?`n" | Where-Object { $_ -match '^PRETTY_NAME=' } | Select-Object -First 1) -replace '^PRETTY_NAME=', '').Trim('"')
            $detail = if ($pretty) { $pretty } else { "wsl -d $AwnixDistroName" }
        } else {
            $detail = "distro '$AwnixDistroName' not installed (run: irm goodbyewindows.sh | iex)"
        }
    }
    $rows.Add([PSCustomObject]@{ Component = 'awnix'; Status = if ($ok) { 'OK' } else { 'warn' }; Detail = $detail; Required = $false; Ok = $ok })
}

foreach ($c in $checks) {
    $cmd = Get-Command $c.Command -ErrorAction SilentlyContinue
    $ok = $false
    $detail = 'not found'
    if ($cmd) {
        try {
            $out = (& $cmd.Source @($c.Args) 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
            $first = if ($lines.Count -gt 0) { $lines[0].Trim() } else { '' }
            if ($c.Name -eq 'awrise') {
                $verLine = ($lines | Where-Object { $_ -match 'self\s+awrise' } | Select-Object -First 1)
                $tickLine = ($lines | Where-Object { $_ -match 'last tick' } | Select-Object -First 1)
                $splitLine = ($lines | Where-Object { $_ -match 'SPLIT HOME' } | Select-Object -First 1)
                $detail = if ($splitLine) { $splitLine.Trim() } elseif ($verLine -and $tickLine) { "$($verLine.Trim()) | $($tickLine.Trim())" } else { $first }
                $ok = (-not $splitLine) -and ($code -eq 0 -or [bool]$verLine)
            } else {
                $ok = ($code -eq 0)
                $detail = $first
                if ($out -match '(\d+)\.(\d+)') {
                    $major = [int]$Matches[1]
                    if ($c.Name -eq 'adk')  { $adkMajor  = $major }
                    if ($c.Name -eq 'awsh') { $awshMajor = $major }
                    if ($ok -and $c.MinMajor -gt 0 -and $major -lt $c.MinMajor) {
                        $ok = $false
                        $detail = "$first (requires >= $($c.MinMajor).0)"
                    }
                }
            }
        } catch {
            $detail = "error: $($_.Exception.Message)"
        }
    }
    $rows.Add([PSCustomObject]@{
        Component = $c.Name
        Status    = if ($ok) { 'OK' } elseif ($c.Required) { 'FAIL' } else { 'warn' }
        Detail    = $detail
        Required  = $c.Required
        Ok        = $ok
    })
}

# Version-gated awsh 2.0 avatar check
if ($awshMajor -ge 2) {
    try {
        $out = (& awsh avatar list 2>&1 | Out-String)
        $ok = ($LASTEXITCODE -eq 0)
        $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
        $detail = if ($lines.Count -gt 0) { ($lines | Select-Object -First 1).Trim() } else { '' }
    } catch { $ok = $false; $detail = $_.Exception.Message }
    $rows.Add([PSCustomObject]@{ Component = 'awsh-avatar'; Status = if ($ok) { 'OK' } else { 'warn' }; Detail = $detail; Required = $false; Ok = $ok })
} else {
    $rows.Add([PSCustomObject]@{ Component = 'awsh-avatar'; Status = 'warn'; Detail = "skipped (awsh major=$awshMajor < 2)"; Required = $false; Ok = $false })
}

# Version-gated adk 4.0 Antigravity doctor
if ($CheckAntigravity) {
    if ($adkMajor -ge 4) {
        try {
            $out = (& adk antigravity doctor 2>&1 | Out-String)
            $ok = ($LASTEXITCODE -eq 0)
            $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
            $detail = if ($lines.Count -gt 0) { ($lines | Select-Object -Last 1).Trim() } else { '' }
        } catch { $ok = $false; $detail = $_.Exception.Message }
        $rows.Add([PSCustomObject]@{ Component = 'antigravity'; Status = if ($ok) { 'OK' } else { 'warn' }; Detail = $detail; Required = $false; Ok = $ok })
    } else {
        $rows.Add([PSCustomObject]@{ Component = 'antigravity'; Status = 'warn'; Detail = "skipped (adk major=$adkMajor < 4)"; Required = $false; Ok = $false })
    }
}

# Batch-check all 12 core aw* Python bricks in one fast interpreter invocation
$pyExe = Get-Command $pyCmd -ErrorAction SilentlyContinue
if ($pyExe) {
    $joined = ($CoreBricks -join ',')
    $probe = @"
import importlib.metadata, json
out = {}
for n in '$joined'.split(','):
    try:
        out[n] = importlib.metadata.version(n)
    except importlib.metadata.PackageNotFoundError:
        out[n] = None
print(json.dumps(out))
"@
    $raw = (& $pyExe.Source -c $probe 2>$null | Out-String).Trim()
    $map = if ($raw) { $raw | ConvertFrom-Json } else { $null }
    $present = @(); $missingReq = @(); $missingOpt = @()
    foreach ($b in $CoreBricks) {
        $v = if ($map) { $map.$b } else { $null }
        if ($v) { $present += "$b=$v" }
        elseif ($RequiredBricks -contains $b) { $missingReq += $b }
        else { $missingOpt += $b }
    }
    $bricksOk = ($missingReq.Count -eq 0)
    $bricksDetail = "$($present.Count)/$($CoreBricks.Count) installed" +
        $(if ($missingReq.Count -gt 0) { " | MISSING required: $($missingReq -join ', ')" } else { '' }) +
        $(if ($missingOpt.Count -gt 0) { " | optional missing: $($missingOpt -join ', ')" } else { '' })
    $rows.Add([PSCustomObject]@{
        Component = 'aw-bricks'
        Status    = if ($bricksOk) { 'OK' } else { 'FAIL' }
        Detail    = $bricksDetail
        Required  = $true
        Ok        = $bricksOk
    })
}

$rows | Format-Table Component, Status, Detail -AutoSize | Out-String -Width 220 | Write-Host

$failed = @($rows | Where-Object { $_.Required -and -not $_.Ok })
if ($failed.Count -gt 0) {
    throw "Dev stack verification failed for required component(s): $($failed.Component -join ', ')"
}
Write-Host "Aitherium dev stack verified." -ForegroundColor Green
