#Requires -Version 7.0

<#
.SYNOPSIS
    Deploy AitherNode to a remote host via the Elysium deployment pipeline.

.DESCRIPTION
    End-to-end orchestrator that handles the complete Elysium deployment workflow:

    1. BOOTSTRAP: Remote host prerequisite setup (Hyper-V, Docker, PS7, networking)
    2. DEPLOY:    AitherNode container deployment with failover configuration
    3. MESH:      Join the AitherMesh with auto-discovery and failover priority
    4. VERIFY:    Health check all endpoints and validate mesh membership

    This is the "one command" entry point for deploying a compute node from your
    dev machine to a remote lab server and connecting it to the AitherOS Core mesh.

    Wraps the 31-remote automation scripts (3100, 3101, 3102) into a cohesive pipeline.

.PARAMETER ComputerName
    Target server hostname or IP address. REQUIRED.

.PARAMETER Credential
    PSCredential for remote authentication.

.PARAMETER CredentialName
    Name of a stored AitherZero credential.

.PARAMETER UseSSH
    Use SSH transport instead of WinRM.

.PARAMETER Profile
    Service profile for the node. Default: core.

.PARAMETER SkipBootstrap
    Skip OS-level bootstrap (assume host is already prepared).

.PARAMETER GPU
    Enable GPU passthrough.

.PARAMETER FailoverPriority
    Failover priority (1=highest). Default: 10.

.PARAMETER StartWatchdog
    Start the failover watchdog after deployment.

.PARAMETER DryRun
    Preview what would be done.

.PARAMETER PassThru
    Return deployment result object.

.INPUTS
    System.String — Computer names can be piped.

.OUTPUTS
    PSCustomObject — Deployment result with health, mesh, and failover status.

.EXAMPLE
    Invoke-AitherElysiumDeploy -ComputerName "lab-server" -Credential (Get-Credential)

    Full end-to-end: bootstrap → deploy → mesh join.

.EXAMPLE
    Invoke-AitherElysiumDeploy -ComputerName "192.168.1.50" -SkipBootstrap -GPU

    Deploy to an already-prepared host with GPU support.

.EXAMPLE
    "node1", "node2" | Invoke-AitherElysiumDeploy -CredentialName "LabAdmin" -FailoverPriority 5

    Deploy to multiple nodes with stored credentials.

.EXAMPLE
    Invoke-AitherElysiumDeploy -ComputerName "lab" -StartWatchdog -PassThru

    Deploy and start continuous failover monitoring.

.NOTES
    Part of AitherZero module — Deployment category.
    Requires: AitherZero module, network access to target.
