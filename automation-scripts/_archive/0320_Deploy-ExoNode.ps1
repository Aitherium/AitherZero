<#
.SYNOPSIS
    Deploy AitherExo distributed compute nodes to remote machines.

.DESCRIPTION
    This script enables distributed AI inference across multiple machines using
    AitherExo (based on the exo project). It can:
    
    - Deploy AitherExo client to remote Windows/Linux machines
    - Configure nodes to join the mesh automatically
    - Distribute services (Canvas on GPU, LLM on local, etc.)
    - Manage the distributed compute cluster
    
    Architecture:
    ┌─────────────────────────────────────────────────────────────┐
    │                    AitherExo Cluster                        │
    │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
    │  │ Local Desktop│  │  Cloud GPU   │  │  Homelab Server  │  │
    │  │   (Primary)  │  │   (Canvas)   │  │   (Memory/LLM)   │  │
    │  │              │  │              │  │                  │  │
    │  │ • AitherNode │◄─►│ • Canvas    │◄─►│ • Spirit        │  │
    │  │ • Memory     │  │ • Vision     │  │ • WorkingMemory    │  │
    │  │ • Veil UI    │  │ • Parallel   │  │ • LLM (Ollama)  │  │
    │  │ • Chronicle  │  │ • Exo Node   │  │ • Exo Node      │  │
    │  └──────────────┘  └──────────────┘  └──────────────────┘  │
    │                          │                                  │
    │              Ring Topology via P2P Discovery                │
    └─────────────────────────────────────────────────────────────┘

.PARAMETER Action
    Action to perform: Deploy, Status, Add, Remove, ListNodes, Distribute

.PARAMETER Target
    Target hostname, IP, or comma-separated list

.PARAMETER Role
    Node role: gpu, memory, llm, standard

.PARAMETER Services
    Comma-separated list of specific services to deploy

.PARAMETER DiscoveryMethod
    How nodes discover each other: udp (LAN), tailscale, manual

.PARAMETER Credential
    PSCredential for remote connection

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Deploy to homelab server via SSH
    .\0320_Deploy-ExoNode.ps1 -Action Deploy -Target "192.168.1.100" -Role llm
    
.EXAMPLE
    # Check cluster status
    .\0320_Deploy-ExoNode.ps1 -Action Status
    
.EXAMPLE
    # Distribute Canvas to cloud GPU
    .\0320_Deploy-ExoNode.ps1 -Action Distribute -Target "gpu-cloud.example.com" -Services "Canvas,Vision,Parallel"
    
.EXAMPLE
    # List all nodes in the cluster
    .\0320_Deploy-ExoNode.ps1 -Action ListNodes
    
.NOTES
    Requires network connectivity to target nodes
    SSH or WinRM must be enabled on targets
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Deploy', 'Status', 'Add', 'Remove', 'ListNodes', 'Distribute', 'Configure')]
    [string]$Action = 'Status',
    
    [Parameter()]
    [string]$Target,
    
    [Parameter()]
    [ValidateSet('gpu', 'memory', 'llm', 'standard', 'minimal')]
    [string]$Role = 'standard',
    
    [Parameter()]
    [string]$Services,
    
    [Parameter()]
    [ValidateSet('udp', 'tailscale', 'manual')]
    [string]$DiscoveryMethod = 'udp',
    
    [Parameter()]
    [string]$TailscaleApiKey,
    
    [Parameter()]
    [string]$TailnetName,
    
    [Parameter()]
    [PSCredential]$Credential,
    
    [Parameter()]
    [string]$SSHKeyPath,
    
    [Parameter()]
    [switch]$UseSSH,
    
    [Parameter()]
    [int]$SSHPort = 22,
    
    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
. (Join-Path $scriptDir '_init.ps1')

#region Configuration

