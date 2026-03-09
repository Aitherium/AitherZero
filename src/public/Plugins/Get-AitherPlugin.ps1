function Get-AitherPlugin {
    <#
    .SYNOPSIS
        Lists registered AitherZero plugins.
    .DESCRIPTION
        Returns information about all currently registered plugins or a specific plugin by name.
    .PARAMETER Name
        Optional plugin name to filter by.
    .EXAMPLE
        Get-AitherPlugin
    .EXAMPLE
        Get-AitherPlugin -Name 'my-webapp'
    #>
    [CmdletBinding()]
    param(
        [string]$Name
    )

    $plugins = [AitherPluginState]::Plugins
    if (-not $plugins -or $plugins.Count -eq 0) {
        return @()
    }

    if ($Name) {
        if ($plugins.ContainsKey($Name)) {
            [PSCustomObject]$plugins[$Name]
        }
    } else {
        $plugins.Values | ForEach-Object { [PSCustomObject]$_ }
    }
}
