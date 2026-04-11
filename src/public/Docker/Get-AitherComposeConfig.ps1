#Requires -Version 7.0

<#
.SYNOPSIS
    Get the Docker Compose configuration for AitherOS.

.DESCRIPTION
    Returns the resolved compose file path, project name, and default profile.
    All AitherOS Docker commands MUST use this to ensure --profile is always included,
    preventing orphaned/hash-prefixed containers.

    This is the single source of truth for compose invocations across the module.

.PARAMETER ProjectRoot
    Override the project root directory. Defaults to AITHERZERO_ROOT or auto-detected.

.PARAMETER Profile
    The Docker Compose profile to use. Defaults to 'all'.
    Available: core, intelligence, perception, memory, training, autonomic, security,
    agents, social, creative, gpu, gateway, mcp, external, desktop, all

.EXAMPLE
    $cfg = Get-AitherComposeConfig
    docker compose -f $cfg.ComposeFile --profile $cfg.Profile up -d

.EXAMPLE
    Get-AitherComposeConfig -Profile social
    # Returns config scoped to social services only

.NOTES
    CRITICAL: Never invoke docker compose without --profile on AitherOS.
    All services use profiles, so omitting --profile sees ZERO services and causes
    container name collisions (hash-prefixed orphans).
    Copyright © 2025 Aitherium Corporation
#>
function Get-AitherComposeConfig {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string]$ProjectRoot,

        [Parameter()]
        [ValidateSet('core', 'intelligence', 'perception', 'memory', 'training',
                     'autonomic', 'security', 'agents', 'social', 'creative',
                     'gpu', 'gateway', 'mcp', 'external', 'desktop', 'all')]
        [string]$Profile = 'all'
    )

    # Resolve project root
    if (-not $ProjectRoot) {
        $ProjectRoot = if ($env:AITHERZERO_ROOT) { $env:AITHERZERO_ROOT }
                       elseif ($script:ProjectRoot) { $script:ProjectRoot }
                       else { Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent }
    }

    $ctx = Get-AitherLiveContext
    $composeFile = Join-Path $ProjectRoot $ctx.ComposeFile

    if (-not (Test-Path $composeFile)) {
        Write-Error "Compose file not found: $composeFile"
        return $null
    }

    [PSCustomObject]@{
        PSTypeName  = 'AitherOS.ComposeConfig'
        ComposeFile = $composeFile
        ProjectRoot = $ProjectRoot
        ProjectName = 'aitheros'
        Profile     = $Profile
        # Pre-built arg array for splatting into docker compose calls
        BaseArgs    = @('-f', $composeFile, '--profile', $Profile)
    }
}
