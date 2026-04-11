#Requires -Version 7.0
<#
.SYNOPSIS
    Manages and scales AitherOS distributed compute cluster.

.DESCRIPTION
    This script provides management operations for the distributed compute cluster:
    
    - SCALE: Add or remove cloud GPU instances
    - DRAIN: Gracefully drain a node for maintenance
    - TERMINATE: Terminate cloud instances
    - LIST: List all nodes and their status
    - JOBS: View and manage compute jobs
    - METRICS: Display cluster metrics
    
    Integrates with AitherCompute (port 8168) for all operations.

.PARAMETER Action
    Management action to perform:
    - Scale: Scale cloud resources up/down
    - Drain: Drain a node for maintenance
    - Undrain: Bring a drained node back online
    - Terminate: Terminate cloud instance(s)
    - List: List all nodes
    - Jobs: List compute jobs
    - Metrics: Show cluster metrics
    - AutoScale: Configure auto-scaling policy

.PARAMETER NodeId
    Target node ID for Drain/Undrain/Terminate actions

.PARAMETER InstanceId
    Cloud instance ID for Terminate action

.PARAMETER TargetGpuCount
    Target number of cloud GPUs for Scale action

.PARAMETER ScaleMin
    Minimum GPU count for auto-scaling (default: 0)

.PARAMETER ScaleMax
    Maximum GPU count for auto-scaling (default: 10)

.PARAMETER ScaleThreshold
    Queue depth threshold to trigger scale-up (default: 5)

.PARAMETER MaxPricePerHour
    Maximum price per GPU hour for scaling (default: 1.50)

.PARAMETER JobStatus
    Filter jobs by status: pending, running, completed, failed, all

.PARAMETER Force
    Skip confirmation prompts

.EXAMPLE
    # Scale cluster to 4 cloud GPUs
    .\3011_Manage-ComputeCluster.ps1 -Action Scale -TargetGpuCount 4

.EXAMPLE
    # Drain a node for maintenance
    .\3011_Manage-ComputeCluster.ps1 -Action Drain -NodeId node-abc123

.EXAMPLE
    # Terminate a cloud instance
    .\3011_Manage-ComputeCluster.ps1 -Action Terminate -InstanceId inst-xyz789

.EXAMPLE
    # Configure auto-scaling
    .\3011_Manage-ComputeCluster.ps1 -Action AutoScale -ScaleMin 1 -ScaleMax 8 -ScaleThreshold 10

.EXAMPLE
    # View cluster metrics
    .\3011_Manage-ComputeCluster.ps1 -Action Metrics

.NOTES
    Author: Aitherium
    Version: 1.0.0
    Priority: P622
    Dependencies: AitherCompute
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Scale', 'Drain', 'Undrain', 'Terminate', 'List', 'Jobs', 'Metrics', 'AutoScale')]
    [string]$Action,
    
    [string]$NodeId = "",
    
    [string]$InstanceId = "",
    
    [int]$TargetGpuCount = -1,
    
    [int]$ScaleMin = 0,
    
    [int]$ScaleMax = 10,
    
    [int]$ScaleThreshold = 5,
    
    [decimal]$MaxPricePerHour = 1.50,
    
    [ValidateSet('pending', 'running', 'completed', 'failed', 'all')]
    [string]$JobStatus = 'all',
    
    [switch]$Force
)

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'Stop'
$COMPUTE_PORT = 8168
$COMPUTE_URL = "http://localhost:$COMPUTE_PORT"

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $colors = @{
        'Info' = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error' = 'Red'
    }
    $symbols = @{
        'Info' = '►'
        'Success' = '✓'
        'Warning' = '⚠'
        'Error' = '✗'
    }
    
    Write-Host "$($symbols[$Level]) " -NoNewline -ForegroundColor $colors[$Level]
    Write-Host $Message -ForegroundColor $colors[$Level]
}

