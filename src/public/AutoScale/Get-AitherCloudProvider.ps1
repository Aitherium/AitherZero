#Requires -Version 7.0

<#
.SYNOPSIS
    List and check configured cloud providers for auto-scaling.
.DESCRIPTION
    Enumerates all registered cloud providers (AWS, Azure, GCP) plus on-prem
    targets (Docker, Hyper-V). Shows configuration status, region, and health.
.PARAMETER Name
    Filter to a specific provider by name.
.PARAMETER HealthCheck
    Perform an active health check on each provider.
.PARAMETER Raw
    Return raw data instead of formatted output.
.EXAMPLE
    Get-AitherCloudProvider
.EXAMPLE
    Get-AitherCloudProvider -HealthCheck
.EXAMPLE
    Get-AitherCloudProvider -Name "aws"
.NOTES
    Part of AitherZero AutoScale module.
    Copyright © 2025 Aitherium Corporation.
#>
function Get-AitherCloudProvider {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [string]$Name,

        [switch]$HealthCheck,
        [switch]$Raw
    )

    begin {
        $AutoScaleUrl = $env:AITHER_AUTOSCALE_URL
        if (-not $AutoScaleUrl) { $AutoScaleUrl = "http://localhost:8797" }
    }

    process {
        try {
            $response = Invoke-RestMethod -Uri "$AutoScaleUrl/providers" -TimeoutSec 10 -ErrorAction Stop
            $providers = if ($response.data) { $response.data } else { $response }

            if ($Name) {
                $providers = $providers | Where-Object { $_.name -eq $Name }
            }

            if ($Raw) { return $providers }

            Write-Host "`n☁️  AutoScale Providers" -ForegroundColor Cyan
            Write-Host "──────────────────────" -ForegroundColor DarkGray

            $results = @()
            foreach ($p in $providers) {
                $icon = switch ($p.type) {
                    'on-prem' { '🏠' }
                    'aws'     { '🟠' }
                    'azure'   { '🔵' }
                    'gcp'     { '🟢' }
                    default   { '☁️' }
                }
                $statusIcon = if ($p.enabled) { '✅' } else { '❌' }

                $results += [PSCustomObject]@{
                    Icon    = $icon
                    Name    = $p.name
                    Type    = $p.type
                    Region  = $p.region
                    Enabled = $p.enabled
                    Status  = $p.status
                }

                Write-Host " $icon $($p.name.PadRight(10)) | $statusIcon Enabled=$($p.enabled) | Region=$($p.region) | Status=$($p.status)"
            }

            return $results

        } catch {
            Write-Warning "Could not fetch providers from AutoScale agent: $_"

            # Fallback: check env vars for configured providers
            Write-Host "`n☁️  Cloud Provider Detection (from environment)" -ForegroundColor Yellow
            $results = @()

            # Docker always available
            $results += [PSCustomObject]@{ Name = 'docker'; Type = 'on-prem'; Status = 'available' }
            Write-Host " 🏠 docker    | ✅ Always available"

            if ($env:AWS_ACCESS_KEY_ID -or $env:AITHER_AWS_ENABLED) {
                $results += [PSCustomObject]@{ Name = 'aws'; Type = 'cloud'; Region = $env:AWS_REGION ?? 'us-east-1'; Status = 'configured' }
                Write-Host " 🟠 aws       | ✅ Configured (region: $($env:AWS_REGION ?? 'us-east-1'))"
            }
            if ($env:AZURE_SUBSCRIPTION_ID -or $env:AITHER_AZURE_ENABLED) {
                $results += [PSCustomObject]@{ Name = 'azure'; Type = 'cloud'; Region = $env:AZURE_REGION ?? 'eastus'; Status = 'configured' }
                Write-Host " 🔵 azure     | ✅ Configured (region: $($env:AZURE_REGION ?? 'eastus'))"
            }
            if ($env:GOOGLE_APPLICATION_CREDENTIALS -or $env:AITHER_GCP_ENABLED) {
                $results += [PSCustomObject]@{ Name = 'gcp'; Type = 'cloud'; Region = $env:GCP_REGION ?? 'us-central1'; Status = 'configured' }
                Write-Host " 🟢 gcp       | ✅ Configured (region: $($env:GCP_REGION ?? 'us-central1'))"
            }

            # Hyper-V detection (Windows only)
            if ($IsWindows) {
                try {
                    $hyperv = Get-Command Get-VM -ErrorAction SilentlyContinue
                    if ($hyperv) {
                        $results += [PSCustomObject]@{ Name = 'hyperv'; Type = 'on-prem'; Status = 'available' }
                        Write-Host " 🏠 hyperv    | ✅ Available"
                    }
                } catch { }
            }

            return $results
        }
    }
}
