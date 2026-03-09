#Requires -Version 7.0

<#
.SYNOPSIS
    Deploy or manage an AitherNode on a remote host via the Elysium pipeline.

.DESCRIPTION
    Wrapper for the AitherZero agent and MCP tools to deploy AitherNode instances
    to remote hosts. Supports the full lifecycle: bootstrap, deploy, verify, 
    configure replication, and start watchdog.

    This is the "quick deploy" command — for full customization, use 
    Invoke-AitherElysiumDeploy directly.

.PARAMETER ComputerName
    Target hostname or IP address.

.PARAMETER Action
    Deployment action: Deploy (full pipeline), Status, Update, Restart, Remove.

.PARAMETER Credential
    PSCredential for authentication.

.PARAMETER CredentialName
    Stored credential name from AitherZero vault.

.PARAMETER Profile
    Service profile: minimal, core (default), gpu, dashboard, all.

.PARAMETER SkipBootstrap
    Skip OS-level setup (host already prepared).

.PARAMETER SkipReplication
    Skip database replication configuration.

.PARAMETER GPU
    Enable GPU passthrough.

.PARAMETER FailoverPriority
    Failover priority (1=highest). Default: 10.

.PARAMETER StartWatchdog
    Start failover watchdog after deployment.

.PARAMETER DryRun
    Preview mode — show what would be done.

.PARAMETER PassThru
    Return result objects.

.INPUTS
    System.String — Computer names via pipeline.

.OUTPUTS
    PSCustomObject — Deployment result.

.EXAMPLE
    Invoke-AitherNodeDeploy -ComputerName "lab-server" -Credential (Get-Credential)
    Full end-to-end deployment.

.EXAMPLE
    Invoke-AitherNodeDeploy -ComputerName "192.168.1.50" -Action Status
    Check deployment status on a remote host.

.EXAMPLE
    Invoke-AitherNodeDeploy -ComputerName "lab" -SkipBootstrap -GPU -StartWatchdog
    Deploy to a pre-configured host with GPU support and watchdog.

.NOTES
    Part of AitherZero module — Infrastructure category.
    Delegates to: Invoke-AitherElysiumDeploy, 3101, 3103, 3104 automation scripts.