function Test-ComputeService {
    try {
        $response = Invoke-RestMethod -Uri "$COMPUTE_URL/health" -TimeoutSec 5 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-ComputeApi {
    param(
        [string]$Path,
        [string]$Method = 'GET',
        [object]$Body = $null,
        [int]$TimeoutSec = 30
    )
    
    $params = @{
        Uri = "$COMPUTE_URL$Path"
        Method = $Method
        TimeoutSec = $TimeoutSec
    }
    
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
        $params.ContentType = "application/json"
    }
    
    return Invoke-RestMethod @params
}

function Format-FileSize {
    param([long]$Bytes)
    
    if ($Bytes -ge 1TB) { return "{0:F2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:F2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:F2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:F2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Duration {
    param([int]$Seconds)
    
    if ($Seconds -ge 86400) { return "{0}d {1}h" -f [int]($Seconds / 86400), [int](($Seconds % 86400) / 3600) }
    if ($Seconds -ge 3600) { return "{0}h {1}m" -f [int]($Seconds / 3600), [int](($Seconds % 3600) / 60) }
    if ($Seconds -ge 60) { return "{0}m {1}s" -f [int]($Seconds / 60), ($Seconds % 60) }
    return "${Seconds}s"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ACTION IMPLEMENTATIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-ScaleAction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "             SCALE COMPUTE CLUSTER" -ForegroundColor Magenta
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
    
    if ($TargetGpuCount -lt 0) {
        Write-Status "-TargetGpuCount is required for Scale action" -Level Error
        return
    }
    
    # Get current status
    $status = Invoke-ComputeApi -Path "/capacity"
    $currentCloud = $status.nodes.cloud
    
    Write-Status "Current cloud GPUs: $currentCloud" -Level Info
    Write-Status "Target cloud GPUs:  $TargetGpuCount" -Level Info
    
    $delta = $TargetGpuCount - $currentCloud
    
    if ($delta -eq 0) {
        Write-Status "Already at target. No action needed." -Level Success
        return
    }
    
    if ($delta -gt 0) {
        Write-Status "Scaling UP: Adding $delta GPU(s)..." -Level Info
        
        for ($i = 0; $i -lt $delta; $i++) {
            $body = @{
                min_vram_gb = 24
                max_price_per_hour = $MaxPricePerHour
                auto_join_mesh = $true
            }
            
            $result = Invoke-ComputeApi -Path "/cloud/provision" -Method POST -Body $body
            if ($result.instance_id) {
                Write-Status "Provisioned: $($result.instance_id) ($($result.gpu_name))" -Level Success
            }
        }
    }
    else {
        $toRemove = -$delta
        Write-Status "Scaling DOWN: Removing $toRemove GPU(s)..." -Level Warning
        
        if (-not $Force) {
            $confirm = Read-Host "Are you sure? (y/N)"
            if ($confirm -notmatch '^[Yy]') {
                Write-Status "Cancelled" -Level Info
                return
            }
        }
        
        # Get cloud instances
        $instances = Invoke-ComputeApi -Path "/cloud/instances"
        
        for ($i = 0; $i -lt [Math]::Min($toRemove, $instances.instances.Count); $i++) {
            $inst = $instances.instances[$i]
            $result = Invoke-ComputeApi -Path "/cloud/terminate/$($inst.instance_id)" -Method DELETE
            Write-Status "Terminated: $($inst.instance_id)" -Level Success
        }
    }
    
    Write-Host ""
    Write-Status "Scale operation complete!" -Level Success
}

function Invoke-DrainAction {
    if (-not $NodeId) {
        Write-Status "-NodeId is required for Drain action" -Level Error
        return
    }
    
    Write-Host ""
    Write-Status "Draining node: $NodeId" -Level Warning
    
    try {
        $result = Invoke-ComputeApi -Path "/nodes/$NodeId/drain" -Method POST
        Write-Status "Node $NodeId is now draining" -Level Success
        Write-Status "Active jobs will complete, new jobs will be scheduled elsewhere" -Level Info
    }
    catch {
        Write-Status "Failed to drain node: $_" -Level Error
    }
}

function Invoke-UndrainAction {
    if (-not $NodeId) {
        Write-Status "-NodeId is required for Undrain action" -Level Error
        return
    }
    
    Write-Host ""
    Write-Status "Undraining node: $NodeId" -Level Info
    
    try {
        $result = Invoke-ComputeApi -Path "/nodes/$NodeId/undrain" -Method POST
        Write-Status "Node $NodeId is back online" -Level Success
    }
    catch {
        Write-Status "Failed to undrain node: $_" -Level Error
    }
}

function Invoke-TerminateAction {
    if (-not $InstanceId -and -not $NodeId) {
        Write-Status "-InstanceId or -NodeId is required for Terminate action" -Level Error
        return
    }
    
    $targetId = if ($InstanceId) { $InstanceId } else { $NodeId }
    
    Write-Host ""
    Write-Status "Terminating: $targetId" -Level Warning
    
    if (-not $Force) {
        $confirm = Read-Host "Are you sure? This will terminate the cloud instance. (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Status "Cancelled" -Level Info
            return
        }
    }
    
    try {
        $result = Invoke-ComputeApi -Path "/cloud/terminate/$targetId" -Method DELETE
        Write-Status "Instance terminated: $targetId" -Level Success
    }
    catch {
        Write-Status "Failed to terminate: $_" -Level Error
    }
}

function Invoke-ListAction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    COMPUTE NODES" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $topology = Invoke-ComputeApi -Path "/topology"
        
        if ($topology.nodes.Count -eq 0) {
            Write-Status "No nodes in cluster" -Level Warning
            return
        }
        
        # Group by type
        $localNodes = $topology.nodes | Where-Object { $_.type -eq 'local' }
        $cloudNodes = $topology.nodes | Where-Object { $_.type -eq 'cloud' }
        
        if ($localNodes.Count -gt 0) {
            Write-Host "  LOCAL NODES" -ForegroundColor Green
            Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
            foreach ($node in $localNodes) {
                $statusColor = switch ($node.status) {
                    'online' { 'Green' }
                    'draining' { 'Yellow' }
                    'offline' { 'Red' }
                    default { 'Gray' }
                }
                Write-Host "  [$($node.status.ToUpper().PadRight(9))]" -NoNewline -ForegroundColor $statusColor
                Write-Host " $($node.id.PadRight(20)) " -NoNewline -ForegroundColor White
                Write-Host "GPUs: $($node.gpus) " -NoNewline -ForegroundColor Cyan
                Write-Host "($($node.gpu_model))" -ForegroundColor Gray
            }
            Write-Host ""
        }
        
        if ($cloudNodes.Count -gt 0) {
            Write-Host "  CLOUD NODES" -ForegroundColor Blue
            Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
            foreach ($node in $cloudNodes) {
                $statusColor = switch ($node.status) {
                    'online' { 'Green' }
                    'draining' { 'Yellow' }
                    'offline' { 'Red' }
                    'provisioning' { 'Cyan' }
                    default { 'Gray' }
                }
                $cost = if ($node.price_per_hour) { "`$$($node.price_per_hour.ToString('F2'))/hr" } else { "" }
                Write-Host "  [$($node.status.ToUpper().PadRight(12))]" -NoNewline -ForegroundColor $statusColor
                Write-Host " $($node.id.Substring(0, [Math]::Min(18, $node.id.Length)).PadRight(18)) " -NoNewline -ForegroundColor White
                Write-Host "$($node.gpu_model.PadRight(15)) " -NoNewline -ForegroundColor Cyan
                Write-Host "$cost " -NoNewline -ForegroundColor Yellow
                Write-Host "($($node.provider))" -ForegroundColor Gray
            }
            Write-Host ""
        }
        
        # Summary
        $totalGpus = ($topology.nodes | Measure-Object -Property gpus -Sum).Sum
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Total: $($topology.nodes.Count) nodes, $totalGpus GPUs" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Write-Status "Failed to get node list: $_" -Level Error
    }
}

