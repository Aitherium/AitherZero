#Requires -Version 7.0

<#
.SYNOPSIS
    Verify the developer workstation toolchain: every tool resolves AND answers.
.DESCRIPTION
    A listening `Get-Command` is not a working tool. Each check runs the real
    binary with --version (or `adk status` for the SDK) and reports
    installed / version / path in one table. Exit 1 if any REQUIRED tool is
    missing, so a playbook stops here rather than declaring success.
.PARAMETER RequireGitHubCLI
    Treat `gh` as required (default: optional).
.PARAMETER DryRun
    List the checks without running them.
.EXAMPLE
    ./3217_Test-DevWorkstation.ps1
.NOTES
    Stage: Onboarding
    Dependencies: None
    Tags: verify, onboarding, awdk, awsh
#>

[CmdletBinding()]
param(
    [switch]$RequireGitHubCLI,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

Update-AitherSessionPath

$checks = @(
    @{ Name = 'python'; Command = $(if ($IsWindows) { 'python' } else { 'python3' }); Args = @('--version'); Required = $true }
    @{ Name = 'pip';    Command = $(if ($IsWindows) { 'python' } else { 'python3' }); Args = @('-m', 'pip', '--version'); Required = $true }
    @{ Name = 'git';    Command = 'git';  Args = @('--version'); Required = $true }
    @{ Name = 'node';   Command = 'node'; Args = @('--version'); Required = $true }
    @{ Name = 'npm';    Command = 'npm';  Args = @('--version'); Required = $true }
    @{ Name = 'gh';     Command = 'gh';   Args = @('--version'); Required = [bool]$RequireGitHubCLI }
    @{ Name = 'adk';    Command = 'adk';  Args = @('status');    Required = $true }
    @{ Name = 'awsh';   Command = 'awsh'; Args = @('--version'); Required = $true }
)

if ($DryRun) {
    $checks | ForEach-Object { Write-Host "[DRY RUN] would run: $($_.Command) $($_.Args -join ' ')" }
    return
}

$rows = foreach ($c in $checks) {
    $cmd = Get-Command $c.Command -ErrorAction SilentlyContinue
    $ok = $false; $detail = 'not found'
    if ($cmd) {
        try {
            $out = (& $cmd.Source @($c.Args) 2>&1 | Out-String)
            $ok = ($LASTEXITCODE -eq 0)
            # First non-empty line is the version for everything except adk,
            # where the useful line is the one naming a reachable backend.
            $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
            $detail = if ($c.Name -eq 'adk') {
                $up = @($lines | Where-Object { $_ -match '\[\+\]' })
                if ($up.Count -gt 0) { "$($up.Count) backend(s) UP: " + (($up | ForEach-Object { ($_ -replace '^\s*\[\+\]\s*', '') -replace '\s{2,}', ' ' }) -join '; ') }
                elseif ($ok) { 'installed; no backend reachable (run adk quickstart or adk login)' }
                else { ($lines | Select-Object -First 1) }
            } else { ($lines | Select-Object -First 1) }
        } catch {
            $detail = "error: $($_.Exception.Message)"
        }
    }
    [PSCustomObject]@{
        Tool     = $c.Name
        Status   = if ($ok) { 'OK' } elseif ($c.Required) { 'MISSING' } else { 'optional' }
        Detail   = $detail
        Path     = if ($cmd) { $cmd.Source } else { '' }
        Required = $c.Required
        Ok       = $ok
    }
}

$rows | Format-Table Tool, Status, Detail, Path -AutoSize | Out-String -Width 200 | Write-Host

$missing = @($rows | Where-Object { $_.Required -and -not $_.Ok })
if ($missing.Count -gt 0) {
    # throw, not exit: the playbook engine ignores `exit N` by design.
    throw "MISSING (required): $($missing.Tool -join ', ')"
}
Write-Host "All required tools present." -ForegroundColor Green
