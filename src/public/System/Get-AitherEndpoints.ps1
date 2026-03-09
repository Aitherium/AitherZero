#Requires -Version 7.0

<#
.SYNOPSIS
    Get AitherZero system endpoints and URLs.

.DESCRIPTION
    Retrieves and displays the URLs and ports for various AitherZero services,
    including the Web Dashboard, Gateway, and Agent endpoints.

.EXAMPLE
    Get-AitherEndpoints

.NOTES
    Useful for quickly finding where to access services.
#>
function Get-AitherEndpoints {
    [CmdletBinding()]
    param()

    process {
        try {
            $endpoints = [ordered]@{}
            $ctx = Get-AitherLiveContext

            # 1. Web Dashboard (Local)
            $dashboardUrl = "http://localhost:3000"
            if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                $config = Get-AitherConfigs -ErrorAction SilentlyContinue
                if ($config.Network.DashboardPort) {
                    $hostName = if ($config.Network.Host) { $config.Network.Host } else { "localhost" }
                    $dashboardUrl = "http://${hostName}:$($config.Network.DashboardPort)"
                }
            }
            $endpoints["Web Dashboard"] = $dashboardUrl

            # 2. Web Gateway (Public)
            $root = if ($env:AITHERZERO_ROOT) { $env:AITHERZERO_ROOT } else { $PSScriptRoot }
            if ($root -match "src[\\/]public") {
                 if (Get-Command Get-AitherModuleRoot -ErrorAction SilentlyContinue) {
                     $root = Get-AitherModuleRoot
                 }
            }

            $gatewayPath = $null
            $possiblePaths = @(
                (Join-Path $root "gateway_url.txt"),
                (Join-Path $PWD "gateway_url.txt")
            )
            foreach ($p in $possiblePaths) {
                if (Test-Path $p) { $gatewayPath = $p; break }
            }

            if ($gatewayPath) {
                $endpoints["Web Gateway"] = (Get-Content $gatewayPath -Raw).Trim()
            } else {
                $endpoints["Web Gateway"] = "Not available (gateway_url.txt not found)"
            }

            # 3. Orchestrator / API (from ProjectContext)
            if ($ctx.OrchestratorURL) {
                $endpoints["Orchestrator"] = $ctx.OrchestratorURL
            }
            if ($ctx.MetricsURL) {
                $endpoints["Metrics"] = $ctx.MetricsURL
            }
            if ($ctx.TelemetryURL) {
                $endpoints["Telemetry"] = $ctx.TelemetryURL
            }

            # 4. Service ports from config
            if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                $config = Get-AitherConfigs -ErrorAction SilentlyContinue
                if ($config.Services.Ports) {
                    foreach ($svc in $config.Services.Ports.GetEnumerator()) {
                        $endpoints[$svc.Key] = "http://localhost:$($svc.Value)"
                    }
                }
            }

            # 5. AI Services (vLLM Multi-Model) if configured
            if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                $config = Get-AitherConfigs -ErrorAction SilentlyContinue
                if ($config.AI.vLLM) {
                    foreach ($worker in @('Orchestrator','Reasoning','Vision','Coding')) {
                        if ($config.AI.vLLM.$worker.Port) {
                            $endpoints["vLLM $worker"] = "http://localhost:$($config.AI.vLLM.$worker.Port)"
                        }
                    }
                }
                if ($config.AI.ComfyUI.Port) {
                    $endpoints["ComfyUI"] = "http://localhost:$($config.AI.ComfyUI.Port)"
                }
            }

            $obj = [PSCustomObject]$endpoints

            Write-AitherLog -Level Information -Message "=== $($ctx.Name) Endpoints ===" -Source 'Get-AitherEndpoints'
            foreach ($key in $endpoints.Keys) {
                Write-AitherLog -Level Information -Message "  $($key): $($endpoints[$key])" -Source 'Get-AitherEndpoints'
            }

            return $obj
        }
        catch {
            Write-AitherLog -Level Error -Message "Failed to get endpoints: $_" -Source 'Get-AitherEndpoints' -Exception $_
            throw
        }
    }
}