function Invoke-JobsAction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "                    COMPUTE JOBS" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    
    try {
        $activity = Invoke-ComputeApi -Path "/activity"
        
        # Filter by status
        $jobs = if ($JobStatus -eq 'all') {
            $activity.recent_requests
        }
        else {
            $activity.recent_requests | Where-Object { $_.status -eq $JobStatus }
        }
        
        if ($jobs.Count -eq 0) {
            Write-Status "No jobs found" -Level Info
            return
        }
        
        foreach ($job in $jobs) {
            $statusColor = switch ($job.status) {
                'pending' { 'Yellow' }
                'running' { 'Cyan' }
                'completed' { 'Green' }
                'failed' { 'Red' }
                default { 'Gray' }
            }
            
            $duration = if ($job.duration_ms) { 
                Format-Duration -Seconds ([int]($job.duration_ms / 1000)) 
            } else { 
                "..." 
            }
            
            Write-Host "  [$($job.status.ToUpper().PadRight(10))]" -NoNewline -ForegroundColor $statusColor
            Write-Host " $($job.job_id.Substring(0, [Math]::Min(12, $job.job_id.Length)).PadRight(12)) " -NoNewline -ForegroundColor White
            Write-Host "$($job.type.PadRight(15)) " -NoNewline -ForegroundColor Cyan
            Write-Host "$duration" -ForegroundColor Gray
        }
        
        # Stats
        Write-Host ""
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Total: $($activity.total_requests) | " -NoNewline -ForegroundColor White
        Write-Host "Pending: $($activity.pending_count) | " -NoNewline -ForegroundColor Yellow
        Write-Host "Running: $($activity.running_count) | " -NoNewline -ForegroundColor Cyan
        Write-Host "Avg: $([int]$activity.avg_duration_ms)ms" -ForegroundColor Green
        Write-Host ""
    }
    catch {
        Write-Status "Failed to get jobs: $_" -Level Error
    }
}

