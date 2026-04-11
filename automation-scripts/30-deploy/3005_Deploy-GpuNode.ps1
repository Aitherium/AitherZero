#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys AitherClient to a rented GPU instance (Vast.ai) with mTLS authentication.

.DESCRIPTION
    This script automates the entire GPU rental and deployment workflow:
    1. Searches for available GPU offers matching your requirements
    2. Creates a new instance on Vast.ai
    3. Waits for the instance to be ready
    4. Requests mTLS certificates from AitherSecrets CA
    5. Deploys AitherClient with certificates
    6. Sets up Cloudflare tunnels for service access
    7. Registers the node with AitherGateway

.PARAMETER GpuModel
    GPU model to search for (e.g., RTX_4090, RTX_3090, A100)

.PARAMETER MinVram
    Minimum VRAM in GB (default: 24)

.PARAMETER MaxPrice
    Maximum price per hour in USD (default: 0.50)

.PARAMETER Services
    Comma-separated list of services to deploy (default: comfyui,ollama)

.PARAMETER GatewayUrl
    AitherGateway URL for mesh registration

.PARAMETER SecretsUrl
    AitherSecrets URL for certificate issuance

.PARAMETER UsePsk
    Use PSK authentication instead of mTLS

.PARAMETER Psk
    Pre-shared key for PSK authentication

.PARAMETER DiskGb
    Disk space to allocate in GB (default: 50)

.PARAMETER DryRun
    Show what would be done without creating instance

.EXAMPLE
    # Deploy with defaults (RTX 4090, mTLS, comfyui+ollama)
    .\0825_Deploy-GpuNode.ps1

.EXAMPLE
    # Deploy specific GPU with custom services
    .\0825_Deploy-GpuNode.ps1 -GpuModel RTX_3090 -Services "comfyui,sdxl" -MaxPrice 0.30

.EXAMPLE
    # Deploy with PSK instead of mTLS
    .\0825_Deploy-GpuNode.ps1 -UsePsk -Psk "my-secret-key"

.NOTES
    Author: Aitherium
    Priority: P621
    Dependencies: vastai CLI, Python 3.10+
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$GpuModel = "RTX_4090",
    [int]$MinVram = 24,
    [decimal]$MaxPrice = 0.50,
    [string]$Services = "comfyui,ollama",
    [string]$GatewayUrl = "",
    [string]$SecretsUrl = "",
    [switch]$UsePsk,
    [string]$Psk = "",
    [int]$DiskGb = 50,
    [switch]$DryRun,
    [switch]$ShowOffers
)

# Initialize
. $PSScriptRoot/_init.ps1

$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

$PYTHON_VENV = Join-Path $AITHEROS_ROOT ".venv/Scripts/python.exe"
if (-not (Test-Path $PYTHON_VENV)) {
    $PYTHON_VENV = "python"
}

# Default URLs from AitherPorts
$DEFAULT_GATEWAY_PORT = 8120
$DEFAULT_SECRETS_PORT = 8111

if (-not $GatewayUrl) {
    $GatewayUrl = "http://localhost:$DEFAULT_GATEWAY_PORT"
}