# Role definitions - which services run on each role
$RoleServices = @{
    'gpu' = @{
        Description = 'GPU compute node for Canvas/Vision'
        Services = @('Exo', 'ExoNodes', 'Canvas', 'Vision', 'Parallel', 'Force', 'Accel')
        RequiresGPU = $true
    }
    'memory' = @{
        Description = 'Memory and vector database services'
        Services = @('Spirit', 'WorkingMemory', 'Context', 'Chain', 'SensoryBuffer', 'Conduit')
        RequiresGPU = $false
    }
    'llm' = @{
        Description = 'LLM inference node'
        Services = @('LLM', 'Mind', 'Reasoning', 'Judge', 'Flow', 'Safety')
        RequiresGPU = $false
    }
    'standard' = @{
        Description = 'Standard AitherOS node'
        Services = @('Node', 'Chronicle', 'Pulse', 'Watch', 'Gateway', 'Mesh')
        RequiresGPU = $false
    }
    'minimal' = @{
        Description = 'Minimal exo-only node'
        Services = @('Exo', 'ExoNodes')
        RequiresGPU = $true
    }
}

$NodeConfigPath = Join-Path $env:AITHERZERO_ROOT 'AitherOS' 'config' 'exo-nodes.json'
$LocalApiPort = 52415

#endregion

#region Functions

function Get-NodeConfig {
    if (Test-Path $NodeConfigPath) {
        return Get-Content $NodeConfigPath | ConvertFrom-Json
    }
    return @{ nodes = @() }
}

function Save-NodeConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 10 | Set-Content $NodeConfigPath
}

function Test-RemoteConnection {
    param(
        [string]$Host,
        [PSCredential]$Cred,
        [switch]$SSH
    )
    
    if ($SSH) {
        # Test SSH connection
        $sshCmd = "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no"
        if ($SSHKeyPath) { $sshCmd += " -i '$SSHKeyPath'" }
        $sshCmd += " ${Host} 'echo ok'"
        
        try {
            $result = Invoke-Expression $sshCmd 2>&1
            return $result -eq 'ok'
        } catch {
            return $false
        }
    } else {
        # Test WinRM connection
        try {
            if ($Cred) {
                Test-WSMan -ComputerName $Host -Credential $Cred -ErrorAction Stop | Out-Null
            } else {
                Test-WSMan -ComputerName $Host -ErrorAction Stop | Out-Null
            }
            return $true
        } catch {
            return $false
        }
    }
}

function Invoke-RemoteCommand {
    param(
        [string]$Host,
        [string]$Command,
        [PSCredential]$Cred,
        [switch]$SSH
    )
    
    if ($SSH) {
        $sshCmd = "ssh -o StrictHostKeyChecking=no"
        if ($SSHKeyPath) { $sshCmd += " -i '$SSHKeyPath'" }
        $sshCmd += " ${Host} '$Command'"
        
        return Invoke-Expression $sshCmd
    } else {
        if ($Cred) {
            return Invoke-Command -ComputerName $Host -Credential $Cred -ScriptBlock { param($c) Invoke-Expression $c } -ArgumentList $Command
        } else {
            return Invoke-Command -ComputerName $Host -ScriptBlock { param($c) Invoke-Expression $c } -ArgumentList $Command
        }
    }
}

function Deploy-ExoNode {
    param(
        [string]$TargetHost,
        [string]$NodeRole,
        [string[]]$NodeServices
    )
    
    Write-AitherInfo "Deploying AitherExo node to $TargetHost (Role: $NodeRole)"
    
    # Test connectivity
    $canConnect = Test-RemoteConnection -Host $TargetHost -Cred $Credential -SSH:$UseSSH
    if (-not $canConnect) {
        Write-AitherError "Cannot connect to $TargetHost"
        return $false
    }
    
    $roleConfig = $RoleServices[$NodeRole]
    $servicesToDeploy = if ($NodeServices) { $NodeServices } else { $roleConfig.Services }
    
    Write-AitherInfo "Services to deploy: $($servicesToDeploy -join ', ')"
    
    # Generate deployment script
    $servicesJson = ($servicesToDeploy | ConvertTo-Json -Compress)
    
    $deployScript = @'
#!/usr/bin/env bash
set -e

echo "=== AitherExo Node Deployment ==="

# Detect OS
if [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ -n "$WINDIR" ]]; then
    OS="windows"
