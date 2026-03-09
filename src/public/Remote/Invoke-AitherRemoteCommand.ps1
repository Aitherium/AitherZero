#Requires -Version 7.0

<#
.SYNOPSIS
    Execute a command on a remote computer using stored credentials

.DESCRIPTION
    Executes a PowerShell script block on a remote computer using stored credentials.
    This is a convenience wrapper that creates a session, runs the command, and cleans up
    automatically - perfect for one-off remote commands.

    Supports both Windows (WinRM) and Linux/macOS (SSH) targets.

.PARAMETER ComputerName
    Target computer name or IP address. This parameter is REQUIRED.

    You can specify multiple computers to run the command on all of them.

.PARAMETER Credential
    PSCredential object for authentication. This parameter is REQUIRED unless CredentialName
    is provided.

.PARAMETER CredentialName
    Name of a stored credential to use. Alternative to providing Credential directly.

.PARAMETER ScriptBlock
    PowerShell script block to execute on the remote computer. This parameter is REQUIRED.

    Example: { Get-Service | Where-Object Status -eq 'Running' }
    Example: { Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 }

.PARAMETER UseSSH
    Use SSH transport instead of WinRM. Required for Linux/macOS targets.

.PARAMETER UseSSL
    Use SSL/TLS for WinRM connection (more secure).

.PARAMETER Port
    Port number for the connection. Defaults to 5985 (WinRM), 5986 (WinRM HTTPS), or 22 (SSH).

.PARAMETER AsJob
    Run the command as a background job. Useful for long-running commands.

.INPUTS
    System.String
    You can pipe computer names to Invoke-AitherRemoteCommand.

.OUTPUTS
    System.Object
    Returns the output from the remote script block execution.

    When -AsJob is used, returns System.Management.Automation.Job objects.

.EXAMPLE
    Invoke-AitherRemoteCommand -ComputerName "server01" -Credential (Get-Credential) -ScriptBlock { Get-Service | Where-Object Status -eq 'Running' }

    Gets running services on server01.

.EXAMPLE
    Invoke-AitherRemoteCommand -ComputerName "server01" -CredentialName "Admin" -ScriptBlock { Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 }

    Gets top 10 CPU processes using a stored credential.

.EXAMPLE
    $servers = "web01", "web02", "web03"
    $servers | Invoke-AitherRemoteCommand -CredentialName "Deploy" -ScriptBlock {
        Stop-Service MyApp
        Copy-Item \\share\release\*.* C:\App\
        Start-Service MyApp
    }

    Deploys to multiple servers by piping computer names.

.EXAMPLE
    Invoke-AitherRemoteCommand -ComputerName "linux-server" -Credential (Get-Credential) -UseSSH -ScriptBlock { uname -a }

    Runs a command on a Linux server using SSH.

.EXAMPLE
    Invoke-AitherRemoteCommand -ComputerName "server01" -CredentialName "Admin" -ScriptBlock { Get-EventLog -LogName Application -Newest 100 } -AsJob

    Runs a long-running command as a background job.

.NOTES
    This cmdlet automatically:
    - Creates a PSSession
    - Executes the script block
    - Closes the session when done

    For multiple commands to the same server, consider creating a session with New-AitherPSSession
    and reusing it for better performance.

.LINK
    New-AitherPSSession
    Invoke-Command
#>
function Invoke-AitherRemoteCommand {
    [OutputType([System.Object], [System.Management.Automation.Job])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Target computer names or IP addresses.")]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [Parameter(HelpMessage = "Credential to use for the connection.")]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(HelpMessage = "Name of a stored credential to use.")]
        [string]$CredentialName,

        [Parameter(Mandatory = $false, Position = 1, HelpMessage = "Script block to execute on the remote computer.")]
        [ValidateNotNull()]
        [System.Management.Automation.ScriptBlock]$ScriptBlock,

        [Parameter(HelpMessage = "Use SSH for connection (Linux/macOS targets).")]
        [switch]$UseSSH,

        [Parameter(HelpMessage = "Use SSL/HTTPS for WinRM connection.")]
        [switch]$UseSSL,

        [Parameter(HelpMessage = "Custom port for the connection.")]
        [int]$Port,

        [Parameter(HelpMessage = "Run the command as a background job.")]
        [switch]$AsJob,

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
                Write-AitherLog -Level Warning -Message "Could not retrieve credential '$CredentialName'. You may need to provide Credential directly." -Source 'Invoke-AitherRemoteCommand' -Exception $_
            }
        }
    }

    process {
        foreach ($computer in $ComputerName) {
            $session = $null
            try {
                # Create session
                $sessionParams = @{
                    ComputerName = $computer
                }

                if ($Credential) {
                    $sessionParams.Credential = $Credential
                }

                if ($UseSSH) {
                    $sessionParams.UseSSH = $true
                    if ($Port) {
                        $sessionParams.Port = $Port
                    }
                }
                else {
                    if ($UseSSL) {
                        $sessionParams.UseSSL = $true
                    }
                    if ($Port) {
                        $sessionParams.Port = $Port
                    }
                }

                $session = New-AitherPSSession @sessionParams

                # Execute command
                if ($AsJob) {
                    $job = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -AsJob -ErrorAction Stop
                    return $job
                }
                else {
                    $result = Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ErrorAction Stop

                    if ($ShowOutput) {
                        $result | ForEach-Object { Write-AitherLog -Level Information -Message $_ -Source 'Invoke-AitherRemoteCommand' }
                    }

                    return $result
                }
            }
            catch {
                Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Executing remote command on $computer" -Parameters $PSBoundParameters -ThrowOnError
            }
            finally {
                if ($session) {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
                # Restore original log targets
                $script:AitherLogTargets = $originalLogTargets
            }
        }
    }

}

