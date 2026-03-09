#Requires -Version 7.0

<#
.SYNOPSIS
    Initialize dashboard generation session

.DESCRIPTION
    Sets up configuration and prepares for metrics collection for dashboard generation.
    Creates output directory and initializes session tracking.

.PARAMETER ProjectPath
    Path to the project root (default: current directory '.')

.PARAMETER OutputPath
    Path where dashboard files will be generated (default: 'AitherZero/library/reports/dashboard')

.PARAMETER Configuration
    Optional hashtable of dashboard configuration settings

.EXAMPLE
    Initialize-AitherDashboard

    Initialize a dashboard session with default paths

.EXAMPLE
    Initialize-AitherDashboard -ProjectPath . -OutputPath ./dashboards

    Initialize a dashboard session with custom output path

.OUTPUTS
    Hashtable - Dashboard configuration object

.NOTES
    Must be called before registering metrics or generating dashboard files.
    Session start time is tracked for duration calculation.

.LINK
    Register-AitherMetrics
    New-AitherDashboard
    Complete-AitherDashboard
#>
function Initialize-AitherDashboard {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ProjectPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = 'AitherZero/library/reports/dashboard',

    [hashtable]$Configuration = @{},

    [Parameter(HelpMessage = "Show command output in console.")]
    [switch]$ShowOutput
)

begin {
    # Manage logging targets for this execution
    $originalLogTargets = $script:AitherLogTargets
    if ($ShowOutput) {
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Ensure Console is NOT in targets if ShowOutput is not specified
        $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
    }

    # Script-level variables for dashboard session
    if (-not $script:DashboardConfig) {
        $script:DashboardConfig = @{}
    }
        if (-not $script:CollectedMetrics) {
        $script:CollectedMetrics = @{}
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return @{}
        }

        if (-not $ProjectPath) {
            if (Get-Command Get-AitherProjectRoot -ErrorAction SilentlyContinue) {
                $ProjectPath = Get-AitherProjectRoot
            } else {
                $ProjectPath = '.'
            }
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        $script:DashboardConfig = @{
            ProjectPath = $ProjectPath
            OutputPath = $OutputPath
            SessionStart = Get-Date
            Configuration = $Configuration
        }

        # Ensure output directory exists
        if ($OutputPath -and -not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        # Clear previous metrics
        $script:CollectedMetrics = @{}

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Dashboard session initialized: $OutputPath" -Level Information -Source 'Initialize-AitherDashboard'
        }
        return $script:DashboardConfig
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error initializing dashboard session: $($_.Exception.Message)" -Level Error -Source 'Initialize-AitherDashboard' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Error initializing dashboard session: $($_.Exception.Message)" -Source 'Initialize-AitherDashboard' -Exception $_
        }
        throw
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

