#Requires -Version 7.0

<#
.SYNOPSIS
    Create a new playbook interactively or from parameters

.DESCRIPTION
    Creates a new playbook definition. Can be used interactively or with parameters.

.PARAMETER Name
    Name of the playbook

.PARAMETER Description
    Description of what the playbook does

.PARAMETER Scripts
    Script numbers or names to include in the playbook

.PARAMETER Interactive
    Launch interactive playbook creation wizard

.EXAMPLE
    New-AitherPlaybook -Name 'deploy' -Description 'Deployment playbook' -Scripts @('0300', '0900')

.EXAMPLE
    New-AitherPlaybook -Interactive

.NOTES
    This is a convenience function that calls Save-AitherPlaybook.
#>
function New-AitherPlaybook {
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(ParameterSetName = 'Quick', Mandatory)]
    [string]$Name,

    [Parameter(ParameterSetName = 'Quick')]
    [string]$Description = '',

    [Parameter(ParameterSetName = 'Quick')]
    [string[]]$Scripts = @(),

    [Parameter(ParameterSetName = 'Interactive')]
    [switch]$Interactive,

    [switch]$ShowOutput
)

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Name -and -not $Interactive) {
            return
        }

        # Check if Save-AitherPlaybook is available
        if (-not (Get-Command Save-AitherPlaybook -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Save-AitherPlaybook is not available. Cannot create playbook." -Source 'New-AitherPlaybook'
            return
        }

        if ($Interactive) {
            Write-AitherLog -Level Information -Message "=== Create New Playbook ===" -Source 'New-AitherPlaybook'

            $Name = Read-Host "Playbook name"
            if ([string]::IsNullOrWhiteSpace($Name)) {
                throw "Playbook name is required"
            }

            $Description = Read-Host "Description (optional)"

            Write-AitherLog -Level Information -Message "Enter script numbers (one per line, empty line to finish):" -Source 'New-AitherPlaybook'
            $Scripts = @()
            while ($true) {
                $script = Read-Host "Script number"
                if ([string]::IsNullOrWhiteSpace($script)) {
                    break
                }
                $Scripts += $script
            }

            Write-AitherLog -Level Information -Message "Parallel execution? (Y/N): " -Source 'New-AitherPlaybook'
            $parallelInput = Read-Host
            $parallel = $parallelInput -match '^[Yy]'

            $playbook = @{
                Name = $Name
                Description = $Description
                Sequence = $Scripts
                Options = @{
                    Parallel = $parallel
                }
            }

            Save-AitherPlaybook -Playbook $playbook -Force -ShowOutput:$ShowOutput
        }
        else {
            $playbook = @{
                Name = $Name
                Description = $Description
                Sequence = $Scripts
            }

            Save-AitherPlaybook -Playbook $playbook -Force -ShowOutput:$ShowOutput
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Creating playbook" -Parameters $PSBoundParameters -ThrowOnError
    }
}

}

