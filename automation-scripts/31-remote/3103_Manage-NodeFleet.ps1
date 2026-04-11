#Requires -Version 7.0

<#
.SYNOPSIS
    Manage a fleet of AitherNode remote compute nodes.

.DESCRIPTION
    Fleet management tool for operating multiple AitherNodes across a LAN.
    Supports:
    - Status check across all registered nodes
    - Rolling updates (drain → update → rejoin per node)
    - Batch deployment to multiple hosts
    - Fleet-wide health reporting

    Exit Codes:
        0 - Success
        1 - Partial failure (some nodes unhealthy)
        2 - Fleet unreachable

.PARAMETER Action
    What to do:
    - Status:   Check health of all known nodes (default)
    - Update:   Rolling update across all nodes
    - Deploy:   Deploy AitherNode to new hosts
    - Report:   Generate fleet health report
    - Restart:  Restart containers on a specific node

.PARAMETER Nodes
    List of node hostnames/IPs. If not provided, queries mesh for registered nodes.

.PARAMETER Credential
    PSCredential for remote access.

.PARAMETER CredentialName
    Stored credential name.

.PARAMETER Profile
    Service profile for deploys. Default: core.

.PARAMETER RollingDelay
    Seconds between nodes during rolling update. Default: 30.

.PARAMETER DryRun
    Preview mode.

.PARAMETER PassThru
    Return result objects.

.NOTES
    Stage: Remote-Deploy
    Order: 3103
    Dependencies: 3100, 3101, 3102
    Tags: fleet, nodes, management, remote, deploy
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Status", "Update", "Deploy", "Report", "Restart")]
    [string]$Action = "Status",

    [string[]]$Nodes,

    [PSCredential]$Credential,
    [string]$CredentialName,

    [ValidateSet("minimal", "core", "gpu", "dashboard", "all")]
    [string]$Profile = "core",

    [int]$RollingDelay = 30,

    [string]$CoreUrl = "http://localhost:8001",
    [int]$MeshPort = 8125,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════
# RESOLVE NODES
# ═══════════════════════════════════════════════════════════════════════

$meshUrl = $CoreUrl -replace ':\d+$', ":$MeshPort"

if (-not $Nodes -or $Nodes.Count -eq 0) {
    Write-Host "  Querying mesh for registered nodes..." -ForegroundColor DarkGray
    try {
        $meshData = Invoke-RestMethod -Uri "$meshUrl/mesh/nodes" -TimeoutSec 10 -ErrorAction Stop
        $registeredNodes = if ($meshData.nodes) { $meshData.nodes } elseif ($meshData -is [array]) { $meshData } else { @() }
        $Nodes = $registeredNodes | ForEach-Object {
            $url = $_.node_url ?? $_.url ?? ""
            if ($url -match '//([^:]+)') { $Matches[1] } else { $_.node_id ?? $_.id }
        }
    }
    catch {
        Write-Host "  ✗ Cannot query mesh. Provide -Nodes explicitly." -ForegroundColor Red
        exit 2
    }
}

if ($Nodes.Count -eq 0) {
    Write-Host "  No nodes to manage." -ForegroundColor Yellow
    exit 0
}

# Resolve credential
if ($CredentialName -and -not $Credential) {
    try { $Credential = Get-AitherCredential -Name $CredentialName -ErrorAction Stop } catch {}
}

# ═══════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     AitherNode Fleet Manager (3103)                ║" -ForegroundColor Cyan
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Action: $Action | Nodes: $($Nodes -join ', ')"
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════════

