function Unregister-AitherPlugin {
    <#
    .SYNOPSIS
        Unregisters an AitherZero plugin.
    .PARAMETER Name
        The name of the plugin to unregister.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $plugins = [AitherPluginState]::Plugins
    if ($plugins.ContainsKey($Name)) {
        $plugin = $plugins[$Name]

        # Remove script paths
        if ($plugin.Manifest.ScriptPaths) {
            foreach ($sp in $plugin.Manifest.ScriptPaths) {
                $fullPath = Join-Path $plugin.Path $sp
                [AitherPluginState]::ScriptPaths.Remove($fullPath) | Out-Null
            }
        }

        # Remove playbook paths
        if ($plugin.Manifest.PlaybookPaths) {
            foreach ($pp in $plugin.Manifest.PlaybookPaths) {
                $fullPath = Join-Path $plugin.Path $pp
                [AitherPluginState]::PlaybookPaths.Remove($fullPath) | Out-Null
            }
        }

        $plugins.Remove($Name)
        Write-Verbose "Plugin '$Name' unregistered."
    } else {
        Write-Warning "Plugin '$Name' is not registered."
    }
}
