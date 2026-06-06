#Requires -Version 7.0
<#
.SYNOPSIS
    Switch between GitHub accounts (git identity + gh CLI auth).

.DESCRIPTION
    Switches both the repo-level git commit identity and the active gh CLI
    account between two pre-configured profiles.  Temporarily unsets GH_TOKEN
    so that `gh auth switch` works (VS Code / Copilot inject it at the
    process level).

.PARAMETER Profile
    Which account profile to activate: 'personal' (wizzense) or 'work' (aither-wzns).
    Aliases: 'p'/'w', '1'/'2', 'wizzense'/'aither-wzns'.

.PARAMETER Status
    Show current identity without changing anything.

.EXAMPLE
    ./0704_Switch-GitHubAccount.ps1 personal
    ./0704_Switch-GitHubAccount.ps1 work
    ./0704_Switch-GitHubAccount.ps1 -Status

.NOTES
    Git identity and gh active account persist to disk and work across shells.
    If GH_TOKEN is set in your current shell (Copilot/VS Code inject it),
    dot-source the script to clear it in your session too:

        . ./0704_Switch-GitHubAccount.ps1 work

    Without dot-sourcing, git identity still switches correctly but `gh` CLI
    may still auth as the GH_TOKEN user in that specific shell.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Profile,

    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Profile definitions ────────────────────────────────────────────
$Profiles = @{
    personal = @{
        GitName  = 'wizzense'
        GitEmail = 'wizzense@users.noreply.github.com'
        GhUser   = 'wizzense'
        Label    = 'Personal (wizzense)'
    }
    work = @{
        GitName  = 'aither_wzns'
        GitEmail = 'david@aitherium.com'
        GhUser   = 'aither-wzns'
        Label    = 'Work (aither-wzns / Aitherium)'
    }
}

# ── Aliases ─────────────────────────────────────────────────────────
$AliasMap = @{
    'p' = 'personal'; '1' = 'personal'; 'wizzense' = 'personal'
    'w' = 'work';     '2' = 'work';     'aither-wzns' = 'work'; 'aither_wzns' = 'work'
}

# ── Show current status ────────────────────────────────────────────
function Show-Status {
    $name  = git config user.name 2>$null
    $email = git config user.email 2>$null
    $savedToken = $env:GH_TOKEN
    $env:GH_TOKEN = $null
    $ghStatus = gh auth status 2>&1 | Out-String
    $env:GH_TOKEN = $savedToken

    Write-Host "`n  Git identity : $name <$email>" -ForegroundColor Cyan
    Write-Host "  gh CLI status:" -ForegroundColor Cyan
    $ghStatus -split "`n" | ForEach-Object {
        if ($_ -match 'Active account: true') {
            Write-Host "    $_" -ForegroundColor Green
        } elseif ($_ -match 'account (\S+)') {
            Write-Host "    $_" -ForegroundColor White
        } elseif ($_ -match '✓') {
            Write-Host "    $_" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}

# ── Main ────────────────────────────────────────────────────────────
if ($Status -or -not $Profile) {
    Show-Status
    if (-not $Profile) {
        Write-Host "  Usage: Switch-GitHubAccount <personal|work>" -ForegroundColor Yellow
        Write-Host "         Aliases: p/w, 1/2, wizzense/aither-wzns`n" -ForegroundColor DarkGray
    }
    return
}

$resolved = if ($AliasMap.ContainsKey($Profile.ToLower())) { $AliasMap[$Profile.ToLower()] } else { $Profile.ToLower() }

if (-not $Profiles.ContainsKey($resolved)) {
    Write-Error "Unknown profile '$Profile'. Use: personal, work (or aliases p/w, 1/2)"
    return
}

$target = $Profiles[$resolved]

# 1. Switch git identity (repo-level)
git config user.name  $target.GitName
git config user.email $target.GitEmail

# 2. Unset GH_TOKEN so gh auth switch works
$savedToken = $env:GH_TOKEN
$env:GH_TOKEN = $null

# 3. Switch gh CLI active account
$switchResult = gh auth switch --user $target.GhUser 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Warning "gh auth switch failed: $switchResult"
    Write-Warning "You may need to run: `$env:GH_TOKEN = `$null; gh auth login -h github.com -p https -w"
}

# 4. Restore GH_TOKEN (some tools may need it)
# NOTE: We intentionally do NOT restore GH_TOKEN — it overrides gh auth switch.
# If a tool needs it, set it manually.

Write-Host "`n  ✓ Switched to $($target.Label)" -ForegroundColor Green
Write-Host "    Git : $($target.GitName) <$($target.GitEmail)>" -ForegroundColor Cyan
Write-Host "    gh  : $($target.GhUser)" -ForegroundColor Cyan

if ($savedToken) {
    Write-Host "`n  ⚠ GH_TOKEN was set (Copilot/VS Code inject it)." -ForegroundColor Yellow
    Write-Host "    Git identity is switched. For gh CLI too, run:" -ForegroundColor Yellow
    Write-Host "      `$env:GH_TOKEN = `$null" -ForegroundColor White
    Write-Host "    Or dot-source next time:  . ./0704_Switch-GitHubAccount.ps1 $resolved" -ForegroundColor DarkGray
}
Write-Host ""