function Invoke-MetricsAction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "                   CLUSTER METRICS" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    
    try {
        $summary = Invoke-ComputeApi -Path "/metrics/summary"
        
        # GPU section
        Write-Host "  GPU UTILIZATION" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        
        $gpuBar = "█" * [int]($summary.gpu.utilization_percent / 5)
        $gpuEmpty = "░" * (20 - [int]($summary.gpu.utilization_percent / 5))
        Write-Host "  Compute:  " -NoNewline
        Write-Host "$gpuBar$gpuEmpty " -NoNewline -ForegroundColor Cyan
        Write-Host "$($summary.gpu.utilization_percent.ToString('F1'))%" -ForegroundColor White
        
        $vramBar = "█" * [int]($summary.gpu.vram_used_percent / 5)
        $vramEmpty = "░" * (20 - [int]($summary.gpu.vram_used_percent / 5))
        Write-Host "  VRAM:     " -NoNewline
        Write-Host "$vramBar$vramEmpty " -NoNewline -ForegroundColor Magenta
        Write-Host "$($summary.gpu.vram_used_gb.ToString('F1'))GB / $($summary.gpu.vram_total_gb.ToString('F1'))GB ($($summary.gpu.vram_used_percent.ToString('F1'))%)" -ForegroundColor White
        
        Write-Host ""
        Write-Host "  MEMORY & CPU" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        
        $memBar = "█" * [int]($summary.memory.used_percent / 5)
        $memEmpty = "░" * (20 - [int]($summary.memory.used_percent / 5))
        Write-Host "  RAM:      " -NoNewline
        Write-Host "$memBar$memEmpty " -NoNewline -ForegroundColor Yellow
        Write-Host "$(Format-FileSize ($summary.memory.used_gb * 1GB)) / $(Format-FileSize ($summary.memory.total_gb * 1GB))" -ForegroundColor White
        
        $cpuBar = "█" * [int]($summary.cpu.utilization_percent / 5)
        $cpuEmpty = "░" * (20 - [int]($summary.cpu.utilization_percent / 5))
        Write-Host "  CPU:      " -NoNewline
        Write-Host "$cpuBar$cpuEmpty " -NoNewline -ForegroundColor Green
        Write-Host "$($summary.cpu.utilization_percent.ToString('F1'))%" -ForegroundColor White
        
        Write-Host ""
        Write-Host "  I/O BANDWIDTH" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Network:  ↓ $(Format-FileSize $summary.io.network_rx_bytes)/s  ↑ $(Format-FileSize $summary.io.network_tx_bytes)/s" -ForegroundColor White
        Write-Host "  Disk:     ↓ $(Format-FileSize $summary.io.disk_read_bytes)/s  ↑ $(Format-FileSize $summary.io.disk_write_bytes)/s" -ForegroundColor White
        
        Write-Host ""
        Write-Host "  THROUGHPUT" -ForegroundColor Cyan
        Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Requests: $($summary.throughput.requests_per_second.ToString('F1'))/sec" -ForegroundColor White
        Write-Host "  Tokens:   $($summary.throughput.tokens_per_second.ToString('F0'))/sec (inference)" -ForegroundColor White
        
        Write-Host ""
    }
    catch {
        Write-Status "Failed to get metrics: $_" -Level Error
    }
}

function Invoke-AutoScaleAction {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "                AUTO-SCALING POLICY" -ForegroundColor Blue
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    $policy = @{
        enabled = $true
        min_gpu_count = $ScaleMin
        max_gpu_count = $ScaleMax
        scale_up_threshold = $ScaleThreshold
        scale_down_threshold = [Math]::Max(1, $ScaleThreshold - 3)
        max_price_per_hour = $MaxPricePerHour
        cooldown_seconds = 300
    }
    
    Write-Status "Configuring auto-scaling policy..." -Level Info
    Write-Host "  Min GPUs:        $ScaleMin" -ForegroundColor White
    Write-Host "  Max GPUs:        $ScaleMax" -ForegroundColor White
    Write-Host "  Scale-up at:     $ScaleThreshold pending jobs" -ForegroundColor White
    Write-Host "  Max price:       `$$MaxPricePerHour/hr" -ForegroundColor White
    Write-Host ""
    
    try {
        $result = Invoke-ComputeApi -Path "/autoscale/policy" -Method POST -Body $policy
        Write-Status "Auto-scaling policy configured!" -Level Success
        Write-Status "Cluster will automatically scale between $ScaleMin-$ScaleMax GPUs" -Level Info
    }
    catch {
        Write-Status "Failed to configure auto-scaling: $_" -Level Error
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

# Verify compute service is running
if (-not (Test-ComputeService)) {
    Write-Status "AitherCompute service is not running on port $COMPUTE_PORT" -Level Error
    Write-Status "Start it with: .\3010_Deploy-ComputeCluster.ps1 -Mode Local" -Level Info
    exit 1
}

switch ($Action) {
    'Scale' { Invoke-ScaleAction }
    'Drain' { Invoke-DrainAction }
    'Undrain' { Invoke-UndrainAction }
    'Terminate' { Invoke-TerminateAction }
    'List' { Invoke-ListAction }
    'Jobs' { Invoke-JobsAction }
    'Metrics' { Invoke-MetricsAction }
    'AutoScale' { Invoke-AutoScaleAction }
}