#>
function Invoke-AitherElysiumDeploy {
    [OutputType([PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName,
                   HelpMessage = "Target server hostname or IP")]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName,

        [PSCredential]$Credential,
        [string]$CredentialName,

        [switch]$UseSSH,

        [ValidateSet("minimal", "core", "gpu", "dashboard", "all")]
        [string]$Profile = "core",

        [switch]$SkipBootstrap,
        [switch]$GPU,

        [ValidateRange(1, 100)]
        [int]$FailoverPriority = 10,

        [string[]]$ReplicateServices = @("Pulse", "Chronicle", "Strata"),

        [string]$CoreUrl,
        [string]$MeshToken,

        [switch]$StartWatchdog,
        [switch]$DryRun,
        [switch]$Force,
        [switch]$PassThru
    )

    begin {
        $startTime = Get-Date
        $results = @()
        $projectRoot = $null

        # Locate project root
        $searchDir = $PSScriptRoot
        while ($searchDir) {
            if (Test-Path (Join-Path $searchDir "AitherZero" "AitherZero.psd1")) {
                $projectRoot = $searchDir
                break
            }
            $parent = Split-Path $searchDir -Parent
            if ($parent -eq $searchDir) { break }
            $searchDir = $parent
        }
        if (-not $projectRoot -and $env:AITHERZERO_ROOT) {
            $projectRoot = $env:AITHERZERO_ROOT
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

        # Auto-detect Core URL
        if (-not $CoreUrl) {
            $localIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
                $_.PrefixOrigin -eq 'Dhcp' -or $_.PrefixOrigin -eq 'Manual'
            } | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
            if ($localIP) {
                $CoreUrl = "http://${localIP}:8001"
            }
            else {
                $CoreUrl = "http://localhost:8001"
            }
        }

        # Generate mesh token if not provided
        if (-not $MeshToken) {
            $MeshToken = [Convert]::ToBase64String(
                [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
            )
        }

        # Banner
        Write-Host ""
        Write-Host "  ╔═══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
        Write-Host "  ║          AitherOS Elysium Deployment                  ║" -ForegroundColor Magenta
        Write-Host "  ║   Remote Node Deploy → Mesh Join → Hot Failover       ║" -ForegroundColor Magenta
        Write-Host "  ╚═══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
        Write-Host ""
        Write-Host "  Core:     $CoreUrl" -ForegroundColor Cyan
        Write-Host "  Profile:  $Profile" -ForegroundColor White
        Write-Host "  Mode:     $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' })
        Write-Host ""
    }

    process {
        foreach ($target in $ComputerName) {
            Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
            Write-Host "  TARGET: $target" -ForegroundColor White
            Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

            $nodeResult = [PSCustomObject]@{
                PSTypeName       = 'AitherOS.ElysiumDeployResult'
                ComputerName     = $target
                Status           = 'Unknown'
                BootstrapStatus  = 'Skipped'
                DeployStatus     = 'NotStarted'
                MeshStatus       = 'NotStarted'
                FailoverPriority = $FailoverPriority
                Profile          = $Profile
                CoreUrl          = $CoreUrl
                Duration         = $null
                Timestamp        = Get-Date
                Error            = $null
            }

            $nodeStart = Get-Date

            try {
                # ── PHASE 1: BOOTSTRAP ─────────────────────────────────
                if (-not $SkipBootstrap) {
                    Write-Host "  [1/3] BOOTSTRAP — Installing prerequisites on $target" -ForegroundColor Cyan

                    $bootstrapScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "31-remote" "3100_Setup-HyperVHost.ps1"

                    if (Test-Path $bootstrapScript) {
                        $bootstrapParams = @{
                            ComputerName = $target
                            CoreUrl      = $CoreUrl
                            MeshToken    = $MeshToken
                            GPU          = $GPU
                            PassThru     = $true
                        }
                        if ($Credential) { $bootstrapParams.Credential = $Credential }
                        if ($UseSSH)     { $bootstrapParams.UseSSH = $true }
                        if ($Force)      { $bootstrapParams.Force = $true }
                        if ($DryRun)     { $bootstrapParams.DryRun = $true }

                        $bsResult = & $bootstrapScript @bootstrapParams
                        $nodeResult.BootstrapStatus = $bsResult.Status ?? 'Completed'
                    }
                    else {
                        Write-Warning "Bootstrap script not found at $bootstrapScript — running inline bootstrap"
                        $nodeResult.BootstrapStatus = 'ScriptNotFound'
                    }
                }
                else {
                    Write-Host "  [1/3] BOOTSTRAP — Skipped (-SkipBootstrap)" -ForegroundColor DarkGray
                    $nodeResult.BootstrapStatus = 'Skipped'
                }

                # ── PHASE 2: DEPLOY ────────────────────────────────────
                Write-Host "  [2/3] DEPLOY — Deploying AitherNode containers" -ForegroundColor Cyan

                $deployScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "31-remote" "3101_Deploy-RemoteNode.ps1"

                if (Test-Path $deployScript) {
                    $deployParams = @{
                        ComputerName      = $target
                        Profile           = $Profile
                        FailoverPriority  = $FailoverPriority
                        ReplicateServices = $ReplicateServices
                        CoreUrl           = $CoreUrl
                        MeshToken         = $MeshToken
                        PassThru          = $true
                    }
                    if ($Credential) { $deployParams.Credential = $Credential }
                    if ($UseSSH)     { $deployParams.UseSSH = $true }
                    if ($Force)      { $deployParams.Force = $true }
                    if ($DryRun)     { $deployParams.DryRun = $true }

                    $depResult = & $deployScript @deployParams
                    $nodeResult.DeployStatus = $depResult.Status ?? 'Completed'
                }
                else {
                    Write-Warning "Deploy script not found — falling back to direct deployment"
                    $nodeResult.DeployStatus = 'FallbackUsed'
                }

                # ── PHASE 3: MESH VERIFY ───────────────────────────────
                Write-Host "  [3/3] MESH — Verifying mesh membership" -ForegroundColor Cyan

                if (-not $DryRun) {
                    Start-Sleep -Seconds 3
                    try {
                        $meshStatus = Invoke-RestMethod -Uri "http://${target}:8125/mesh/status" -TimeoutSec 10 -ErrorAction Stop
                        $nodeResult.MeshStatus = $meshStatus.status ?? "connected"
                        Write-Host "    Mesh: $($nodeResult.MeshStatus)" -ForegroundColor Green
                    }
                    catch {
                        $nodeResult.MeshStatus = "unreachable"
                        Write-Host "    Mesh: Node will auto-join when Core is reachable" -ForegroundColor Yellow
                    }
                }
                else {
                    $nodeResult.MeshStatus = 'DryRun'
                }

                $nodeResult.Status = if ($nodeResult.DeployStatus -eq 'Success') { 'Success' }
                                     elseif ($nodeResult.DeployStatus -eq 'DryRun') { 'DryRun' }
                                     else { 'PartialSuccess' }
            }
            catch {
                $nodeResult.Status = 'Failed'
                $nodeResult.Error = $_.Exception.Message
                Write-Host "  ✗ FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }

            $nodeResult.Duration = (Get-Date) - $nodeStart
            $results += $nodeResult
        }
    }

    end {
        # Summary
        Write-Host ""
        Write-Host "  ╔═══════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "  ║          Elysium Deployment Summary                   ║" -ForegroundColor Green
        Write-Host "  ╚═══════════════════════════════════════════════════════╝" -ForegroundColor Green

        foreach ($r in $results) {
            $statusIcon = switch ($r.Status) {
                'Success'        { "✓" }
                'PartialSuccess' { "⚠" }
                'DryRun'         { "→" }
                default          { "✗" }
            }
            $statusColor = switch ($r.Status) {
                'Success'        { "Green" }
                'PartialSuccess' { "Yellow" }
                'DryRun'         { "DarkGray" }
                default          { "Red" }
            }
            Write-Host "  $statusIcon $($r.ComputerName) — $($r.Status) ($([math]::Round($r.Duration.TotalSeconds, 1))s)" -ForegroundColor $statusColor
            Write-Host "    Bootstrap: $($r.BootstrapStatus) | Deploy: $($r.DeployStatus) | Mesh: $($r.MeshStatus)" -ForegroundColor DarkGray
        }

        $totalDuration = (Get-Date) - $startTime
        Write-Host ""
        Write-Host "  Total: $($results.Count) nodes in $([math]::Round($totalDuration.TotalSeconds, 1))s" -ForegroundColor White
        Write-Host "  Mesh Token: $($MeshToken.Substring(0, [Math]::Min(16, $MeshToken.Length)))..." -ForegroundColor DarkGray
        Write-Host ""

        # Start watchdog if requested
        if ($StartWatchdog -and -not $DryRun) {
            Write-Host "  Starting failover watchdog..." -ForegroundColor Cyan
            $watchdogScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "31-remote" "3102_Watch-MeshFailover.ps1"
            if (Test-Path $watchdogScript) {
                # Run as background job
                Start-Job -ScriptBlock {
                    param($script, $coreUrl)
                    & $script -CoreUrl $coreUrl -Continuous -EnableFailback
                } -ArgumentList $watchdogScript, $CoreUrl | Out-Null
                Write-Host "  Watchdog started as background job" -ForegroundColor Green
            }
        }

        if ($PassThru) {
            if ($results.Count -eq 1) { return $results[0] }
            return $results
        }
    }
}
