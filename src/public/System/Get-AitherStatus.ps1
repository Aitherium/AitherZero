#Requires -Version 7.0

<#
.SYNOPSIS
    Get AitherZero system status and health

.DESCRIPTION
    Provides comprehensive status information about the AitherZero installation,
    including module version, configuration status, available scripts/playbooks,
    and system health.

.PARAMETER Detailed
    Show detailed status information

.PARAMETER Health
    Show health check results only

.EXAMPLE
    Get-AitherStatus

.EXAMPLE
    Get-AitherStatus -Detailed

.EXAMPLE
    Get-AitherStatus -Health

.NOTES
    Useful for troubleshooting and system verification.
#>
function Get-AitherStatus {
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$Detailed,

    [Parameter()]
    [switch]$Health
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    $issues = @()
    $warnings = @()
}

process {
    try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return [PSCustomObject]@{
                ModuleVersion = '2.0.0'
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                Platform = 'Unknown'
                ModuleRoot = $moduleRoot
                Initialized = $false
                ConfigLoaded = $false
                Health = 'Unknown'
            }
        }

        $statusInfo = @{
            ModuleVersion = '2.0.0'
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            Platform = if ($IsWindows) { 'Windows' }
            elseif ($IsLinux) { 'Linux' }
            elseif ($IsMacOS) { 'macOS' }
            else { 'Unknown' }
            ModuleRoot = $moduleRoot
            Initialized = $env:AITHERZERO_INITIALIZED -eq '1'
        }

        # Check configuration
        try {
            if (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue) {
                $config = Get-AitherConfigs -ErrorAction Stop
                $statusInfo.ConfigLoaded = $true
                $statusInfo.ConfigPath = (Get-AitherConfigs -Path)
                $statusInfo.Environment = $config.Core.Environment
                $statusInfo.Profile = $config.Core.Profile
            } else {
                $statusInfo.ConfigLoaded = $false
                $issues += "Get-AitherConfigs is not available"
            }
        }
        catch {
            $statusInfo.ConfigLoaded = $false
            $issues += "Configuration not loaded: $_"
        }

        # Check scripts directory
        try {
            $scriptsPath = Get-AitherScriptsPath
            if (Test-Path $scriptsPath) {
                $scripts = Get-ChildItem -Path $scriptsPath -Filter '*.ps1' -ErrorAction SilentlyContinue
                $statusInfo.ScriptsAvailable = $scripts.Count
                $statusInfo.ScriptsPath = $scriptsPath
            } else {
                $statusInfo.ScriptsAvailable = 0
                $warnings += "Scripts directory found but inaccessible: $scriptsPath"
            }
        } catch {
            $statusInfo.ScriptsAvailable = 0
            $warnings += "Scripts directory not found: $($_.Exception.Message)"
        }

        # Check playbooks directory
        $playbooksPath = Join-Path $moduleRoot 'library' 'playbooks'
        if (Test-Path $playbooksPath) {
            $playbooks = Get-ChildItem -Path $playbooksPath -Filter '*.psd1' -ErrorAction SilentlyContinue
            $statusInfo.PlaybooksAvailable = $playbooks.Count
        }
        else {
            $statusInfo.PlaybooksAvailable = 0
            $warnings += "Playbooks directory not found"
        }

        # Check logs directory
        $logsPath = Join-Path $moduleRoot 'library' 'logs'
        $statusInfo.LogsPath = $logsPath
        $statusInfo.LogsPathExists = Test-Path $logsPath

        # Health check
        $healthStatus = 'Healthy'
        if ($issues.Count -gt 0) {
            $healthStatus = 'Unhealthy'
        }
        elseif ($warnings.Count -gt 0) {
            $healthStatus = 'Degraded'
        }

        $statusInfo.Health = $healthStatus
        $statusInfo.Issues = $issues
        $statusInfo.Warnings = $warnings

        # Display
        if ($Health) {
            $healthLevel = switch ($healthStatus) {
                'Healthy' { 'Information' }
                'Degraded' { 'Warning' }
                'Unhealthy' { 'Error' }
                default { 'Information' }
            }
            Write-AitherLog -Level $healthLevel -Message "Health Status: $healthStatus" -Source 'Get-AitherStatus'

            if ($issues.Count -gt 0) {
                Write-AitherLog -Level Error -Message "Issues:" -Source 'Get-AitherStatus'
                $issues | ForEach-Object { Write-AitherLog -Level Error -Message "  - $_" -Source 'Get-AitherStatus' }
            }
            if ($warnings.Count -gt 0) {
                Write-AitherLog -Level Warning -Message "Warnings:" -Source 'Get-AitherStatus'
                $warnings | ForEach-Object { Write-AitherLog -Level Warning -Message "  - $_" -Source 'Get-AitherStatus' }
            }
        }
        else {
            Write-AitherLog -Level Information -Message "=== AitherZero Status ===" -Source 'Get-AitherStatus'
            Write-AitherLog -Level Information -Message "Version: $($statusInfo.ModuleVersion)" -Source 'Get-AitherStatus'
            Write-AitherLog -Level Information -Message "Platform: $($statusInfo.Platform)" -Source 'Get-AitherStatus'
            Write-AitherLog -Level Information -Message "PowerShell: $($statusInfo.PowerShellVersion)" -Source 'Get-AitherStatus'
            $healthLevel = switch ($healthStatus) {
                'Healthy' { 'Information' }
                'Degraded' { 'Warning' }
                'Unhealthy' { 'Error' }
                default { 'Information' }
            }
            Write-AitherLog -Level $healthLevel -Message "Health: $healthStatus" -Source 'Get-AitherStatus'

            if ($statusInfo.ConfigLoaded) {
                Write-AitherLog -Level Information -Message "Configuration:" -Source 'Get-AitherStatus'
                Write-AitherLog -Level Information -Message "  Environment: $($statusInfo.Environment)" -Source 'Get-AitherStatus'
                Write-AitherLog -Level Information -Message "  Profile: $($statusInfo.Profile)" -Source 'Get-AitherStatus'
            }

            Write-AitherLog -Level Information -Message "Resources:" -Source 'Get-AitherStatus'
            Write-AitherLog -Level Information -Message "  Scripts: $($statusInfo.ScriptsAvailable)" -Source 'Get-AitherStatus'
            Write-AitherLog -Level Information -Message "  Playbooks: $($statusInfo.PlaybooksAvailable)" -Source 'Get-AitherStatus'

            if ($Detailed) {
                Write-AitherLog -Level Information -Message "Paths:" -Source 'Get-AitherStatus'
                Write-AitherLog -Level Information -Message "  Module Root: $($statusInfo.ModuleRoot)" -Source 'Get-AitherStatus'
                Write-AitherLog -Level Information -Message "  Config Path: $($statusInfo.ConfigPath)" -Source 'Get-AitherStatus'
                Write-AitherLog -Level Information -Message "  Logs Path: $($statusInfo.LogsPath)" -Source 'Get-AitherStatus'
            }
        }

        return [PSCustomObject]$statusInfo
    }
    catch {
        Write-AitherLog -Level Error -Message "Failed to get status: $_" -Source 'Get-AitherStatus' -Exception $_
        throw
    }
}

}

