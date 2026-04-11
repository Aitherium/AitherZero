<#
.SYNOPSIS
    Generates a Dockerfile for a project.

.DESCRIPTION
    Scaffolds a Dockerfile based on the project type using New-AitherDockerfile.

.PARAMETER Type
    The project type (Node, Python, PowerShell, Go, Static).

.PARAMETER Destination
    Directory to save the Dockerfile. Default: current directory.

.EXAMPLE
    ./0310_Generate-Dockerfile.ps1 -Type Node

.NOTES
    Script Number: 0310
    Author: AitherZero
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Node', 'Python', 'PowerShell', 'Go', 'Static')]
    [string]$Type,

    [Parameter(Mandatory = $false)]
    [string]$Destination = '.'
)

try {
    Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction Stop

    Write-Host "Generating $Type Dockerfile in $Destination..." -ForegroundColor Cyan
    
    # Note: Assuming New-AitherDockerfile supports these parameters based on public functions
    New-AitherDockerfile -ProjectType $Type -OutputPath $Destination
    
    Write-Host "Dockerfile created successfully." -ForegroundColor Green
}
catch {
    Write-Error "Dockerfile generation failed: $_"
    exit 1
}