if ($Action -eq "Status" -or $Action -eq "Report") {
    $results = @()

    foreach ($node in $Nodes) {
        $services = @(
            @{ Name = "Genesis"; Port = 8001 },
            @{ Name = "Pulse";   Port = 8081 },
            @{ Name = "Watch";   Port = 8082 },
            @{ Name = "Mesh";    Port = 8125 },
            @{ Name = "Strata";  Port = 8136 },
            @{ Name = "MicroSch"; Port = 8150 }
        )

        $svcResults = foreach ($svc in $services) {
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Invoke-RestMethod -Uri "http://${node}:$($svc.Port)/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null
                $sw.Stop()
                [PSCustomObject]@{ Service = $svc.Name; Port = $svc.Port; Status = "OK"; LatencyMs = $sw.ElapsedMilliseconds }
            }
            catch {
                [PSCustomObject]@{ Service = $svc.Name; Port = $svc.Port; Status = "DOWN"; LatencyMs = -1 }
            }
        }

        $healthy = ($svcResults | Where-Object { $_.Status -eq "OK" }).Count
        $total = $svcResults.Count
        $icon = if ($healthy -eq $total) { "●" } elseif ($healthy -gt 0) { "◐" } else { "○" }
        $color = if ($healthy -eq $total) { "Green" } elseif ($healthy -gt 0) { "Yellow" } else { "Red" }

        Write-Host "  $icon $node — $healthy/$total services" -ForegroundColor $color
        $svcResults | ForEach-Object {
            $sColor = if ($_.Status -eq "OK") { "Green" } else { "Red" }
            $sIcon = if ($_.Status -eq "OK") { "✓" } else { "✗" }
            $latency = if ($_.LatencyMs -ge 0) { "$($_.LatencyMs)ms" } else { "—" }
            Write-Host "    $sIcon $($_.Service):$($_.Port) $latency" -ForegroundColor $sColor
        }
        Write-Host ""

        $results += [PSCustomObject]@{
            Node     = $node
            Healthy  = $healthy
            Total    = $total
            Services = $svcResults
        }
    }

    if ($Action -eq "Report") {
        $totalHealthy = ($results | Measure-Object -Property Healthy -Sum).Sum
        $totalSvcs = ($results | Measure-Object -Property Total -Sum).Sum
        Write-Host "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
        Write-Host "  FLEET: $($results.Count) nodes | $totalHealthy/$totalSvcs services healthy" -ForegroundColor White
        $fullyHealthy = ($results | Where-Object { $_.Healthy -eq $_.Total }).Count
        Write-Host "  Fully healthy nodes: $fullyHealthy/$($results.Count)" -ForegroundColor $(if ($fullyHealthy -eq $results.Count) { "Green" } else { "Yellow" })
        Write-Host ""
    }

    if ($PassThru) {
        return [PSCustomObject]@{
            PSTypeName = 'AitherOS.FleetStatus'
            Action     = $Action
            Nodes      = $results
            Timestamp  = Get-Date
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# ROLLING UPDATE
# ═══════════════════════════════════════════════════════════════════════

elseif ($Action -eq "Update") {
    $deployScript = Join-Path $PSScriptRoot "3101_Deploy-RemoteNode.ps1"

    foreach ($node in $Nodes) {
        Write-Host "  ━━━ Updating $node ━━━" -ForegroundColor White

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would rolling-update $node" -ForegroundColor Yellow
        }
        else {
            $params = @{
                ComputerName = $node
                Profile      = $Profile
                Rolling      = $true
                CoreUrl      = $CoreUrl
                Force        = [bool]$Force
                PassThru     = $true
            }
            if ($Credential) { $params.Credential = $Credential }

            if (Test-Path $deployScript) {
                & $deployScript @params
            }
            else {
                Write-Host "  ⚠ Deploy script not found at $deployScript" -ForegroundColor Yellow
            }

            if ($Nodes.IndexOf($node) -lt ($Nodes.Count - 1)) {
                Write-Host "  Waiting ${RollingDelay}s before next node..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $RollingDelay
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# DEPLOY
# ═══════════════════════════════════════════════════════════════════════

elseif ($Action -eq "Deploy") {
    $priority = 10
    foreach ($node in $Nodes) {
        Write-Host "  ━━━ Deploying to $node (priority: $priority) ━━━" -ForegroundColor White

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would deploy AitherNode to $node" -ForegroundColor Yellow
        }
        else {
            $setupScript = Join-Path $PSScriptRoot "3100_Setup-HyperVHost.ps1"
            if (Test-Path $setupScript) {
                $params = @{
                    ComputerName = $node
                    CoreUrl      = $CoreUrl
                    Force        = [bool]$Force
                    PassThru     = $true
                }
                if ($Credential) { $params.Credential = $Credential }
                & $setupScript @params
            }
        }
        $priority += 5
    }
}

# ═══════════════════════════════════════════════════════════════════════
# RESTART
# ═══════════════════════════════════════════════════════════════════════

elseif ($Action -eq "Restart") {
    foreach ($node in $Nodes) {
        Write-Host "  Restarting containers on $node..." -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would restart AitherNode on $node" -ForegroundColor Yellow
            continue
        }

        if (-not $Credential) { $Credential = Get-Credential -Message "Credentials for $node" }
        $sessionParams = @{ ComputerName = $node; Credential = $Credential }
        try {
            $session = New-PSSession @sessionParams
            Invoke-Command -Session $session -ScriptBlock {
                Set-Location C:\AitherOS
                docker compose -f docker-compose.node.yml restart 2>&1
            } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Remove-PSSession $session
            Write-Host "  ✓ $node restarted" -ForegroundColor Green
        }
        catch {
            Write-Host "  ✗ $node restart failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

Write-Host "  Done." -ForegroundColor Green
Write-Host ""
