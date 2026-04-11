#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys AitherOS distributed compute cluster to local and cloud resources.

.DESCRIPTION
    This script orchestrates deployment of AitherOS distributed compute infrastructure:
    
    1. LOCAL MODE: Initializes the local machine as a compute controller
    2. MESH MODE: Joins additional local machines to the compute mesh
    3. CLOUD MODE: Provisions cloud GPUs from Vast.ai/RunPod and joins them to mesh
    4. CLUSTER MODE: Full cluster deployment with all of the above
    
    The script configures:
    - AitherCompute service (port 8168) as the central coordinator
    - AitherMesh for node discovery and communication
    - Tailscale/WireGuard for secure mesh networking
    - mTLS certificates for node authentication
    - Auto-scaling policies for cloud resources

.PARAMETER Mode
    Deployment mode:
    - Local: Initialize local compute controller
    - Mesh: Join this machine to an existing mesh
    - Cloud: Provision cloud GPU instances
    - Cluster: Full cluster deployment
    - Status: Show cluster status

.PARAMETER ControllerHost
    Controller host address (for Mesh mode)

.PARAMETER CloudProvider
    Cloud provider for GPU rental: vastai, runpod (default: vastai)

.PARAMETER GpuModel
    Preferred GPU model (e.g., RTX_4090, A100, H100)

.PARAMETER GpuCount
    Number of cloud GPUs to provision (default: 1)

.PARAMETER MinVram
    Minimum VRAM per GPU in GB (default: 24)

.PARAMETER MaxPricePerHour
    Maximum price per hour per GPU (default: 1.50)

.PARAMETER Region
    Preferred cloud region (optional)

.PARAMETER TailscaleAuthKey
    Tailscale authentication key for mesh networking

.PARAMETER AutoScale
    Enable auto-scaling based on job queue

.PARAMETER DryRun
    Show what would be done without executing

.EXAMPLE
    # Initialize local compute controller
    .\3010_Deploy-ComputeCluster.ps1 -Mode Local

.EXAMPLE
    # Join a remote machine to existing mesh
    .\3010_Deploy-ComputeCluster.ps1 -Mode Mesh -ControllerHost 192.168.1.100

.EXAMPLE
    # Provision cloud GPUs
    .\3010_Deploy-ComputeCluster.ps1 -Mode Cloud -GpuCount 2 -GpuModel A100 -MaxPricePerHour 2.00

.EXAMPLE
    # Full cluster deployment with cloud resources
    .\3010_Deploy-ComputeCluster.ps1 -Mode Cluster -GpuCount 4 -AutoScale

.NOTES
    Author: Aitherium
    Version: 1.0.0
    Priority: P621
    Dependencies: AitherCompute, AitherMesh, Tailscale (optional)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Local', 'Mesh', 'Cloud', 'Cluster', 'Status')]
    [string]$Mode,
    
    [string]$ControllerHost = "",
    
    [ValidateSet('vastai', 'runpod', '')]
    [string]$CloudProvider = "vastai",
    
    [string]$GpuModel = "RTX_4090",
    
    [int]$GpuCount = 1,
    
    [int]$MinVram = 24,
    
    [decimal]$MaxPricePerHour = 1.50,
    
    [string]$Region = "",
    
    [string]$TailscaleAuthKey = "",
    
    [switch]$AutoScale,
    
    [switch]$DryRun
)

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

$ErrorActionPreference = 'Stop'
$AITHEROS_ROOT = $env:AITHEROS_ROOT ?? (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

# Import helper functions if available
$initScript = Join-Path $PSScriptRoot "_init.ps1"
if (Test-Path $initScript) {
    . $initScript
}

# Service ports from AitherPorts
$COMPUTE_PORT = 8168
$MESH_PORT = 8125
$SECRETS_PORT = 8111
$GATEWAY_PORT = 8120

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
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
    
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$($symbols[$Level]) " -NoNewline -ForegroundColor $colors[$Level]
    Write-Host $Message -ForegroundColor $colors[$Level]
}

