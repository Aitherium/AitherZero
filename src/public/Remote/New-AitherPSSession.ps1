#Requires -Version 7.0

<#
.SYNOPSIS
    Create a PowerShell remoting session to a remote computer

.DESCRIPTION
    Creates a PowerShell remoting session (PSSession) to a remote computer using WinRM
    (Windows Remote Management) or SSH transport. Sessions can be reused for multiple
    commands, making them more efficient than one-off remote commands.

    This cmdlet supports both Windows (WinRM) and Linux/macOS (SSH) targets, making it
    ideal for cross-platform automation scenarios.

.PARAMETER ComputerName
    Target computer name or IP address. This parameter is REQUIRED.

    Examples:
    - "server01.example.com"
    - "192.168.1.100"
    - "server01.example.com,server02.example.com" (multiple computers)

.PARAMETER Credential
    PSCredential object for authentication. This parameter is REQUIRED unless you have
    existing credential access configured.

    Use Get-Credential to create a credential object, or use CredentialName to reference
    a stored credential.

.PARAMETER CredentialName
    Name of a stored credential (if using credential management system).
    Alternative to providing Credential directly.

.PARAMETER UseSSH
    Use SSH transport instead of WinRM. Required for Linux/macOS targets or when SSH
    is preferred over WinRM. When enabled, PowerShell remoting uses SSH as the transport.

.PARAMETER Port
    Port number for the connection. Defaults to:
    - 5985 for WinRM (HTTP)
    - 5986 for WinRM HTTPS (when UseSSL is specified)
    - 22 for SSH

.PARAMETER UseSSL
    Use SSL/TLS for WinRM connection (HTTPS). More secure than plain HTTP WinRM.
    When enabled, uses port 5986 by default.

.PARAMETER SessionName
    Optional name for the session. Useful for identifying sessions when managing multiple connections.

.PARAMETER ConfigurationName
    PowerShell session configuration name. Defaults to "Microsoft.PowerShell" for Windows
    or "PowerShell" for SSH.

.PARAMETER ThrottleLimit
    Maximum number of concurrent operations. Default is 32.

.INPUTS
    System.String
    You can pipe computer names to New-AitherPSSession.

.OUTPUTS
    System.Management.Automation.Runspaces.PSSession
    Returns a PSSession object that can be used with Invoke-Command.

.EXAMPLE
    $session = New-AitherPSSession -ComputerName "server01" -Credential (Get-Credential)

    Creates a WinRM session to server01 using prompted credentials.

.EXAMPLE
    $session = New-AitherPSSession -ComputerName "linux-server" -Credential (Get-Credential) -UseSSH

    Creates an SSH-based session to a Linux server.

.EXAMPLE
    $session = New-AitherPSSession -ComputerName "server01" -CredentialName "DomainAdmin" -UseSSL

    Creates a secure HTTPS WinRM session using a stored credential.

.EXAMPLE
    "server1", "server2", "server3" | New-AitherPSSession -CredentialName "Admin"

    Creates sessions to multiple servers by piping computer names.

.EXAMPLE
    $session = New-AitherPSSession -ComputerName "server01" -Credential (Get-Credential) -SessionName "Production"

    Creates a named session for easier identification.

.NOTES
    Requirements:
    - Windows targets: WinRM must be enabled and configured
    - Linux/macOS targets: SSH server must be running, PowerShell must be installed
    - Appropriate network connectivity and firewall rules

    Security:
    - Always use SSL/TLS (UseSSL) for production WinRM connections
    - Verify host keys when using SSH
    - Use least-privilege credentials
    - Close sessions when done using Remove-AitherPSSession

.LINK
    Get-AitherPSSession
    Remove-AitherPSSession
    Save-AitherPSSession
    Connect-AitherPSSession
    Invoke-AitherRemoteCommand
