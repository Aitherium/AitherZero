#Requires -Version 7.0

<#
.SYNOPSIS
    Resolves an AitherOS service URL dynamically from the service registry.

.DESCRIPTION
    Looks up service port and URL from AitherZero/config/services.psd1 (which mirrors
    AitherOS/config/services.yaml). Supports service names, aliases, and Docker mode
    hostname resolution. Eliminates hardcoded port assumptions.

    In Docker mode (AITHER_DOCKER_MODE=true), resolves to container hostnames instead
    of localhost. Supports multi-node deployments via environment variable overrides.

.PARAMETER Name
    Service name or alias (e.g., 'Genesis', 'Node', 'Pulse', 'MicroScheduler').

.PARAMETER PathOnly
    Return just the port number instead of the full URL.

.PARAMETER HealthEndpoint
    Append the service's health check path to the URL.

.EXAMPLE
    Resolve-AitherServiceUrl -Name Genesis
    # Returns: http://localhost:8001

.EXAMPLE
    Resolve-AitherServiceUrl -Name MicroScheduler
    # Returns: http://localhost:8150

.EXAMPLE
    Resolve-AitherServiceUrl -Name Node -HealthEndpoint
    # Returns: http://localhost:8080/health

.EXAMPLE
    $env:AITHER_DOCKER_MODE = 'true'
    Resolve-AitherServiceUrl -Name Genesis
    # Returns: http://aitheros-genesis:8001

.NOTES
    Category: Configuration
    Platform: Windows, Linux, macOS
#>
function Resolve-AitherServiceUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [switch]$PortOnly,

        [Parameter()]
        [switch]$HealthEndpoint
    )

    # Known aliases (matching AitherPorts.py)
    $aliases = @{
        'Orchestrator'  = 'Genesis'
        'LLM'           = 'MicroScheduler'
        'Scheduler'     = 'MicroScheduler'
        'Brain'         = 'Genesis'
        'MCP'           = 'Node'
        'Events'        = 'Pulse'
        'Logs'          = 'Chronicle'
        'Vault'         = 'Secrets'
        'Ingestion'     = 'Strata'
        'Dashboard'     = 'Veil'
        'UI'            = 'Veil'
    }

    $resolvedName = if ($aliases.ContainsKey($Name)) { $aliases[$Name] } else { $Name }

    # Try loading from services.psd1
    $port = $null
    $healthPath = '/health'
    $containerName = $null

    if (-not $script:_ServiceRegistryCache) {
        $moduleRoot = Get-AitherModuleRoot -ErrorAction SilentlyContinue
        if (-not $moduleRoot) { $moduleRoot = Join-Path $projectRoot "AitherZero" }
        $registryPath = Join-Path $moduleRoot "config/services.psd1"

        if (Test-Path $registryPath) {
            try {
                $script:_ServiceRegistryCache = Import-PowerShellDataFile $registryPath -ErrorAction Stop
            }
            catch {
                Write-Verbose "Could not load services.psd1: $_"
            }
        }
    }

    if ($script:_ServiceRegistryCache -and $script:_ServiceRegistryCache.Services) {
        $services = $script:_ServiceRegistryCache.Services

        # Direct name match
        $svcKey = $services.Keys | Where-Object {
            $_ -eq $resolvedName -or
            $_ -eq "Aither$resolvedName" -or
            $_ -like "*$resolvedName*"
        } | Select-Object -First 1

        if ($svcKey) {
            $svc = $services[$svcKey]
            $port = $svc.Port
            if ($svc.HealthPath) { $healthPath = $svc.HealthPath }
            $containerName = "aitheros-$($svcKey.ToLower() -replace '^aither', '')"
        }

        # Try aliases within services.psd1
        if (-not $port) {
            foreach ($key in $services.Keys) {
                $svc = $services[$key]
                if ($svc.Aliases -and ($svc.Aliases -contains $resolvedName)) {
                    $port = $svc.Port
                    if ($svc.HealthPath) { $healthPath = $svc.HealthPath }
                    $containerName = "aitheros-$($key.ToLower() -replace '^aither', '')"
                    break
                }
            }
        }
    }

    # Fallback: well-known ports
    if (-not $port) {
        $wellKnown = @{
            'Genesis'        = 8001;  'Node'           = 8080
            'Pulse'          = 8081;  'Watch'          = 8082
            'Secrets'        = 8111;  'Chronicle'      = 8121
            'Strata'         = 8136;  'MicroScheduler' = 8150
            'Veil'           = 3000;  'Compute'        = 8168
            'Mesh'           = 8125;  'Comet'          = 8126
            'MCPGateway'     = 8180;  'Directory'      = 8190
        }

        if ($wellKnown.ContainsKey($resolvedName)) {
            $port = $wellKnown[$resolvedName]
            $containerName = "aitheros-$($resolvedName.ToLower())"
        }
        else {
            Write-Warning "Service '$Name' not found in registry or well-known ports."
            return $null
        }
    }

    if ($PortOnly) {
        return $port
    }

    # Determine hostname
    $isDocker = $env:AITHER_DOCKER_MODE -eq 'true'
    $host_ = if ($isDocker -and $containerName) { $containerName } else { 'localhost' }

    # Check for environment override (e.g., AITHER_GENESIS_URL)
    $envKey = "AITHER_$($resolvedName.ToUpper())_URL"
    $envOverride = [Environment]::GetEnvironmentVariable($envKey)
    if ($envOverride) {
        return $envOverride
    }

    $url = "http://${host_}:${port}"
    if ($HealthEndpoint) {
        $url += $healthPath
    }

    return $url
}
