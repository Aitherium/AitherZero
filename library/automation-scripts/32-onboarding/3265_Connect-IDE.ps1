#Requires -Version 7.0

<#
.SYNOPSIS
    Wire an IDE / coding agent to the Aitherium MCP gateway (`adk mcp setup`).
.DESCRIPTION
    Generates the MCP client config for Claude Code (default), Cursor,
    Windsurf or VS Code, pointing at mcp.aitherium.com (remote) or the local
    Docker gateway on :8182 (local), then runs `adk mcp status` so the result
    is a proven connection, not a written file. Uses the token saved by
    `adk login`; add -BakeToken for IDEs that cannot do OAuth.
.PARAMETER Ide
    claude-code (default), cursor, windsurf, vscode. 'none' skips the write
    and only prints `adk mcp config` for manual use.
.PARAMETER Mode
    remote (default) or local.
.PARAMETER ProjectDir
    Where the IDE config is written. Default: current directory.
.PARAMETER BakeToken
    Pass --bake-token to adk mcp setup.
.PARAMETER DryRun
    Print what would run.
.EXAMPLE
    ./3265_Connect-IDE.ps1 -Ide claude-code
.NOTES
    Stage: Onboarding
    Dependencies: 3260_Install-AWDK, 3263_Connect-Aitherium
    Tags: mcp, ide, claude-code, cursor, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('claude-code', 'cursor', 'windsurf', 'vscode', 'none')]
    [string]$Ide = 'claude-code',
    [ValidateSet('remote', 'local')]
    [string]$Mode = 'remote',
    [string]$ProjectDir = '',
    [switch]$BakeToken,
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }  # absent from a module built before this function existed
$adk = Get-Command adk -ErrorAction SilentlyContinue
if (-not $adk) { throw "adk not found. Run 32-onboarding/3260_Install-AWDK first." }

if ($Ide -eq 'none') {
    & $adk.Source mcp config
    return
}

$setupArgs = @('mcp', 'setup', '--mode', $Mode, '--ide', $Ide)
if ($ProjectDir) { $setupArgs += @('--project-dir', $ProjectDir) }
if ($BakeToken)  { $setupArgs += '--bake-token' }

if ($DryRun) { Write-Host "[DRY RUN] adk $($setupArgs -join ' '); adk mcp status"; return }

if ($PSCmdlet.ShouldProcess("adk", ($setupArgs -join ' '))) {
    & $adk.Source @setupArgs
    if ($LASTEXITCODE -ne 0) { throw "adk mcp setup exited with code $LASTEXITCODE" }
}

# Prove it: the gateway for the chosen mode must answer. mcp.aitherium.com
# was measured answering [OK] one minute and ReadTimeout the next
# (2026-09-12), so give it three tries before calling the wire broken.
$ok = $false
for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
    $statusOut = (& $adk.Source mcp status 2>&1 | Out-String)
    $ok = $statusOut -match "\[OK\]\s+$Mode"
    if (-not $ok -and $attempt -lt 3) { Write-Host "  gateway '$Mode' not OK (attempt $attempt/3); retrying in 5s"; Start-Sleep 5 }
}
Write-Host $statusOut
if (-not $ok) {
    throw "adk mcp status does not show the '$Mode' gateway as OK after 3 attempts. Config was written; run 'adk login' then 'adk mcp status' to retry."
}
Write-Host "IDE '$Ide' wired to the $Mode MCP gateway." -ForegroundColor Green