if (-not $SecretsUrl) {
    $SecretsUrl = "http://localhost:$DEFAULT_SECRETS_PORT"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Test-VastAiCli {
    try {
        $null = vastai --version 2>$null
        return $true
    } catch {
        return $false
    }
}

function Test-VastAiAuth {
    try {
        $result = vastai show instances --raw 2>$null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Get-VastAiOffers {
    param(
        [string]$GpuModel,
        [int]$MinVram,
        [decimal]$MaxPrice,
        [int]$Limit = 10
    )
    
    $query = @(
        "gpu_ram >= $MinVram"
        "dph_total <= $MaxPrice"
        "reliability > 0.95"
        "verified = true"
        "rentable = true"
    )
    
    if ($GpuModel) {
        $query += "gpu_name = $GpuModel"
    }
    
    $queryStr = $query -join " "
    
    Write-Host "🔍 Searching for GPU offers: $queryStr" -ForegroundColor Cyan
    
    $offersJson = vastai search offers "$queryStr" -o dph_total --raw 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Vast.ai search failed. Using fallback query..."
        $queryStr = "gpu_ram >= $MinVram dph_total <= $MaxPrice reliability > 0.95"
        $offersJson = vastai search offers "$queryStr" -o dph_total --raw 2>$null
    }
    
    try {
        $offers = $offersJson | ConvertFrom-Json
        return $offers | Select-Object -First $Limit
    } catch {
        Write-Error "Failed to parse Vast.ai offers: $_"
        return @()
    }
}

function New-VastAiInstance {
    param(
        [string]$OfferId,
        [int]$DiskGb,
        [string]$Image = "nvidia/cuda:12.1.0-runtime-ubuntu22.04"
    )
    
    Write-Host "🚀 Creating instance from offer $OfferId..." -ForegroundColor Green
    
    $result = vastai create instance $OfferId `
        --image $Image `
        --disk $DiskGb `
        --ssh `
        --direct `
        --raw 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create instance: $result"
    }
    
    # Parse instance ID
    if ($result -match "'new_contract':\s*(\d+)") {
        return $Matches[1]
    } elseif ($result -match '"new_contract":\s*(\d+)') {
        return $Matches[1]
    } else {
        try {
            $data = $result | ConvertFrom-Json
            return $data.new_contract
        } catch {
            throw "Could not parse instance ID from: $result"
        }
    }
}

function Wait-VastAiInstance {
    param(
        [string]$InstanceId,
        [int]$TimeoutSeconds = 600,
        [int]$PollInterval = 15
    )
    
    Write-Host "⏳ Waiting for instance $InstanceId to be ready..." -ForegroundColor Yellow
    
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        try {
            $infoJson = vastai show instance $InstanceId --raw 2>$null
            $info = $infoJson | ConvertFrom-Json
            
            if ($info.Count -gt 0) {
                $instance = $info[0]
            } else {
                $instance = $info
            }
            
            $status = $instance.actual_status
            $sshHost = $instance.ssh_host
            $sshPort = $instance.ssh_port
            
            Write-Host "  Status: $status, SSH: $sshHost`:$sshPort" -ForegroundColor DarkGray
            
            if ($status -eq "running" -and $sshHost) {
                Write-Host "✅ Instance is ready!" -ForegroundColor Green
                return @{
                    InstanceId = $InstanceId
                    SshHost = $sshHost
                    SshPort = $sshPort
                    GpuModel = $instance.gpu_name
                    VramGb = [int]$instance.gpu_ram
                    PricePerHour = [decimal]$instance.dph_total
                }
            }
            
            if ($status -eq "error") {
                throw "Instance entered error state"
            }
        } catch {
            Write-Warning "Status check failed: $_"
        }
        
        Start-Sleep -Seconds $PollInterval
        $elapsed += $PollInterval
    }
    
    throw "Timeout waiting for instance to be ready"
}