#>
function Invoke-AitherNodeDeploy {
    [OutputType([PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [ValidateSet("Deploy", "Status", "Update", "Restart", "Remove")]
        [string]$Action = "Deploy",

        [PSCredential]$Credential,
        [string]$CredentialName,

        [ValidateSet("minimal", "core", "gpu", "dashboard", "all")]
        [string]$Profile = "core",

        [switch]$SkipBootstrap,
        [switch]$SkipReplication,
        [switch]$GPU,

        [ValidateRange(1, 100)]
        [int]$FailoverPriority = 10,

        [switch]$StartWatchdog,
        [switch]$DryRun,
        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        $results = @()
        $projectRoot = $null

        # Locate project root
        $searchDir = $PSScriptRoot
        while ($searchDir) {
            if (Test-Path (Join-Path $searchDir ".." ".." "AitherZero.psd1")) {
                $projectRoot = (Resolve-Path (Join-Path $searchDir ".." "..")).Path
                break
            }
            $parent = Split-Path $searchDir -Parent
            if ($parent -eq $searchDir) { break }
            $searchDir = $parent
        }
        if (-not $projectRoot -and $env:AITHERZERO_ROOT) {
            $projectRoot = $env:AITHERZERO_ROOT
        }
        if (-not $projectRoot) {
            $projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        }

        # Resolve credential
        if ($CredentialName -and -not $Credential) {
            try {
                $Credential = Get-AitherCredential -Name $CredentialName -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not retrieve credential '$CredentialName': $($_.Exception.Message)"
            }
        }
    }

    process {
        foreach ($target in $ComputerName) {
            if (-not $PSCmdlet.ShouldProcess($target, "$Action AitherNode")) { continue }

            switch ($Action) {
                "Deploy" {
                    # Full deployment via Elysium pipeline
                    $deployParams = @{
                        ComputerName     = $target
                        Profile          = $Profile
                        FailoverPriority = $FailoverPriority
                        GPU              = $GPU
                        StartWatchdog    = $StartWatchdog
                        PassThru         = $true
                    }
                    if ($Credential)     { $deployParams.Credential = $Credential }
                    if ($SkipBootstrap)  { $deployParams.SkipBootstrap = $true }
                    if ($DryRun)         { $deployParams.DryRun = $true }
                    if ($Force)          { $deployParams.Force = $true }

                    try {
                        $result = Invoke-AitherElysiumDeploy @deployParams
                    }
                    catch {
                        $result = [PSCustomObject]@{
                            ComputerName = $target
                            Action       = 'Deploy'
                            Status       = 'Failed'
                            Error        = $_.Exception.Message
                        }
                    }

                    # Configure replication if not skipped
                    if (-not $SkipReplication -and -not $DryRun -and $result.Status -ne 'Failed') {
                        Write-Host "  Configuring database replication for $target..." -ForegroundColor Cyan
                        $replScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "31-remote" "3104_Setup-DatabaseReplication.ps1"
                        if (Test-Path $replScript) {
                            try {
                                $replParams = @{
                                    NodeHost  = $target
                                    Force     = $true
                                }
                                if ($Credential) { $replParams.Credential = $Credential }
                                & $replScript @replParams
                            }
                            catch {
                                Write-Warning "Replication setup failed: $($_.Exception.Message)"
                            }
                        }
                    }

                    $results += $result
                }

                "Status" {
                    # Check status on remote host
                    $result = [PSCustomObject]@{
                        ComputerName = $target
                        Action       = 'Status'
                        Status       = 'Unknown'
                        Containers   = @()
                        MeshJoined   = $false
                    }

                    try {
                        if ($Credential) {
                            $containers = Invoke-Command -ComputerName $target -Credential $Credential -ScriptBlock {
                                docker ps --filter "name=aitheros" --format "{{.Names}}|{{.Status}}" 2>&1
                            }
                        }
                        else {
                            $containers = Invoke-Command -ComputerName $target -ScriptBlock {
                                docker ps --filter "name=aitheros" --format "{{.Names}}|{{.Status}}" 2>&1
                            }
                        }

                        $result.Containers = $containers | ForEach-Object {
                            $parts = $_ -split '\|'
                            [PSCustomObject]@{ Name = $parts[0]; Status = $parts[1] }
                        }
                        $result.Status = if ($result.Containers.Count -gt 0) { 'Running' } else { 'Stopped' }

                        # Check mesh
                        try {
                            $meshCheck = Invoke-RestMethod -Uri "http://${target}:8125/mesh/status" -TimeoutSec 5 -ErrorAction Stop
                            $result.MeshJoined = $true
                        }
                        catch { $result.MeshJoined = $false }
                    }
                    catch {
                        $result.Status = 'Unreachable'
                        $result | Add-Member -NotePropertyName Error -NotePropertyValue $_.Exception.Message
                    }

                    $results += $result
                }

                "Update" {
                    # Rolling update via fleet manager
                    $fleetScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "31-remote" "3103_Manage-NodeFleet.ps1"
                    if (Test-Path $fleetScript) {
                        $fleetParams = @{
                            Action       = "Update"
                            ComputerName = $target
                            PassThru     = $true
                        }
                        if ($Credential) { $fleetParams.Credential = $Credential }
                        if ($Force)      { $fleetParams.Force = $true }
                        $results += & $fleetScript @fleetParams
                    }
                    else {
                        $results += [PSCustomObject]@{ ComputerName = $target; Action = 'Update'; Status = 'ScriptNotFound' }
                    }
                }

                "Restart" {
                    # Restart all containers on remote node
                    try {
                        $sb = { docker compose -f /opt/aitheros/docker-compose.node.yml restart 2>&1 }
                        if ($Credential) {
                            Invoke-Command -ComputerName $target -Credential $Credential -ScriptBlock $sb
                        }
                        else {
                            Invoke-Command -ComputerName $target -ScriptBlock $sb
                        }
                        $results += [PSCustomObject]@{ ComputerName = $target; Action = 'Restart'; Status = 'Success' }
                    }
                    catch {
                        $results += [PSCustomObject]@{ ComputerName = $target; Action = 'Restart'; Status = 'Failed'; Error = $_.Exception.Message }
                    }
                }

                "Remove" {
                    # Remove node from mesh and stop containers
                    try {
                        # Leave mesh first
                        try {
                            Invoke-RestMethod -Uri "http://localhost:8125/mesh/nodes/$target" -Method DELETE -TimeoutSec 10 -ErrorAction Stop
                        }
                        catch { Write-Verbose "Mesh removal: $($_.Exception.Message)" }

                        # Stop containers on remote
                        $sb = { docker compose -f /opt/aitheros/docker-compose.node.yml down 2>&1 }
                        if ($Credential) {
                            Invoke-Command -ComputerName $target -Credential $Credential -ScriptBlock $sb
                        }
                        else {
                            Invoke-Command -ComputerName $target -ScriptBlock $sb
                        }
                        $results += [PSCustomObject]@{ ComputerName = $target; Action = 'Remove'; Status = 'Removed' }
                    }
                    catch {
                        $results += [PSCustomObject]@{ ComputerName = $target; Action = 'Remove'; Status = 'Failed'; Error = $_.Exception.Message }
                    }
                }
            }
        }
    }

    end {
        if ($PassThru) {
            if ($results.Count -eq 1) { return $results[0] }
            return $results
        }

        # Display summary
        foreach ($r in $results) {
            $icon = switch -Wildcard ($r.Status) {
                'Success*'  { '✓' }
                'Running'   { '✓' }
                'Failed'    { '✗' }
                'DryRun'    { '→' }
                default     { '○' }
            }
            $color = switch -Wildcard ($r.Status) {
                'Success*'  { 'Green' }
                'Running'   { 'Green' }
                'Failed'    { 'Red' }
                'DryRun'    { 'DarkGray' }
                default     { 'Yellow' }
            }
            Write-Host "  $icon $($r.ComputerName) — $($r.Action): $($r.Status)" -ForegroundColor $color
        }
    }
}
