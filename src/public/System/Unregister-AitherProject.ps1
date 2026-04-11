#Requires -Version 7.0

function Unregister-AitherProject {
    <#
    .SYNOPSIS
        Remove a project from the AitherZero registry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$Name
    )

    process {
        if ($PSCmdlet.ShouldProcess($Name, "Unregister project")) {
            $registryPath = Get-AitherProjectRegistryPath
            if (-not (Test-Path $registryPath)) { return }

            try {
                $content = Get-Content -Path $registryPath -Raw
                if (-not [string]::IsNullOrWhiteSpace($content)) {
                    $projects = @($content | ConvertFrom-Json)
                    $initialCount = $projects.Count
                    $projects = @($projects | Where-Object { $_.Name -ne $Name })
                    
                    if ($projects.Count -ne $initialCount) {
                        $projects | ConvertTo-Json -Depth 5 | Set-Content -Path $registryPath
                        Write-AitherLog -Level Information -Message "Unregistered project '$Name'" -Source 'Unregister-AitherProject'
                    } else {
                        Write-AitherLog -Level Warning -Message "Project '$Name' not found in registry." -Source 'Unregister-AitherProject'
                    }
                }
            }
            catch {
                Write-AitherLog -Level Warning -Message "Failed to update registry: $_" -Source 'Unregister-AitherProject' -Exception $_
            }
        }
    }
}