function Deploy-AitherClient {
    param(
        [hashtable]$Instance,
        [string[]]$Services,
        [string]$GatewayUrl,
        [string]$SecretsUrl,
        [bool]$UseMtls,
        [string]$Psk
    )
    
    $nodeId = "vast-$($Instance.InstanceId.Substring(0, 8))"
    $sshTarget = "$($Instance.SshHost) -p $($Instance.SshPort)"
    
    Write-Host "🔐 Deploying AitherClient to node: $nodeId" -ForegroundColor Cyan
    
    # Prepare deployment script
    $servicesStr = $Services -join ","
    $authMode = if ($UseMtls) { "mtls" } else { "psk" }
    
    # Build certificate section
    $certSection = ""
    if ($UseMtls) {
        Write-Host "  📜 Requesting mTLS certificate from $SecretsUrl..." -ForegroundColor Yellow
        
        try {
            # Request certificate
            $certResponse = Invoke-RestMethod -Uri "$SecretsUrl/ca/issue/$nodeId" -Method POST -Body (@{
                validity_days = 365
                key_type = "ec"
            } | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            
            # Get CA chain
            $chainResponse = Invoke-RestMethod -Uri "$SecretsUrl/ca/chain" -Method GET -ErrorAction Stop
            
            Write-Host "  ✅ Certificate obtained for $nodeId" -ForegroundColor Green
            
            $certSection = @"
# Install mTLS certificates
mkdir -p ~/.aither/certs
chmod 700 ~/.aither/certs

cat > ~/.aither/certs/client.crt << 'CERT_EOF'
$($certResponse.certificate)
CERT_EOF

cat > ~/.aither/certs/client.key << 'KEY_EOF'
$($certResponse.private_key)
KEY_EOF

cat > ~/.aither/certs/ca-chain.crt << 'CHAIN_EOF'
$($chainResponse.chain)
CHAIN_EOF

chmod 600 ~/.aither/certs/client.key
echo "mTLS certificates installed"
"@
        } catch {
            Write-Warning "Certificate request failed: $_ - falling back to PSK"
            $authMode = "psk"
        }
    }
    
    # Create deployment script
    $deployScript = @"
#!/bin/bash
set -e

echo "=== AitherClient Deployment ==="
echo "Node ID: $nodeId"
echo "Services: $servicesStr"
echo "Auth Mode: $authMode"

# Install dependencies
apt-get update -qq
apt-get install -y -qq python3-pip curl jq

# Install cloudflared
if ! command -v cloudflared &> /dev/null; then
    echo "Installing cloudflared..."
    curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

# Install Python dependencies
pip install -q httpx pyyaml cryptography

# Create config directory
mkdir -p ~/.aither

$certSection

# Create AitherClient configuration
cat > ~/.aither/client.json << 'CONFIG_EOF'
{
    "name": "$nodeId",
    "gateway_host": "$(([uri]$GatewayUrl).Host)",
    "gateway_port": $(([uri]$GatewayUrl).Port),
    "auth_mode": "$authMode",
    "heartbeat_interval": 30,
    "capabilities": {
        "gpu": "$($Instance.GpuModel)",
        "vram_gb": $($Instance.VramGb),
        "provider": "vast_ai"
    }
}
CONFIG_EOF

# Download AitherClient
echo "Downloading AitherClient..."
curl -sL "https://raw.githubusercontent.com/Aitherium/AitherOS/main/AitherOS/AitherNode/lib/AitherClient.py" -o ~/.aither/AitherClient.py

# Register with gateway
echo "Registering with AitherGateway..."
python3 ~/.aither/AitherClient.py join-mtls --gateway $(([uri]$GatewayUrl).Host) --port $(([uri]$GatewayUrl).Port) --name $nodeId 2>/dev/null || \
python3 ~/.aither/AitherClient.py join --gateway $(([uri]$GatewayUrl).Host) --port $(([uri]$GatewayUrl).Port) --psk "$Psk" --name $nodeId 2>/dev/null || \
echo "Direct registration, will use heartbeat"

# Start services
echo "Starting services: $servicesStr"

for service in \$(echo "$servicesStr" | tr ',' ' '); do
    case \$service in
        comfyui)
            echo "Starting ComfyUI..."
            if command -v comfyui &> /dev/null; then
                comfyui --listen 0.0.0.0 --port 8188 &
            fi
            ;;
        ollama)
            echo "Starting Ollama..."
            if command -v ollama &> /dev/null; then
                ollama serve &
            fi
            ;;
    esac
done

# Create tunnels
echo "Setting up Cloudflare tunnels..."
TUNNEL_LOG=/tmp/tunnel_urls.txt
> \$TUNNEL_LOG

for service in \$(echo "$servicesStr" | tr ',' ' '); do
    case \$service in
        comfyui)
            cloudflared tunnel --url http://localhost:8188 2>&1 | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | head -1 >> \$TUNNEL_LOG &
            ;;
        ollama)
            cloudflared tunnel --url http://localhost:11434 2>&1 | grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' | head -1 >> \$TUNNEL_LOG &
            ;;
    esac
done

# Wait for tunnels
sleep 10
echo "=== Tunnel URLs ==="
cat \$TUNNEL_LOG

# Start AitherClient daemon
echo "Starting AitherClient heartbeat daemon..."
nohup python3 ~/.aither/AitherClient.py daemon --interval 30 > /var/log/aither-client.log 2>&1 &