#>
function New-AitherPSSession {
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Target computer names or IP addresses.")]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [Parameter(HelpMessage = "Credential to use for the connection.")]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(HelpMessage = "Name of a stored credential to use.")]
        [string]$CredentialName,

        [Parameter(HelpMessage = "Use SSH for connection (Linux/macOS targets).")]
        [switch]$UseSSH,

        [Parameter(HelpMessage = "Custom port for the connection.")]
        [int]$Port,

        [Parameter(HelpMessage = "Use SSL/HTTPS for WinRM connection.")]
        [switch]$UseSSL,

        [Parameter(HelpMessage = "Friendly name for the session.")]
        [string]$SessionName,

        [Parameter(HelpMessage = "PowerShell session configuration name.")]
        [string]$ConfigurationName,

        [Parameter(HelpMessage = "Maximum number of concurrent operations.")]
        [int]$ThrottleLimit = 32,

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

        # Get credential if CredentialName provided
        if ($CredentialName -and -not $Credential) {
            try {
                $Credential = Get-AitherCredential -Name $CredentialName
            }
            catch {
                Write-AitherLog -Level Warning -Message "Could not retrieve credential '$CredentialName'. You may need to provide Credential directly." -Source 'New-AitherPSSession' -Exception $_
            }
        }
    }

    process {
        try {
            foreach ($computer in $ComputerName) {
                try {
                    $sessionParams = @{
                        ComputerName  = $computer
                        ThrottleLimit = $ThrottleLimit
                    }
                    if ($Credential) {
                        $sessionParams.Credential = $Credential
                    }
                    if ($UseSSH) {
                        $sessionParams.SSHTransport = $true
                        if ($Port) {
                            $sessionParams.Port = $Port
                        }
                        elseif (-not $Port) {
                            $sessionParams.Port = 22
                        }
                    }
                    else {
                        # WinRM
                        if ($UseSSL) {
                            $sessionParams.UseSSL = $true
                            if ($Port) {
                                $sessionParams.Port = $Port
                            }
                            else {
                                $sessionParams.Port = 5986
                            }
                        }
                        elseif ($Port) {
                            $sessionParams.Port = $Port
                        }
                        else {
                            $sessionParams.Port = 5985
                        }
                    }
                    if ($SessionName) {
                        $sessionParams.Name = $SessionName
                    }
                    if ($ConfigurationName) {
                        $sessionParams.ConfigurationName = $ConfigurationName
                    }
                    if ($PSCmdlet.ShouldProcess($computer, "Create PSSession")) {
                        Write-AitherLog -Level Information -Message "Creating PSSession to $computer" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                            UseSSH = $UseSSH
                            UseSSL = $UseSSL
                            Port   = $sessionParams.Port
                        }

                        $session = New-PSSession @sessionParams -ErrorAction Stop

                        Write-AitherLog -Level Information -Message "PSSession created successfully: $($session.Id)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Data @{
                            SessionId    = $session.Id
                            ComputerName = $session.ComputerName
                            State        = $session.State
                        }

                        Write-Output $session
                    }
                }
                catch {
                    # Use centralized error handling
                    $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
                    if (Test-Path $errorScript) {
                        . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Creating PSSession to $computer" -Parameters $PSBoundParameters -ErrorAction Continue
                    }
                    else {
                        # Fallback error handling
                        $errorObject = [PSCustomObject]@{
                            PSTypeName   = 'AitherZero.Error'
                            Success      = $false
                            ErrorId      = [System.Guid]::NewGuid().ToString()
                            Cmdlet       = $PSCmdlet.MyInvocation.MyCommand.Name
                            Operation    = "Creating PSSession to $computer"
                            Error        = $_.Exception.Message
                            ComputerName = $computer
                            Timestamp    = Get-Date
                        }
                        Write-Output $errorObject

                        Write-AitherLog -Level Error -Message "Failed to create PSSession to $computer : $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
                    }

                    # Continue with next computer instead of throwing
                    Write-AitherLog -Level Error -Message "Failed to create session to $computer : $_" -Source 'New-AitherPSSession' -Exception $_
                }
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

