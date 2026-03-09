#Requires -Version 7.0

<#
.SYNOPSIS
    Safe wrapper for docker compose commands on AitherOS.

.DESCRIPTION
    Executes any docker compose command with the correct -f and --profile flags
    automatically injected. This prevents the orphaned container bug that occurs
    when compose is invoked without --profile on a fully-profiled compose file.

    Use this instead of raw 'docker compose' for any AitherOS operations.

.PARAMETER Command
    The compose subcommand to run (up, down, restart, build, ps, logs, exec, etc.)

.PARAMETER ArgumentList
    Additional arguments to pass to the compose command.

.PARAMETER Profile
    The compose profile. Defaults to 'all'.

.EXAMPLE
    Invoke-AitherCompose ps
    # docker compose -f <ComposeFile> --profile all ps

.EXAMPLE
    Invoke-AitherCompose up -ArgumentList '-d', '--build', 'aither-moltbook'
    # docker compose -f ... --profile all up -d --build aither-moltbook

.EXAMPLE
    Invoke-AitherCompose exec -ArgumentList 'aither-genesis', 'curl', 'http://localhost:8001/health'
    # Execute a command inside a running container

.EXAMPLE
    Invoke-AitherCompose logs -ArgumentList '-f', '--tail', '100', 'aither-pulse'
    # Tail pulse logs via compose

.NOTES
    This is the SAFE alternative to raw 'docker compose' commands.
    It guarantees --profile is always present.
    Copyright © 2025 Aitherium Corporation
#>
function Invoke-AitherCompose {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('up', 'down', 'restart', 'stop', 'start', 'build', 'pull',
                     'push', 'ps', 'logs', 'exec', 'run', 'config', 'images',
                     'top', 'events', 'port', 'pause', 'unpause', 'rm', 'create')]
        [string]$Command,

        [Parameter(Position = 1, ValueFromRemainingArguments)]
        [string[]]$ArgumentList,

        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile = 'all'
    )

    $cfg = Get-AitherComposeConfig -Profile $Profile
    if (-not $cfg) { return }

    $args = @('compose') + $cfg.BaseArgs + @($Command)

    if ($ArgumentList) {
        $args += $ArgumentList
    }

    Write-Verbose "Executing: docker $($args -join ' ')"
    & docker @args
}