elif [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
else
    OS="linux"
fi

echo "Detected OS: $OS"

# Install prerequisites
if [[ "$OS" == "linux" ]]; then
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv git
    elif command -v yum &> /dev/null; then
        sudo yum install -y python3 python3-pip git
    fi
elif [[ "$OS" == "macos" ]]; then
    brew install python3 git 2>/dev/null || true
fi

# Setup AitherOS directory
AITHER_HOME="/opt/aitheros"
if [[ "$OS" == "windows" ]]; then
    AITHER_HOME="C:/AitherOS"
fi

sudo mkdir -p $AITHER_HOME 2>/dev/null || mkdir -p $AITHER_HOME
cd $AITHER_HOME

# Clone or update AitherOS
if [ ! -d ".git" ]; then
    git clone https://github.com/Aither-AI/AitherOS.git .
else
    git pull
fi

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install --upgrade pip
pip install -r requirements.txt
pip install exo  # Distributed inference

# Create node configuration
'@ + @"

cat > config/exo-node.yaml << 'EOF'
node_id: '$(hostname)'
role: '$NodeRole'
services: $servicesJson
discovery:
  method: '$DiscoveryMethod'
mesh:
  enabled: true
  port: 8125
exo:
  enabled: true
  api_port: $LocalApiPort
  node_port: 5678
EOF

"@ + @'

echo "=== Starting AitherExo Node ==="

# Start exo in background
nohup python -m exo.main \
    --discovery-module $DISCOVERY_METHOD \
    --chatgpt-api-port $API_PORT \
    --node-port 5678 \
    > /var/log/aither-exo.log 2>&1 &

echo "AitherExo node deployed successfully!"
echo "API available at: http://$(hostname):$API_PORT"
'@
    
    $deployScript = $deployScript -replace '\$DISCOVERY_METHOD', $DiscoveryMethod
    $deployScript = $deployScript -replace '\$API_PORT', $LocalApiPort
    
    try {
        if ($UseSSH) {
            # Save script locally and scp it
            $tempScript = Join-Path $env:TEMP "deploy-exo-$TargetHost.sh"
            $deployScript | Set-Content -Path $tempScript -Encoding UTF8
            
            $scpCmd = "scp"
            if ($SSHKeyPath) { $scpCmd += " -i '$SSHKeyPath'" }
            $scpCmd += " '$tempScript' ${TargetHost}:/tmp/deploy-exo.sh"
            Invoke-Expression $scpCmd
            
            Invoke-RemoteCommand -Host $TargetHost -Command "chmod +x /tmp/deploy-exo.sh && /tmp/deploy-exo.sh" -SSH
            
            Remove-Item $tempScript -Force
        } else {
            # WinRM deployment for Windows
            $psDeployScript = @"
`$ErrorActionPreference = 'Stop'

# Install prerequisites
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    winget install Python.Python.3.11 --silent --accept-source-agreements
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install Git.Git --silent --accept-source-agreements
}

`$aitherPath = 'C:\AitherOS'
if (-not (Test-Path `$aitherPath)) {
    git clone https://github.com/Aither-AI/AitherOS.git `$aitherPath
}

Set-Location `$aitherPath
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
pip install exo

# Create config
@"
node_id: `$env:COMPUTERNAME
role: '$NodeRole'
services: $servicesJson
"@ | Set-Content config\exo-node.yaml

# Start exo
Start-Process -FilePath python -ArgumentList '-m', 'exo.main', '--discovery-module', '$DiscoveryMethod' -NoNewWindow

Write-Host 'AitherExo node deployed successfully!'
"@
            
            Invoke-RemoteCommand -Host $TargetHost -Command $psDeployScript -Cred $Credential
        }
        
        # Register node in local config
        $config = Get-NodeConfig
        $newNode = @{
            id = $TargetHost
            role = $NodeRole
            services = $servicesToDeploy
            added = (Get-Date -Format 'o')
            status = 'deployed'
        }
        
        # Remove existing entry if present
        $config.nodes = @($config.nodes | Where-Object { $_.id -ne $TargetHost })
        $config.nodes += $newNode
        Save-NodeConfig -Config $config
        
        Write-AitherSuccess "Node $TargetHost deployed successfully"
        return $true
    } catch {
        Write-AitherError "Deployment failed: $_"
        return $false
    }
}

function Get-ClusterStatus {
    Write-AitherInfo "Checking AitherExo cluster status..."
    
    # Check local exo API
    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$LocalApiPort/healthcheck" -Method Get -TimeoutSec 5 -ErrorAction Stop
        $topology = Invoke-RestMethod -Uri "http://localhost:$LocalApiPort/v1/topology" -Method Get -TimeoutSec 5 -ErrorAction SilentlyContinue
        $models = Invoke-RestMethod -Uri "http://localhost:$LocalApiPort/v1/models" -Method Get -TimeoutSec 5 -ErrorAction SilentlyContinue
        
        Write-Host ""
        Write-AitherSuccess "🟢 AitherExo Cluster ONLINE"
        Write-Host ""
        
        if ($topology -and $topology.nodes) {
            Write-Host "📊 Cluster Topology:" -ForegroundColor Cyan
            $nodes = $topology.nodes.PSObject.Properties
            $totalMemory = 0
            
            foreach ($node in $nodes) {
                $nodeData = $node.Value
                $caps = $nodeData.capabilities
                $memory = [math]::Round($caps.memory / 1024, 1)
                $totalMemory += $caps.memory
                
                $gpuIcon = if ($caps.has_gpu) { "🎮" } else { "💻" }
                Write-Host "   $gpuIcon $($node.Name): $($caps.model) (${memory}GB VRAM)"
            }
            
            Write-Host ""
            Write-Host "   Total Cluster Memory: $([math]::Round($totalMemory / 1024, 1)) GB" -ForegroundColor Yellow
        }
        
        if ($models -and $models.data) {
            Write-Host ""
            Write-Host "📦 Available Models:" -ForegroundColor Cyan
            foreach ($model in $models.data) {
                Write-Host "   └── $($model.id)"
            }
        }
        
        Write-Host ""
        Write-Host "🔗 Endpoints:" -ForegroundColor Cyan
        Write-Host "   WebUI: http://localhost:$LocalApiPort"
        Write-Host "   API:   http://localhost:$LocalApiPort/v1/chat/completions"
        
    } catch {
        Write-Host ""
        Write-AitherWarning "🔴 AitherExo cluster is NOT RUNNING locally"
        Write-Host ""
        Write-Host "Start the cluster with:"
        Write-Host "   .\0815_Manage-AitherExo.ps1 -Action Start"
    }
    
    # Show registered nodes
    $config = Get-NodeConfig
    if ($config.nodes -and $config.nodes.Count -gt 0) {
        Write-Host ""
        Write-Host "📋 Registered Nodes:" -ForegroundColor Cyan
        foreach ($node in $config.nodes) {
            $statusIcon = switch ($node.status) {
                'deployed' { "🟢" }
                'offline' { "🔴" }
                default { "🟡" }
            }
            Write-Host "   $statusIcon $($node.id) [$($node.role)] - $($node.services -join ', ')"
        }
    }
}

