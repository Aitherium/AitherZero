#Requires -Version 7.0

<#
.SYNOPSIS
    Create a new AitherOS Hyper-V compute node on a remote Windows Server host.

.DESCRIPTION
    Convenience wrapper that combines host preparation and node deployment into a 
    single cmdlet optimized for Hyper-V Server Core hosts.

    Equivalent to:
      3100_Setup-HyperVHost.ps1 + 3101_Deploy-RemoteNode.ps1

    But as a proper PowerShell cmdlet with pipeline support and credential management.

.PARAMETER ComputerName
    Target server hostname or IP.

.PARAMETER Credential
    PSCredential for authentication.

.PARAMETER CredentialName
    Stored credential name.

.PARAMETER UseSSH
    Use SSH transport.

.PARAMETER GPU
    Enable GPU passthrough.

.PARAMETER VirtualSwitchName
    Name for the Hyper-V virtual switch. Default: AitherSwitch.

.PARAMETER Profile
    Service profile. Default: core.

.PARAMETER FailoverPriority
    Failover priority (1=highest). Default: 10.

.PARAMETER SkipHyperV
    Skip Hyper-V role installation.

.PARAMETER SkipDocker
    Skip Docker installation.

.PARAMETER DryRun
    Preview mode.

.PARAMETER PassThru
    Return result object.

.INPUTS
    System.String — Computer names.

.OUTPUTS
    PSCustomObject — Setup result.

.EXAMPLE
    New-AitherHyperVNode -ComputerName "lab-server"

.EXAMPLE
    New-AitherHyperVNode -ComputerName "192.168.1.50" -GPU -FailoverPriority 1

.NOTES
    Part of AitherZero module — Deployment category.
#>
function New-AitherHyperVNode {
    [OutputType([PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [PSCredential]$Credential,
        [string]$CredentialName,
        [switch]$UseSSH,
        [switch]$GPU,

        [string]$VirtualSwitchName = "AitherSwitch",

        [ValidateSet("minimal", "core", "gpu", "dashboard", "all")]
        [string]$Profile = "core",

        [ValidateRange(1, 100)]
        [int]$FailoverPriority = 10,

        [string]$CoreUrl,
        [string]$MeshToken,

        [switch]$SkipHyperV,
        [switch]$SkipDocker,
        [switch]$DryRun,
        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        # Resolve credential
        if ($CredentialName -and -not $Credential) {
            try {
                $Credential = Get-AitherCredential -Name $CredentialName -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not retrieve credential '$CredentialName'"
            }
        }
    }

    process {
        foreach ($target in $ComputerName) {
            if (-not $PSCmdlet.ShouldProcess($target, "Create Hyper-V Node")) { continue }

            # Delegate to the Elysium deployer
            $params = @{
                ComputerName     = $target
                Profile          = $Profile
                FailoverPriority = $FailoverPriority
                GPU              = $GPU
                PassThru         = $true
            }
            if ($Credential) { $params.Credential = $Credential }
            if ($UseSSH)     { $params.UseSSH = $true }
            if ($CoreUrl)    { $params.CoreUrl = $CoreUrl }
            if ($MeshToken)  { $params.MeshToken = $MeshToken }
            if ($Force)      { $params.Force = $true }
            if ($DryRun)     { $params.DryRun = $true }

            $result = Invoke-AitherElysiumDeploy @params

            if ($PassThru) {
                $result
            }
        }
    }
}