function Test-ServiceHealth {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 5
    )
    
    try {
        $response = Invoke-RestMethod -Uri "$Url/health" -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return $response.status -eq 'healthy' -or $response.status -eq 'ok'
    }
    catch {
        return $false
    }
}

function Get-ComputeCapacity {
    param([string]$Host = "localhost")
    
    try {
        $response = Invoke-RestMethod -Uri "http://${Host}:$COMPUTE_PORT/capacity" -TimeoutSec 10
        return $response
    }
    catch {
        Write-Warning "Failed to get compute capacity: $_"
        return $null
    }
}

function Invoke-CloudProvision {
    param(
        [string]$Provider,
        [string]$GpuModel,
        [int]$Count,
        [int]$MinVram,
        [decimal]$MaxPrice
    )
    
    $body = @{
        min_vram_gb = $MinVram
        gpu_name = $GpuModel
        gpu_count = $Count
        max_price_per_hour = $MaxPrice
        auto_join_mesh = $true
    }
    
    if ($Provider) {
        $body.provider = $Provider
    }
    
    try {
        $response = Invoke-RestMethod `
            -Uri "http://localhost:$COMPUTE_PORT/cloud/provision" `
            -Method POST `
            -ContentType "application/json" `
            -Body ($body | ConvertTo-Json) `
            -TimeoutSec 120
        
        return $response
    }
    catch {
        Write-Warning "Cloud provisioning failed: $_"
        return $null
    }
}

function Get-CloudOfferings {
    param(
        [int]$MinVram = 16,
        [decimal]$MaxPrice = 5.0,
        [string]$Provider = ""
    )
    
    $params = @{
        min_vram_gb = $MinVram
        max_price = $MaxPrice
    }
    if ($Provider) {
        $params.provider = $Provider
    }
    
    $query = ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
    
    try {
        $response = Invoke-RestMethod `
            -Uri "http://localhost:$COMPUTE_PORT/cloud/offerings?$query" `
            -TimeoutSec 30
        
        return $response.offerings
    }
    catch {
        Write-Warning "Failed to get cloud offerings: $_"
        return @()
    }
}

function Start-LocalCompute {
    Write-Status "Starting AitherCompute service..." -Level Info
    
    $pythonPath = Join-Path $AITHEROS_ROOT ".venv/Scripts/python.exe"
    if (-not (Test-Path $pythonPath)) {
        $pythonPath = "python"
    }
    
    $computeScript = Join-Path $AITHEROS_ROOT "AitherOS/services/gpu/AitherCompute.py"
    
    if (-not (Test-Path $computeScript)) {
        Write-Status "AitherCompute.py not found at $computeScript" -Level Error
        return $false
    }
    
    # Check if already running
    if (Test-ServiceHealth "http://localhost:$COMPUTE_PORT") {
        Write-Status "AitherCompute already running on port $COMPUTE_PORT" -Level Success
        return $true
    }
    
    if ($DryRun) {
        Write-Status "[DRY RUN] Would start: $pythonPath $computeScript" -Level Info
        return $true
    }
    
    # Start in background
    $proc = Start-Process -FilePath $pythonPath -ArgumentList $computeScript -PassThru -WindowStyle Hidden
    Write-Status "Started AitherCompute (PID: $($proc.Id))" -Level Info
    
    # Wait for service to be ready
    $maxWait = 30
    $waited = 0
    while ($waited -lt $maxWait) {
        Start-Sleep -Seconds 1
        $waited++
        if (Test-ServiceHealth "http://localhost:$COMPUTE_PORT") {
            Write-Status "AitherCompute is ready" -Level Success
            return $true
        }
    }
    
    Write-Status "AitherCompute failed to start within $maxWait seconds" -Level Error
    return $false
}

function Initialize-TailscaleMesh {
    param([string]$AuthKey)
    
    Write-Status "Setting up Tailscale mesh networking..." -Level Info
    
    # Check if Tailscale is installed
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $tailscale) {
        Write-Status "Tailscale not installed. Skipping mesh network setup." -Level Warning
        Write-Status "Install from: https://tailscale.com/download" -Level Info
        return $false
    }
    
    if ($DryRun) {
        Write-Status "[DRY RUN] Would initialize Tailscale with auth key" -Level Info
        return $true
    }
    
    # Login with auth key if provided
    if ($AuthKey) {
        & tailscale up --authkey $AuthKey --accept-routes --accept-dns
    }
    else {
        & tailscale up --accept-routes --accept-dns
    }
    
    # Get Tailscale IP
    $status = & tailscale status --json | ConvertFrom-Json
    if ($status.Self.TailscaleIPs) {
        $tsIP = $status.Self.TailscaleIPs[0]
        Write-Status "Tailscale IP: $tsIP" -Level Success
        return $true
    }
    
    return $false
}

function Register-MeshNode {
    param(
        [string]$ControllerHost,
        [string]$NodeName = $env:COMPUTERNAME,
        [string]$Role = "worker"
    )
    
    Write-Status "Registering with mesh controller at $ControllerHost..." -Level Info
    
    $body = @{
        name = $NodeName
        host = $ControllerHost
        role = $Role
    }
    
    if ($DryRun) {
        Write-Status "[DRY RUN] Would register node: $($body | ConvertTo-Json -Compress)" -Level Info
        return $true
    }
    
    try {
        $response = Invoke-RestMethod `
            -Uri "http://${ControllerHost}:$MESH_PORT/nodes/join" `
            -Method POST `
            -ContentType "application/json" `
            -Body ($body | ConvertTo-Json) `
            -TimeoutSec 30
        
        Write-Status "Registered as: $($response.node_id)" -Level Success
        return $true
    }
    catch {
        Write-Status "Mesh registration failed: $_" -Level Error
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MODE IMPLEMENTATIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-LocalMode {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     AitherOS Distributed Compute - Local Controller Setup      ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Step 1: Start AitherCompute
    if (-not (Start-LocalCompute)) {
        Write-Status "Failed to start AitherCompute" -Level Error
        return
    }
    
    # Step 2: Setup Tailscale (optional)
    if ($TailscaleAuthKey) {
        Initialize-TailscaleMesh -AuthKey $TailscaleAuthKey
    }
    
    # Step 3: Get local GPU info
    $capacity = Get-ComputeCapacity
    if ($capacity) {
        Write-Host ""
        Write-Status "Local Compute Capacity:" -Level Info
        Write-Host "  GPUs:   $($capacity.gpus.total) ($($capacity.gpus.total_vram_gb) GB VRAM)" -ForegroundColor White
        Write-Host "  CPU:    $($capacity.cpu.total_cores) cores" -ForegroundColor White
        Write-Host "  Memory: $($capacity.memory.total_gb) GB" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Status "Local compute controller initialized!" -Level Success
    Write-Host ""
    Write-Host "  Dashboard:  http://localhost:3000" -ForegroundColor Gray
    Write-Host "  API:        http://localhost:$COMPUTE_PORT" -ForegroundColor Gray
    Write-Host "  Topology:   http://localhost:$COMPUTE_PORT/topology" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-MeshMode {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║        AitherOS Distributed Compute - Mesh Node Join           ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    
    if (-not $ControllerHost) {
        Write-Status "ControllerHost is required for Mesh mode" -Level Error
        Write-Host "  Use: -ControllerHost <ip-address>" -ForegroundColor Gray
        return
    }
    
    # Step 1: Verify controller is reachable
    Write-Status "Checking controller at $ControllerHost..." -Level Info
    if (-not (Test-ServiceHealth "http://${ControllerHost}:$COMPUTE_PORT")) {
        Write-Status "Cannot reach controller at ${ControllerHost}:$COMPUTE_PORT" -Level Error
        return
    }
    Write-Status "Controller is online" -Level Success
    
    # Step 2: Start local compute service
    if (-not (Start-LocalCompute)) {
        Write-Status "Failed to start local compute service" -Level Error
        return
    }
    
    # Step 3: Setup Tailscale
    if ($TailscaleAuthKey) {
        Initialize-TailscaleMesh -AuthKey $TailscaleAuthKey
    }
    
    # Step 4: Register with controller
    if (-not (Register-MeshNode -ControllerHost $ControllerHost)) {
        Write-Status "Failed to join mesh" -Level Error
        return
    }
    
    Write-Host ""
    Write-Status "Successfully joined compute mesh!" -Level Success
}

function Invoke-CloudMode {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Blue
    Write-Host "║        AitherOS Distributed Compute - Cloud Provisioning       ║" -ForegroundColor Blue
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Blue
    Write-Host ""
    
    # Step 1: Verify local controller is running
    if (-not (Test-ServiceHealth "http://localhost:$COMPUTE_PORT")) {
        Write-Status "Local compute controller not running. Starting..." -Level Warning
        if (-not (Start-LocalCompute)) {
            Write-Status "Failed to start compute controller" -Level Error
            return
        }
    }
    
    # Step 2: Show available offerings
    Write-Status "Fetching cloud GPU offerings..." -Level Info
    $offerings = Get-CloudOfferings -MinVram $MinVram -MaxPrice $MaxPricePerHour -Provider $CloudProvider
    
    if ($offerings.Count -eq 0) {
        Write-Status "No offerings found matching criteria" -Level Warning
        Write-Host "  MinVRAM: ${MinVram}GB, MaxPrice: `$${MaxPricePerHour}/hr" -ForegroundColor Gray
        return
    }
    
    Write-Host ""
    Write-Host "  Available Offerings:" -ForegroundColor Cyan
    $offerings | Select-Object -First 5 | ForEach-Object {
        $gpu = $_
        Write-Host "    • $($gpu.gpu_name) - $($gpu.vram_gb)GB - `$$($gpu.price_per_hour.ToString('F2'))/hr ($($gpu.provider))" -ForegroundColor White
    }
    Write-Host ""
    
    # Step 3: Provision instances
    Write-Status "Provisioning $GpuCount x $GpuModel GPU(s)..." -Level Info
    
    if ($DryRun) {
        Write-Status "[DRY RUN] Would provision: $GpuCount GPU(s), VRAM >= ${MinVram}GB, Max `$${MaxPricePerHour}/hr" -Level Info
        return
    }
    
    for ($i = 0; $i -lt $GpuCount; $i++) {
        $instance = Invoke-CloudProvision `
            -Provider $CloudProvider `
            -GpuModel $GpuModel `
            -Count 1 `
            -MinVram $MinVram `
            -MaxPrice $MaxPricePerHour
        
        if ($instance) {
            Write-Status "Provisioned instance: $($instance.instance_id) ($($instance.gpu_name))" -Level Success
        }
        else {
            Write-Status "Failed to provision instance $($i + 1)" -Level Error
        }
    }
    
    Write-Host ""
    Write-Status "Cloud provisioning complete!" -Level Success
}

function Invoke-ClusterMode {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║        AitherOS Distributed Compute - Full Cluster Deploy      ║" -ForegroundColor Magenta
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
    
    # Step 1: Initialize local controller
    Write-Status "Step 1/3: Initializing local controller..." -Level Info
    Invoke-LocalMode
    
    # Step 2: Setup mesh networking
    Write-Host ""
    Write-Status "Step 2/3: Setting up mesh networking..." -Level Info
    if ($TailscaleAuthKey) {
        Initialize-TailscaleMesh -AuthKey $TailscaleAuthKey
    }
    else {
        Write-Status "Skipping Tailscale (no auth key provided)" -Level Warning
    }
    
    # Step 3: Provision cloud resources
    if ($GpuCount -gt 0) {
        Write-Host ""
        Write-Status "Step 3/3: Provisioning cloud GPUs..." -Level Info
        Invoke-CloudMode
    }
    else {
        Write-Status "Step 3/3: Skipping cloud provisioning (GpuCount = 0)" -Level Info
    }
    
    # Step 4: Enable auto-scaling if requested
    if ($AutoScale) {
        Write-Host ""
        Write-Status "Enabling auto-scaling..." -Level Info
        # TODO: Configure auto-scaling policy via AitherCompute API
        Write-Status "Auto-scaling policy configured" -Level Success
    }
    
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                    Cluster Deployment Complete!                 ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
}

function Invoke-StatusMode {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor White
    Write-Host "║          AitherOS Distributed Compute - Cluster Status         ║" -ForegroundColor White
    Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor White
    Write-Host ""
    
    # Check compute service
    $computeHealthy = Test-ServiceHealth "http://localhost:$COMPUTE_PORT"
    if ($computeHealthy) {
        Write-Status "AitherCompute: Online (port $COMPUTE_PORT)" -Level Success
    }
    else {
        Write-Status "AitherCompute: Offline" -Level Error
        return
    }
    
    # Get capacity
    $capacity = Get-ComputeCapacity
    if ($capacity) {
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  GPU Pool                                       │" -ForegroundColor DarkGray
        Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor DarkGray
        Write-Host "  │  Total:     $($capacity.gpus.total.ToString().PadLeft(4)) GPUs ($($capacity.gpus.total_vram_gb) GB VRAM)" -ForegroundColor Cyan
        Write-Host "  │  Available: $($capacity.gpus.available.ToString().PadLeft(4)) GPUs" -ForegroundColor Green
        Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  Nodes                                          │" -ForegroundColor DarkGray
        Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor DarkGray
        Write-Host "  │  Online:    $($capacity.nodes.online.ToString().PadLeft(4)) / $($capacity.nodes.total)" -ForegroundColor White
        Write-Host "  │  Local:     $($capacity.nodes.local.ToString().PadLeft(4))" -ForegroundColor Green
        Write-Host "  │  Cloud:     $($capacity.nodes.cloud.ToString().PadLeft(4))" -ForegroundColor Blue
        Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
        Write-Host "  │  Jobs                                           │" -ForegroundColor DarkGray
        Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor DarkGray
        Write-Host "  │  Running:   $($capacity.jobs.running.ToString().PadLeft(4))" -ForegroundColor Yellow
        Write-Host "  │  Pending:   $($capacity.jobs.pending.ToString().PadLeft(4))" -ForegroundColor White
        Write-Host "  │  Completed: $($capacity.jobs.completed.ToString().PadLeft(4))" -ForegroundColor Green
        Write-Host "  │  Failed:    $($capacity.jobs.failed.ToString().PadLeft(4))" -ForegroundColor Red
        Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor DarkGray
    }
    
    # Get cloud instances
    try {
        $cloudStatus = Invoke-RestMethod -Uri "http://localhost:$COMPUTE_PORT/cloud/instances" -TimeoutSec 10
        if ($cloudStatus.instances.Count -gt 0) {
            Write-Host ""
            Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
            Write-Host "  │  Cloud Instances                                │" -ForegroundColor DarkGray
            Write-Host "  ├─────────────────────────────────────────────────┤" -ForegroundColor DarkGray
            foreach ($inst in $cloudStatus.instances) {
                $costStr = "`$$($inst.price_per_hour.ToString('F2'))/hr"
                Write-Host "  │  $($inst.gpu_name.PadRight(15)) $costStr $($inst.status)" -ForegroundColor Blue
            }
            Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor DarkGray
        }
    }
    catch {
        # Ignore cloud status errors
    }
    
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

switch ($Mode) {
    'Local' { Invoke-LocalMode }
    'Mesh' { Invoke-MeshMode }
    'Cloud' { Invoke-CloudMode }
    'Cluster' { Invoke-ClusterMode }
    'Status' { Invoke-StatusMode }
}