function Get-ClusterNodes {
    Write-AitherInfo "Listing cluster nodes..."
    
    $config = Get-NodeConfig
    
    if (-not $config.nodes -or $config.nodes.Count -eq 0) {
        Write-Host ""
        Write-AitherWarning "No nodes registered in the cluster"
        Write-Host ""
        Write-Host "Add a node with:"
        Write-Host "   .\0320_Deploy-ExoNode.ps1 -Action Deploy -Target <hostname> -Role gpu"
        return
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "                    AitherExo Cluster Nodes                      " -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    foreach ($node in $config.nodes) {
        $roleConfig = $RoleServices[$node.role]
        Write-Host "┌─ $($node.id)" -ForegroundColor Yellow
        Write-Host "│  Role:     $($node.role) ($($roleConfig.Description))" -ForegroundColor White
        Write-Host "│  Services: $($node.services -join ', ')" -ForegroundColor White
        Write-Host "│  Added:    $($node.added)" -ForegroundColor DarkGray
        Write-Host "│  Status:   $($node.status)" -ForegroundColor White
        Write-Host "└────────────────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
    }
}

function Distribute-Services {
    param(
        [string]$TargetHost,
        [string[]]$ServiceList
    )
    
    Write-AitherInfo "Distributing services to $TargetHost..."
    Write-AitherInfo "Services: $($ServiceList -join ', ')"
    
    # This updates the node's service configuration and restarts relevant services
    $config = Get-NodeConfig
    $node = $config.nodes | Where-Object { $_.id -eq $TargetHost }
    
    if (-not $node) {
        Write-AitherWarning "Node $TargetHost not found. Deploying first..."
        Deploy-ExoNode -TargetHost $TargetHost -NodeRole 'standard' -NodeServices $ServiceList
        return
    }
    
    # Update node services
    $node.services = $ServiceList
    $node.status = 'updating'
    Save-NodeConfig -Config $config
    
    # Restart services on remote node
    $restartCmd = @"
Set-Location 'C:\AitherOS'
.\.venv\Scripts\Activate.ps1

# Stop existing services
Get-Process python* | Stop-Process -Force -ErrorAction SilentlyContinue

# Start only specified services
\$services = @('$($ServiceList -join "','")') 
python -m aitheros.start --services \$services
"@
    
    try {
        Invoke-RemoteCommand -Host $TargetHost -Command $restartCmd -Cred $Credential -SSH:$UseSSH
        
        $node.status = 'deployed'
        Save-NodeConfig -Config $config
        
        Write-AitherSuccess "Services distributed to $TargetHost"
    } catch {
        Write-AitherError "Failed to distribute services: $_"
    }
}

function Remove-Node {
    param([string]$TargetHost)
    
    Write-AitherInfo "Removing node $TargetHost from cluster..."
    
    $config = Get-NodeConfig
    $config.nodes = @($config.nodes | Where-Object { $_.id -ne $TargetHost })
    Save-NodeConfig -Config $config
    
    Write-AitherSuccess "Node $TargetHost removed from cluster registry"
    Write-AitherInfo "Note: AitherOS is still installed on the remote machine"
}

#endregion

#region Main Execution

Write-ScriptHeader -ScriptName 'Deploy AitherExo Node' -ScriptDescription 'Distributed compute node management'

switch ($Action) {
    'Deploy' {
        if (-not $Target) {
            Write-AitherError "Target hostname required. Use -Target <hostname>"
            exit 1
        }
        
        $serviceList = if ($Services) { $Services -split ',' } else { $null }
        
        foreach ($host in ($Target -split ',')) {
            Deploy-ExoNode -TargetHost $host.Trim() -NodeRole $Role -NodeServices $serviceList
        }
    }
    
    'Status' {
        Get-ClusterStatus
    }
    
    'ListNodes' {
        Get-ClusterNodes
    }
    
    'Add' {
        if (-not $Target) {
            Write-AitherError "Target hostname required"
            exit 1
        }
        
        # Quick add without full deployment
        $config = Get-NodeConfig
        $newNode = @{
            id = $Target
            role = $Role
            services = if ($Services) { $Services -split ',' } else { $RoleServices[$Role].Services }
            added = (Get-Date -Format 'o')
            status = 'registered'
        }
        $config.nodes = @($config.nodes | Where-Object { $_.id -ne $Target })
        $config.nodes += $newNode
        Save-NodeConfig -Config $config
        
        Write-AitherSuccess "Node $Target registered"
    }
    
    'Remove' {
        if (-not $Target) {
            Write-AitherError "Target hostname required"
            exit 1
        }
        Remove-Node -TargetHost $Target
    }
    
    'Distribute' {
        if (-not $Target -or -not $Services) {
            Write-AitherError "Both -Target and -Services required"
            exit 1
        }
        Distribute-Services -TargetHost $Target -ServiceList ($Services -split ',')
    }
    
    'Configure' {
        Write-AitherInfo "Opening cluster configuration..."
        if (Test-Path $NodeConfigPath) {
            code $NodeConfigPath
        } else {
            @{ nodes = @() } | ConvertTo-Json | Set-Content $NodeConfigPath
            code $NodeConfigPath
        }
    }
}

Write-ScriptFooter -ScriptName 'Deploy AitherExo Node'

#endregion
