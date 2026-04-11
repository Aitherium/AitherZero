#Requires -Version 7.0

<#
.SYNOPSIS
    Save PSSession configuration for later reconnection

.DESCRIPTION
    Saves PSSession configuration (connection details) to configuration storage so you can
    reconnect to the same server later without re-entering credentials. Useful for frequently
    accessed servers and automation scenarios.

.PARAMETER Session
    PSSession object to save configuration from. This parameter is REQUIRED.
    The session's connection details will be extracted and saved.

.PARAMETER Name
    Name identifier for the saved session configuration. This parameter is REQUIRED.
    Use this name later with Connect-AitherPSSession to reconnect.

    Examples:
    - "Production-Server"
    - "Dev-Environment"
    - "Database-Cluster"

.PARAMETER Description
    Optional description of the saved session. Useful for documenting what the session is used for.

.PARAMETER Force
    Overwrite existing saved session configuration with the same name.

.INPUTS
    System.Management.Automation.Runspaces.PSSession
    You can pipe PSSession objects to Save-AitherPSSession.

.OUTPUTS
    PSCustomObject
    Returns saved session configuration object with Name, ComputerName, Port, UseSSH, UseSSL properties.

.EXAMPLE
    $session = New-AitherPSSession -ComputerName "server01" -Credential (Get-Credential)
    Save-AitherPSSession -Session $session -Name "Production"

    Creates a session and saves its configuration as "Production".

.EXAMPLE
    Get-AitherPSSession | Save-AitherPSSession -Name "CurrentSessions"

    Saves all current sessions' configurations.

.EXAMPLE
    Save-AitherPSSession -Session $session -Name "Dev" -Description "Development environment"

    Saves session with a descriptive name and description.

.NOTES
    Saved session configurations are stored in the AitherZero configuration system.
    Credentials are NOT saved - you'll need to provide them again when reconnecting.

    Saved configurations include:
    - ComputerName
    - Port
    - UseSSH flag
    - UseSSL flag
    - ConfigurationName
    - Session name

.LINK
    Connect-AitherPSSession
    Get-AitherPSSession
    New-AitherPSSession
#>
function Save-AitherPSSession {
[OutputType([PSCustomObject])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$false, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [System.Management.Automation.Runspaces.PSSession[]]$Session,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter()]
    [string]$Description,

    [switch]$Force,

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

    if (-not (Test-Path $sessionsConfigPath)) {
        New-Item -Path $sessionsConfigPath -ItemType Directory -Force | Out-Null
    }
}

process {
    try {
        foreach ($sessionToSave in $Session) {
        try {
            $sessionConfig = @{
                Name = $Name
                ComputerName = $sessionToSave.ComputerName
                Port = if ($sessionToSave.Runspace.ConnectionInfo.Port) { $sessionToSave.Runspace.ConnectionInfo.Port } else { 5985 }
                UseSSH = $sessionToSave.Transport -eq 'SSH'
                UseSSL = ($sessionToSave.Runspace.ConnectionInfo -is [System.Management.Automation.Runspaces.WSManConnectionInfo]) -and $sessionToSave.Runspace.ConnectionInfo.Scheme -eq 'https'
                ConfigurationName = $sessionToSave.ConfigurationName
                Description = $Description
                Created = Get-Date
                SessionId = $sessionToSave.Id
            }

            $configFile = Join-Path $sessionsConfigPath "${Name}.json"

            if ((Test-Path $configFile) -and -not $Force) {
                throw "Session configuration '$Name' already exists. Use -Force to overwrite."
            }

            if ($PSCmdlet.ShouldProcess($Name, "Save PSSession configuration")) {
                $sessionConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $configFile -Encoding UTF8 -Force

                Write-AitherLog -Level Information -Message "Saved PSSession configuration: $Name" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data $sessionConfig
                return [PSCustomObject]$sessionConfig
            }
        }
        catch {
            # Use centralized error handling
            $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
            if (Test-Path $errorScript) {
                . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Saving PSSession configuration: $Name" -Parameters $PSBoundParameters -ThrowOnError
            }
            else {
                $errorObject = [PSCustomObject]@{
                    PSTypeName = 'AitherZero.Error'
                    Success = $false
                    ErrorId = [System.Guid]::NewGuid().ToString()
                    Cmdlet = $PSCmdlet.MyInvocation.MyCommand.Name
                    Operation = "Saving PSSession configuration: $Name"
                    Error = $_.Exception.Message
                    Timestamp = Get-Date
                }
                Write-Output $errorObject

                Write-AitherLog -Level Error -Message "Failed to save PSSession configuration $Name : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
            }
            throw
        }
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

