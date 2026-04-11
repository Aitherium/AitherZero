function Get-AitherLiveContext {
    <#
    .SYNOPSIS
        Returns the current ProjectContext configuration.
    .DESCRIPTION
        Reads from the loaded config (base + plugin overlay). Functions should use this
        instead of hardcoding compose files, ports, container prefixes, etc.

        The ProjectContext defines what project this AitherZero instance manages:
        - ComposeFile, ProjectName, ContainerPrefix, NetworkName
        - OrchestratorURL, MetricsURL, TelemetryURL, EventBusURL
        - RegistryURL, ServicesFile, ConfigPath, Domain

        These values are set to generic defaults in config.psd1 and overridden by
        plugin config overlays (e.g., the AitherOS plugin sets them to AitherOS values).
    .EXAMPLE
        $ctx = Get-AitherLiveContext
        docker compose -f $ctx.ComposeFile up -d
    .EXAMPLE
        $ctx = Get-AitherLiveContext
        Invoke-RestMethod "$($ctx.OrchestratorURL)/health"
    #>
    [CmdletBinding()]
    param()

    # Try AitherPluginState (canonical merged config, survives scope splits)
    $cfg = [AitherPluginState]::Config
    if ($cfg -and $cfg.ProjectContext) {
        return $cfg.ProjectContext
    }

    # Try loading from Get-AitherConfigs
    if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
        $cfg = Get-AitherConfigs
        if ($cfg -and $cfg.ProjectContext) {
            return $cfg.ProjectContext
        }
    }

    # Fallback: return defaults
    return @{
        Name            = 'MyProject'
        ComposeFile     = 'docker-compose.yml'
        ProjectName     = 'myproject'
        ContainerPrefix = 'myproject'
        NetworkName     = 'myproject-net'
        RegistryURL     = ''
        OrchestratorURL = ''
        MetricsURL      = ''
        EventBusURL     = ''
        TelemetryURL    = ''
        ServicesFile    = ''
        ConfigPath      = 'config/'
        Domain          = ''
    }
}
