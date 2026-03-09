#Requires -Version 7.0

<#
.SYNOPSIS
    Connect to a saved PSSession configuration

.DESCRIPTION
    Reconnects to a remote server using a previously saved PSSession configuration.
    Loads connection details from saved configuration and creates a new session.

    This is convenient for frequently accessed servers - save the configuration once,
    then reconnect easily without remembering all the connection details.

.PARAMETER Name
    Name of the saved session configuration. This parameter is REQUIRED.
    Use Save-AitherPSSession to create saved configurations.

.PARAMETER Credential
    PSCredential object for authentication. This parameter is REQUIRED.
    Credentials are not saved, so you must provide them each time you connect.

.PARAMETER CredentialName
    Name of a stored credential to use. Alternative to providing Credential directly.

.INPUTS
    System.String
    You can pipe saved session names to Connect-AitherPSSession.

.OUTPUTS
    System.Management.Automation.Runspaces.PSSession
    Returns a PSSession object connected to the remote server.

.EXAMPLE
    Connect-AitherPSSession -Name "Production" -Credential (Get-Credential)

    Reconnects to the "Production" server using saved configuration and prompted credentials.

.EXAMPLE
    Connect-AitherPSSession -Name "Dev" -CredentialName "DevAdmin"

    Reconnects using a stored credential name.

.EXAMPLE
    "Production", "Staging" | Connect-AitherPSSession -CredentialName "Admin"

    Connects to multiple saved sessions by piping session names.

.NOTES
    Saved session configurations are stored in library/saved-sessions/ directory.
    Each configuration is a JSON file containing connection details (but not credentials).

.LINK
    Save-AitherPSSession
    New-AitherPSSession
    Get-AitherPSSession
#>
function Connect-AitherPSSession {
[OutputType([System.Management.Automation.Runspaces.PSSession])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$CredentialName,

    [switch]$ShowOutput
)

begin {
    # Save original log targets
    $originalLogTargets = $script:AitherLogTargets

    # Set log targets based on ShowOutput parameter
    if ($ShowOutput) {
        # Ensure Console is in the log targets
        if ($script:AitherLogTargets -notcontains 'Console') {
            $script:AitherLogTargets += 'Console'
        }
    }
    else {
        # Remove Console from log targets if present (default behavior)
        if ($script:AitherLogTargets -contains 'Console') {
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    $moduleRoot = Get-AitherModuleRoot
    $sessionsConfigPath = Join-Path $moduleRoot 'library' 'saved-sessions'
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and -not $Name) {
            return $null
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        # Get credential if CredentialName provided
        if ($CredentialName -and -not $Credential) {
            try {
                if (Get-Command Get-AitherCredential -ErrorAction SilentlyContinue) {
                    $Credential = Get-AitherCredential -Name $CredentialName
                }
            }
    catch {
                Write-AitherLog -Level Warning -Message "Could not retrieve credential '$CredentialName'. You may need to provide Credential directly." -Source 'Connect-AitherPSSession' -Exception $_
            }
        }
        if (-not $Credential) {
            throw "Credential or CredentialName must be provided. Credentials are not saved for security reasons."
        }

        # Load saved configuration
        $configFile = Join-Path $sessionsConfigPath "${Name}.json"

        if (-not (Test-Path $configFile)) {
            throw "Saved session configuration not found: $Name. Use Save-AitherPSSession to create it first."
        }

        $sessionConfig = Get-Content -Path $configFile -Raw | ConvertFrom-Json

        # Build session parameters
        $sessionParams = @{
            ComputerName = $sessionConfig.ComputerName
            Credential = $Credential
        }
        if ($sessionConfig.UseSSH) {
            $sessionParams.SSHTransport = $true
            if ($sessionConfig.Port) {
                $sessionParams.Port = $sessionConfig.Port
            }
        }
        else {
            if ($sessionConfig.UseSSL) {
                $sessionParams.UseSSL = $true
            }
            if ($sessionConfig.Port) {
                $sessionParams.Port = $sessionConfig.Port
            }
        }
        if ($sessionConfig.ConfigurationName) {
            $sessionParams.ConfigurationName = $sessionConfig.ConfigurationName
        }
        if ($sessionConfig.Name) {
            $sessionParams.Name = $sessionConfig.Name
        }
        if ($PSCmdlet.ShouldProcess($sessionConfig.ComputerName, "Connect to saved session: $Name")) {
            Write-AitherLog -Level Information -Message "Connecting to saved session: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                ComputerName = $sessionConfig.ComputerName
                UseSSH = $sessionConfig.UseSSH
            }

            $session = New-PSSession @sessionParams -ErrorAction Stop

            Write-AitherLog -Level Information -Message "Connected to saved session: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                SessionId = $session.Id
                ComputerName = $session.ComputerName
            }

            return $session
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Connecting to saved session: $Name" -Parameters $PSBoundParameters -ThrowOnError
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}


}