echo "=== Deployment Complete ==="
echo "Node ID: $nodeId"
echo "GPU: $($Instance.GpuModel) ($($Instance.VramGb)GB VRAM)"
echo "Services: $servicesStr"
echo "Auth Mode: $authMode"
"@

    # Save script locally
    $scriptPath = Join-Path $env:TEMP "aither_deploy_$nodeId.sh"
    $deployScript | Set-Content -Path $scriptPath -Encoding utf8
    
    # Copy and execute on remote
    Write-Host "  📤 Copying deployment script..." -ForegroundColor Yellow
    
    try {
        # Copy script
        scp -P $($Instance.SshPort) -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" `
            $scriptPath "root@$($Instance.SshHost):/tmp/deploy.sh"
        
        # Execute
        Write-Host "  ▶️ Executing deployment..." -ForegroundColor Yellow
        ssh -p $($Instance.SshPort) -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=/dev/null" `
            "root@$($Instance.SshHost)" "chmod +x /tmp/deploy.sh && /tmp/deploy.sh"
        
        Write-Host "✅ AitherClient deployed successfully!" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "Deployment failed: $_"
        return $false
    } finally {
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       AitherClient GPU Node Deployment (Vast.ai)                  ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check prerequisites
Write-Host "📋 Checking prerequisites..." -ForegroundColor Yellow

if (-not (Test-VastAiCli)) {
    Write-Error "Vast.ai CLI not installed. Install with: pip install vastai"
    exit 1
}

if (-not (Test-VastAiAuth)) {
    Write-Error "Vast.ai not authenticated. Run: vastai set api-key YOUR_API_KEY"
    exit 1
}

Write-Host "  ✅ Vast.ai CLI ready" -ForegroundColor Green

# Display configuration
Write-Host ""
Write-Host "📊 Configuration:" -ForegroundColor Yellow
Write-Host "  GPU Model:    $GpuModel"
Write-Host "  Min VRAM:     $MinVram GB"
Write-Host "  Max Price:    `$$MaxPrice/hr"
Write-Host "  Services:     $Services"
Write-Host "  Disk:         $DiskGb GB"
Write-Host "  Auth Mode:    $(if ($UsePsk) { 'PSK' } else { 'mTLS' })"
Write-Host "  Gateway:      $GatewayUrl"
Write-Host "  Secrets:      $SecretsUrl"
Write-Host ""

# Search for offers
$offers = Get-VastAiOffers -GpuModel $GpuModel -MinVram $MinVram -MaxPrice $MaxPrice

if ($offers.Count -eq 0) {
    Write-Error "No GPU offers found matching criteria. Try increasing -MaxPrice or changing -GpuModel"
    exit 1
}

Write-Host "📋 Found $($offers.Count) offers:" -ForegroundColor Green
$offers | Select-Object -First 5 | ForEach-Object {
    Write-Host "  [$($_.id)] $($_.gpu_name) ($([int]$_.gpu_ram)GB) - `$$([math]::Round($_.dph_total, 3))/hr - $($_.geolocation)" -ForegroundColor DarkGray
}
Write-Host ""

if ($ShowOffers) {
    Write-Host "Use -OfferId <id> to create an instance from a specific offer"
    exit 0
}

if ($DryRun) {
    Write-Host "🔍 DRY RUN - Would create instance from offer $($offers[0].id)" -ForegroundColor Yellow
    exit 0
}

# Select best offer (cheapest)
$selectedOffer = $offers[0]
Write-Host "✨ Selected: $($selectedOffer.gpu_name) at `$$([math]::Round($selectedOffer.dph_total, 3))/hr" -ForegroundColor Green

if (-not $PSCmdlet.ShouldProcess("Create Vast.ai instance from offer $($selectedOffer.id)", "Deploy GPU Node")) {
    exit 0
}

# Create instance
$instanceId = New-VastAiInstance -OfferId $selectedOffer.id -DiskGb $DiskGb

Write-Host "🎉 Instance created: $instanceId" -ForegroundColor Green

# Wait for ready
$instance = Wait-VastAiInstance -InstanceId $instanceId

# Deploy AitherClient
$serviceList = $Services -split ','
$deployed = Deploy-AitherClient `
    -Instance $instance `
    -Services $serviceList `
    -GatewayUrl $GatewayUrl `
    -SecretsUrl $SecretsUrl `
    -UseMtls (-not $UsePsk) `
    -Psk $Psk

if ($deployed) {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                    DEPLOYMENT SUCCESSFUL                           ║" -ForegroundColor Green
    Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "Instance ID:  $instanceId" -ForegroundColor Cyan
    Write-Host "GPU:          $($instance.GpuModel) ($($instance.VramGb)GB)" -ForegroundColor Cyan
    Write-Host "SSH:          ssh -p $($instance.SshPort) root@$($instance.SshHost)" -ForegroundColor Cyan
    Write-Host "Cost:         `$$($instance.PricePerHour)/hr" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Node should now appear in AitherGateway /gpu/nodes" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To destroy: vastai destroy instance $instanceId" -ForegroundColor DarkGray
} else {
    Write-Error "Deployment failed. Instance $instanceId is still running - destroy manually if needed."
    exit 1
}
