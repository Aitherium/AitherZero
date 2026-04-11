<#
.SYNOPSIS
    Starts and manages the AitherExo clustered LLM inference cluster.

.DESCRIPTION
    This script manages the exo distributed inference cluster, enabling models
    to be split across multiple GPU nodes (home desktop + homelab hypervisor).
    
    Features:
    - Automatic device discovery (UDP, Tailscale, Manual)
    - Dynamic model partitioning based on GPU memory
    - Ring memory-weighted layer distribution
    - P2P node topology with no master-worker architecture
    
.PARAMETER Action
    Action to perform: Start, Stop, Status, Join
    
.PARAMETER DiscoveryModule
    Discovery method: udp (default), tailscale, manual
    
.PARAMETER InferenceEngine
    Inference engine: tinygrad (default on NVIDIA), mlx (Apple Silicon)
    
.PARAMETER WaitForPeers
    Number of peers to wait for before starting inference
    
.PARAMETER TailscaleApiKey
    Tailscale API key (for tailscale discovery)
    
.PARAMETER TailnetName
    Tailnet name (for tailscale discovery)
    
.PARAMETER NodeIdFilter
    Comma-separated list of allowed node IDs
    
.PARAMETER ManualConfigPath
    Path to manual discovery config JSON file
    
.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Start local node with UDP discovery (auto-discovers peers on LAN)
    .\0815_Manage-AitherExo.ps1 -Action Start
    
.EXAMPLE
    # Start with Tailscale discovery for cross-network clustering
    .\0815_Manage-AitherExo.ps1 -Action Start -DiscoveryModule tailscale -TailscaleApiKey $key
    
.EXAMPLE
    # Join an existing cluster and wait for 1 other peer
    .\0815_Manage-AitherExo.ps1 -Action Join -WaitForPeers 1
    
.EXAMPLE
    # Check cluster status
    .\0815_Manage-AitherExo.ps1 -Action Status
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Start', 'Stop', 'Status', 'Join', 'Install')]
    [string]$Action = 'Status',
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('udp', 'tailscale', 'manual')]
    [string]$DiscoveryModule = 'udp',
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('tinygrad', 'mlx', 'dummy')]
    [string]$InferenceEngine,
    
    [Parameter(Mandatory = $false)]
    [int]$WaitForPeers = 0,
    
    [Parameter(Mandatory = $false)]
    [string]$TailscaleApiKey,
    
    [Parameter(Mandatory = $false)]
    [string]$TailnetName,
    
    [Parameter(Mandatory = $false)]
    [string]$NodeIdFilter,
    
    [Parameter(Mandatory = $false)]
    [string]$ManualConfigPath,
    
    [Parameter(Mandatory = $false)]
    [string]$Model,
    
    [Parameter(Mandatory = $false)]
    [int]$ApiPort = 52415,
    
    [Parameter(Mandatory = $false)]
    [int]$NodePort = 5678,
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowOutput
)

# Initialize script
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
. (Join-Path $scriptDir '_init.ps1')

# Configuration
$ExoPath = Join-Path $env:AITHERZERO_ROOT 'external' 'exo'
$PythonPath = Join-Path $env:AITHERZERO_ROOT 'AitherOS' 'agents' 'NarrativeAgent' '.venv' 'Scripts' 'python.exe'

# Detect system and set defaults
if (-not $InferenceEngine) {
    $InferenceEngine = 'tinygrad'
    if ($IsMacOS -and (uname -m) -eq 'arm64') {
        $InferenceEngine = 'mlx'
    }
}

function Test-ExoInstalled {
    return Test-Path $ExoPath
}

function Install-Exo {
    Write-AitherInfo 'Installing exo from external/exo...'
    
    if (-not (Test-Path $ExoPath)) {
        Write-AitherError "Exo not found at $ExoPath. Please clone it first."
        return $false
    }
    
    # Install exo in editable mode
    $env:PYTHONPATH = $ExoPath
    $installCmd = "& '$PythonPath' -m pip install -e '$ExoPath'"
    
    if ($ShowOutput) {
        Invoke-Expression $installCmd
    } else {
        Invoke-Expression $installCmd 2>&1 | Out-Null
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-AitherSuccess 'Exo installed successfully'
        return $true
    } else {
        Write-AitherError 'Failed to install exo'
        return $false
    }
}

