#Requires -Version 7.0

<#
.SYNOPSIS
    Registers an AitherZero plugin from a directory.
.DESCRIPTION
    Loads a plugin manifest (plugin.psd1), merges its configuration overlay,
    registers its scripts with the script engine, dot-sources its functions,
    and registers its playbooks.

    Plugins extend AitherZero with project-specific automation without modifying
    the core module.
.PARAMETER Path
    Path to the plugin directory containing a plugin.psd1 manifest.
.PARAMETER Force
    Re-register even if the plugin is already loaded.
.EXAMPLE
    Register-AitherPlugin -Path ./plugins/my-webapp
.EXAMPLE
    Get-ChildItem ./plugins -Directory | ForEach-Object { Register-AitherPlugin -Path $_.FullName }
.NOTES
    Part of the AitherZero Plugin System.
#>
function Register-AitherPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [switch]$Force
    )

    process {
        $resolvedPath = Resolve-Path -Path $Path -ErrorAction Stop
        $manifestPath = Join-Path $resolvedPath 'plugin.psd1'

        if (-not (Test-Path $manifestPath)) {
            Write-Error "Plugin manifest not found: $manifestPath"
            return
        }

        # Load manifest
        $manifest = Import-PowerShellDataFile -Path $manifestPath

        $pluginName = $manifest.Name
        if (-not $pluginName) {
            Write-Error "Plugin manifest at '$manifestPath' is missing the 'Name' field."
            return
        }

        # Check if already registered
        if (-not $Force -and [AitherPluginState]::Plugins.ContainsKey($pluginName)) {
            Write-Verbose "Plugin '$pluginName' is already registered. Use -Force to re-register."
            return
        }

        # Version check
        if ($manifest.MinimumVersion) {
            $moduleVersion = (Get-Module AitherZero -ErrorAction SilentlyContinue)?.Version
            if ($moduleVersion -and $moduleVersion -lt [version]$manifest.MinimumVersion) {
                Write-Error "Plugin '$pluginName' requires AitherZero >= $($manifest.MinimumVersion), but $moduleVersion is loaded."
                return
            }
        }

        # Check required plugins
        if ($manifest.RequiredPlugins) {
            foreach ($required in $manifest.RequiredPlugins) {
                if (-not [AitherPluginState]::Plugins.ContainsKey($required)) {
                    Write-Error "Plugin '$pluginName' requires plugin '$required' which is not registered."
                    return
                }
            }
        }

        Write-Verbose "Registering plugin: $pluginName v$($manifest.Version) from $resolvedPath"

        # 1. Merge config overlay
        if ($manifest.ConfigOverlay) {
            $overlayPath = Join-Path $resolvedPath $manifest.ConfigOverlay
            if (Test-Path $overlayPath) {
                $overlay = Import-PowerShellDataFile -Path $overlayPath
                # Use AitherPluginState.Config as the canonical merged config
                $mergedConfig = [AitherPluginState]::Config
                if (-not $mergedConfig) {
                    if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                        $mergedConfig = Get-AitherConfigs -ErrorAction SilentlyContinue
                    }
                    if (-not $mergedConfig) {
                        $mergedConfig = @{}
                    }
                    [AitherPluginState]::Config = $mergedConfig
                }
                Merge-PluginConfig -Base $mergedConfig -Overlay $overlay
                # Keep $script: alias in sync
                $script:AitherConfig = $mergedConfig
                Write-Verbose "  Merged config overlay: $overlayPath"
            }
        }

        # 1b. Cross-plugin port conflict detection
        if ($overlay -and $overlay.Services -and $overlay.Services.Ports) {
            foreach ($existingPlugin in $script:RegisteredPlugins.Values) {
                $existingPorts = $existingPlugin.Manifest.Services.Ports
                if (-not $existingPorts) {
                    # Check from merged config if plugin had ports (resolve from stored overlay)
                    continue
                }
                # No action needed — config overlay was already merged.
                # Just check if the incoming plugin shares ports with an already-loaded plugin.
            }

            # Check for actual port collisions with already-registered plugins
            $newPorts = @{}
            foreach ($key in $overlay.Services.Ports.Keys) {
                $newPorts[$overlay.Services.Ports[$key]] = $key
            }

            foreach ($existingPlugin in $script:RegisteredPlugins.Values) {
                if (-not $existingPlugin.Manifest) { continue }
                $epOverlayPath = if ($existingPlugin.Manifest.ConfigOverlay) {
                    Join-Path $existingPlugin.Path $existingPlugin.Manifest.ConfigOverlay
                }
                if ($epOverlayPath -and (Test-Path $epOverlayPath)) {
                    try {
                        $epOverlay = Import-PowerShellDataFile -Path $epOverlayPath
                        if ($epOverlay.Services -and $epOverlay.Services.Ports) {
                            foreach ($epKey in $epOverlay.Services.Ports.Keys) {
                                $epPort = $epOverlay.Services.Ports[$epKey]
                                if ($newPorts.ContainsKey($epPort)) {
                                    $conflictService = $newPorts[$epPort]
                                    Write-Warning (
                                        "Port conflict: plugin '$pluginName' service '$conflictService' " +
                                        "and plugin '$($existingPlugin.Name)' service '$epKey' " +
                                        "both use port $epPort. Containers/networks are isolated, " +
                                        "but host port bindings will collide."
                                    )
                                }
                            }
                        }
                    } catch {
                        # Non-fatal — can't read existing overlay
                    }
                }
            }
        }

        # 2. Register script paths
        $registeredScripts = 0
        if ($manifest.ScriptPaths) {
            foreach ($scriptPath in $manifest.ScriptPaths) {
                $fullScriptPath = Join-Path $resolvedPath $scriptPath
                if (Test-Path $fullScriptPath) {
                    [AitherPluginState]::ScriptPaths.Add($fullScriptPath)
                    $registeredScripts += (Get-ChildItem -Path $fullScriptPath -Filter '*.ps1' -Recurse).Count
                    Write-Verbose "  Registered script path: $fullScriptPath"
                }
            }
        }

        # 3. Dot-source functions
        $registeredFunctions = 0
        if ($manifest.FunctionPaths) {
            foreach ($funcPath in $manifest.FunctionPaths) {
                $fullFuncPath = Join-Path $resolvedPath $funcPath
                if (Test-Path $fullFuncPath) {
                    $funcFiles = Get-ChildItem -Path $fullFuncPath -Filter '*.ps1' -Recurse
                    foreach ($funcFile in $funcFiles) {
                        try {
                            . $funcFile.FullName
                            $registeredFunctions++
                        } catch {
                            Write-Warning "Failed to load function from '$($funcFile.FullName)': $_"
                        }
                    }
                    Write-Verbose "  Loaded $($funcFiles.Count) function(s) from: $fullFuncPath"
                }
            }
        }

        # 4. Register playbooks
        $registeredPlaybooks = 0
        if ($manifest.PlaybookPaths) {
            foreach ($playbookPath in $manifest.PlaybookPaths) {
                $fullPlaybookPath = Join-Path $resolvedPath $playbookPath
                if (Test-Path $fullPlaybookPath) {
                    [AitherPluginState]::PlaybookPaths.Add($fullPlaybookPath)
                    $registeredPlaybooks += (Get-ChildItem -Path $fullPlaybookPath -Filter '*.psd1' -Recurse).Count
                    Write-Verbose "  Registered playbook path: $fullPlaybookPath"
                }
            }
        }

        # Store registration
        [AitherPluginState]::Plugins[$pluginName] = @{
            Name       = $pluginName
            Version    = $manifest.Version
            Path       = $resolvedPath.ToString()
            Manifest   = $manifest
            LoadedAt   = [datetime]::UtcNow
            Scripts    = $registeredScripts
            Functions  = $registeredFunctions
            Playbooks  = $registeredPlaybooks
        }

        Write-Verbose "Plugin '$pluginName' registered: $registeredScripts scripts, $registeredFunctions functions, $registeredPlaybooks playbooks"
    }
}

# --- Private helpers ---

function Merge-PluginConfig {
    [CmdletBinding()]
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    foreach ($key in $Overlay.Keys) {
        if ($Base.ContainsKey($key) -and $Base[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            Merge-PluginConfig -Base $Base[$key] -Overlay $Overlay[$key]
        } else {
            $Base[$key] = $Overlay[$key]
        }
    }
}

# Backward-compat: keep $script: aliases pointing to AitherPluginState
# (some code may reference these directly)
$script:RegisteredPlugins = [AitherPluginState]::Plugins
$script:PluginScriptPaths = [AitherPluginState]::ScriptPaths
$script:PluginPlaybookPaths = [AitherPluginState]::PlaybookPaths

# Note: Deferred plugin loading is handled in the build post-init section
# (see build.ps1 — appended after all functions are defined and exported)