function Start-ExoCluster {
    param(
        [switch]$Join
    )
    
    Write-AitherInfo "Starting exo cluster node (discovery: $DiscoveryModule, engine: $InferenceEngine)"
    
    if (-not (Test-ExoInstalled)) {
        Write-AitherWarning 'Exo not installed. Installing...'
        if (-not (Install-Exo)) {
            return
        }
    }
    
    # Build command arguments
    $args = @(
        '-m', 'exo.main',
        '--discovery-module', $DiscoveryModule,
        '--inference-engine', $InferenceEngine,
        '--chatgpt-api-port', $ApiPort,
        '--node-port', $NodePort
    )
    
    if ($WaitForPeers -gt 0) {
        $args += '--wait-for-peers', $WaitForPeers
    }
    
    if ($NodeIdFilter) {
        $args += '--node-id-filter', $NodeIdFilter
    }
    
    if ($DiscoveryModule -eq 'tailscale') {
        if ($TailscaleApiKey) {
            $args += '--tailscale-api-key', $TailscaleApiKey
        }
        if ($TailnetName) {
            $args += '--tailnet-name', $TailnetName
        }
    }
    
    if ($DiscoveryModule -eq 'manual' -and $ManualConfigPath) {
        $args += '--discovery-config-path', $ManualConfigPath
    }
    
    if ($Model) {
        $args = @('run', $Model) + $args
    }
    
    # Set environment
    $env:PYTHONPATH = $ExoPath
    
    Write-AitherInfo "Exo cluster node starting..."
    Write-AitherInfo "  Discovery: $DiscoveryModule"
    Write-AitherInfo "  Engine: $InferenceEngine"
    Write-AitherInfo "  API: http://localhost:$ApiPort"
    Write-AitherInfo "  Node Port: $NodePort"
    
    if ($WaitForPeers -gt 0) {
        Write-AitherInfo "  Waiting for $WaitForPeers peer(s) before starting"
    }
    
    Write-Host ""
    Write-AitherSuccess "🔗 Cluster endpoints:"
    Write-Host "   WebUI: http://localhost:$ApiPort"
    Write-Host "   API:   http://localhost:$ApiPort/v1/chat/completions"
    Write-Host ""
    
    if ($ShowOutput) {
        & $PythonPath @args
    } else {
        Start-Process -FilePath $PythonPath -ArgumentList $args -NoNewWindow
        Write-AitherSuccess 'Exo cluster started in background'
    }
}

function Stop-ExoCluster {
    Write-AitherInfo 'Stopping exo cluster...'
    
    try {
        Invoke-RestMethod -Uri "http://localhost:$ApiPort/quit" -Method Post -ErrorAction SilentlyContinue
        Write-AitherSuccess 'Exo cluster stopped via API'
    } catch {
        # Try to kill the process directly
        Get-Process -Name python* | Where-Object { 
            $_.CommandLine -like '*exo*' 
        } | Stop-Process -Force -ErrorAction SilentlyContinue
        
        Write-AitherSuccess 'Exo cluster processes terminated'
    }
}

function Get-ExoStatus {
    Write-AitherInfo 'Checking exo cluster status...'
    
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$ApiPort/healthcheck" -Method Get -ErrorAction Stop
        $topology = Invoke-RestMethod -Uri "http://localhost:$ApiPort/v1/topology" -Method Get -ErrorAction SilentlyContinue
        $models = Invoke-RestMethod -Uri "http://localhost:$ApiPort/v1/models" -Method Get -ErrorAction SilentlyContinue
        
        Write-Host ""
        Write-AitherSuccess "🟢 Exo cluster is RUNNING"
        Write-Host ""
        
        if ($topology -and $topology.nodes) {
            Write-Host "📊 Cluster Topology:"
            $nodes = $topology.nodes.PSObject.Properties
            $totalMemory = 0
            
            foreach ($node in $nodes) {
                $nodeData = $node.Value
                $caps = $nodeData.capabilities
                $memory = [math]::Round($caps.memory / 1024, 1)
                $totalMemory += $caps.memory
                Write-Host "   └── $($node.Name): $($caps.model) ($memory GB)"
            }
            
            Write-Host ""
            Write-Host "   Total Memory: $([math]::Round($totalMemory / 1024, 1)) GB"
        }
        
        if ($models -and $models.data) {
            Write-Host ""
            Write-Host "📦 Available Models:"
            foreach ($model in $models.data) {
                Write-Host "   └── $($model.id)"
            }
        }
        
        Write-Host ""
        Write-Host "🔗 Endpoints:"
        Write-Host "   WebUI: http://localhost:$ApiPort"
        Write-Host "   API:   http://localhost:$ApiPort/v1/chat/completions"
        
    } catch {
        Write-Host ""
        Write-AitherWarning "🔴 Exo cluster is NOT RUNNING"
        Write-Host ""
        Write-Host "Start the cluster with:"
        Write-Host "   .\0815_Manage-AitherExo.ps1 -Action Start"
        Write-Host ""
        Write-Host "Or join an existing cluster:"
        Write-Host "   .\0815_Manage-AitherExo.ps1 -Action Join -WaitForPeers 1"
    }
}

# Main execution
Write-ScriptHeader -ScriptName 'Manage AitherExo Cluster' -ScriptDescription 'Clustered LLM inference across GPU nodes'

switch ($Action) {
    'Start' {
        Start-ExoCluster
    }
    'Join' {
        if ($WaitForPeers -eq 0) {
            $WaitForPeers = 1
        }
        Start-ExoCluster -Join
    }
    'Stop' {
        Stop-ExoCluster
    }
    'Status' {
        Get-ExoStatus
    }
    'Install' {
        Install-Exo
    }
}

Write-ScriptFooter -ScriptName 'Manage AitherExo Cluster'
