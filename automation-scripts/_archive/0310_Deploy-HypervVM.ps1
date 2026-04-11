<#
.SYNOPSIS
    Fully deploy an AitherOS node to Hyper-V with automated provisioning.

.DESCRIPTION
    This script provides complete Hyper-V VM deployment automation including:
    - VM creation with configurable resources
    - Virtual switch and network configuration
    - Disk provisioning (VHD/VHDX)
    - ISO-based or image-based installation
    - Post-deployment AitherNode installation
    - Service selection (which AitherOS services to run)
    - AitherExo cluster integration
    
    Supports multiple deployment templates:
    - minimal: Core services only (Chronicle, Node, Pulse)
    - standard: Full AitherOS stack minus GPU services
    - gpu: Full stack with GPU passthrough for Canvas/Parallel
    - exo-node: Lightweight node for distributed inference cluster
    - memory: Memory/Vector services (Spirit, WorkingMemory, Context)
    - llm: LLM inference node (LLM, Reasoning, Mind)

.PARAMETER VMName
    Name of the virtual machine to create

.PARAMETER Template
    Deployment template: minimal, standard, gpu, exo-node, memory, llm

.PARAMETER MemoryGB
    Startup memory in GB (default: 8)

.PARAMETER CPUs
    Number of virtual processors (default: 4)

.PARAMETER DiskSizeGB
    VHD disk size in GB (default: 100)

.PARAMETER SwitchName
    Virtual switch to attach (default: 'Default Switch')

.PARAMETER ISOPath
    Path to installation ISO (for fresh installs)

.PARAMETER ImagePath
    Path to pre-built VHDX image (faster deployment)

.PARAMETER IPAddress
    Static IP to assign (optional, DHCP if not specified)

.PARAMETER JoinExoCluster
    Join this VM to the AitherExo distributed cluster

.PARAMETER InstallAitherNode
    Install and configure AitherNode after VM creation

.PARAMETER AutoStart
    Start VM automatically after creation

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    # Deploy a minimal AitherOS node
    .\0310_Deploy-HypervVM.ps1 -VMName "aither-node-01" -Template minimal
    
.EXAMPLE
    # Deploy GPU node for Canvas with passthrough
    .\0310_Deploy-HypervVM.ps1 -VMName "aither-gpu-01" -Template gpu -MemoryGB 32 -CPUs 8
    
.EXAMPLE
    # Deploy exo node and join cluster
    .\0310_Deploy-HypervVM.ps1 -VMName "exo-01" -Template exo-node -JoinExoCluster
    
.EXAMPLE
    # Deploy memory services node with static IP
    .\0310_Deploy-HypervVM.ps1 -VMName "aither-memory" -Template memory -IPAddress "192.168.1.50"

.NOTES
    Requires Hyper-V role enabled (run 0105_Install-HyperV.ps1 first)
    Requires Administrator privileges
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$VMName,
    
    [Parameter()]
    [ValidateSet('minimal', 'standard', 'gpu', 'exo-node', 'memory', 'llm')]
    [string]$Template = 'standard',
    
    [Parameter()]
    [int]$MemoryGB = 8,
    
    [Parameter()]
    [int]$CPUs = 4,
    
    [Parameter()]
    [int]$DiskSizeGB = 100,
    
    [Parameter()]
    [string]$SwitchName = 'Default Switch',
    
    [Parameter()]
    [string]$ISOPath,
    
    [Parameter()]
    [string]$ImagePath,
    
    [Parameter()]
    [string]$IPAddress,
    
    [Parameter()]
    [string]$Gateway,
    
    [Parameter()]
    [string]$DNSServer = '8.8.8.8',
    
    [Parameter()]
    [switch]$JoinExoCluster,
    
    [Parameter()]
    [switch]$InstallAitherNode,
    
    [Parameter()]
    [switch]$AutoStart,
    
    [Parameter()]
    [switch]$EnableGPU,
    
    [Parameter()]
    [string]$GPUDeviceID,
    
    [Parameter()]
    [PSCredential]$VMCredential,
    
    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
. (Join-Path $scriptDir '_init.ps1')

#region Configuration

# Template definitions - which services to deploy
$TemplateConfigs = @{
    'minimal' = @{
        Description = 'Core services only'
        Services = @('Chronicle', 'Node', 'Pulse', 'Watch')
        MinMemoryGB = 4
        MinCPUs = 2
    }
    'standard' = @{
        Description = 'Full AitherOS without GPU'
        Services = @('Chronicle', 'Node', 'Pulse', 'Watch', 'Mind', 'LLM', 'Spirit', 
                    'WorkingMemory', 'Context', 'Search', 'Scheduler', 'Autonomic',
                    'Identity', 'Flux', 'Secrets', 'Gateway', 'Mesh')
        MinMemoryGB = 8
        MinCPUs = 4
    }
    'gpu' = @{
        Description = 'Full stack with GPU for Canvas/Parallel'
        Services = @('Chronicle', 'Node', 'Pulse', 'Watch', 'Mind', 'LLM', 'Spirit',
                    'WorkingMemory', 'Context', 'Search', 'Canvas', 'Parallel', 'Force',
                    'Accel', 'Vision', 'Gateway', 'Mesh')
        MinMemoryGB = 16
        MinCPUs = 8
        RequiresGPU = $true
    }
    'exo-node' = @{
        Description = 'Lightweight exo distributed inference node'
        Services = @('Chronicle', 'Pulse', 'Exo', 'ExoNodes')
        MinMemoryGB = 4
        MinCPUs = 4
        RequiresGPU = $true
    }
    'memory' = @{
        Description = 'Memory and vector services'
        Services = @('Chronicle', 'Node', 'Pulse', 'Spirit', 'WorkingMemory', 'Context',
                    'Chain', 'Conduit', 'SensoryBuffer')
        MinMemoryGB = 16
        MinCPUs = 4
    }
    'llm' = @{
        Description = 'LLM inference node'
        Services = @('Chronicle', 'Node', 'Pulse', 'LLM', 'Mind', 'Reasoning', 'Judge',
                    'Safety', 'Flow')
        MinMemoryGB = 16
        MinCPUs = 8
    }
}

$VMBasePath = 'C:\Hyper-V\VMs'
$VHDBasePath = 'C:\Hyper-V\VHDs'

#endregion

#region Functions

function Test-HyperVEnabled {
    try {
        $vmms = Get-Service -Name vmms -ErrorAction Stop
        return $vmms.Status -eq 'Running'
    } catch {
        return $false
    }
}

function Test-SwitchExists {
    param([string]$Name)
    try {
        $switch = Get-VMSwitch -Name $Name -ErrorAction Stop
        return $null -ne $switch
    } catch {
        return $false
    }
}

function New-AitherVirtualSwitch {
    param(
        [string]$Name = 'AitherNet',
        [string]$Type = 'Internal'
    )
    
    Write-AitherInfo "Creating virtual switch: $Name ($Type)"
    
    try {
        switch ($Type) {
            'External' {
                $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceType -eq 6 } | Select-Object -First 1
                if ($adapter) {
                    New-VMSwitch -Name $Name -NetAdapterName $adapter.Name -AllowManagementOS $true
                } else {
                    Write-AitherWarning "No suitable network adapter found, creating internal switch"
                    New-VMSwitch -Name $Name -SwitchType Internal
                }
            }
            'Internal' {
                New-VMSwitch -Name $Name -SwitchType Internal
            }
            'Private' {
                New-VMSwitch -Name $Name -SwitchType Private
            }
        }
        Write-AitherSuccess "Virtual switch '$Name' created"
        return $true
    } catch {
        Write-AitherError "Failed to create virtual switch: $_"
        return $false
    }
}

function New-AitherVM {
    param(
        [string]$Name,
        [int]$MemoryGB,
        [int]$CPUs,
        [int]$DiskGB,
        [string]$Switch,
        [string]$ISO,
        [string]$Image
    )
    
    Write-AitherInfo "Creating VM: $Name"
    Write-AitherInfo "  Memory: ${MemoryGB}GB, CPUs: $CPUs, Disk: ${DiskGB}GB"
    
    # Create directories
    $vmPath = Join-Path $VMBasePath $Name
    $vhdPath = Join-Path $VHDBasePath "$Name.vhdx"
    
    if (-not (Test-Path $VMBasePath)) { New-Item -ItemType Directory -Path $VMBasePath -Force | Out-Null }
    if (-not (Test-Path $VHDBasePath)) { New-Item -ItemType Directory -Path $VHDBasePath -Force | Out-Null }
    
    try {
        # Create VHD
        if ($Image -and (Test-Path $Image)) {
            Write-AitherInfo "Using pre-built image: $Image"
            Copy-Item -Path $Image -Destination $vhdPath -Force
        } else {
            Write-AitherInfo "Creating new VHD: $vhdPath"
            New-VHD -Path $vhdPath -SizeBytes ($DiskGB * 1GB) -Dynamic | Out-Null
        }
        
        # Create VM
        $memBytes = $MemoryGB * 1GB
        New-VM -Name $Name -MemoryStartupBytes $memBytes -Generation 2 -VHDPath $vhdPath -Path $vmPath | Out-Null
        
        # Configure VM
        Set-VM -Name $Name -ProcessorCount $CPUs -DynamicMemory -MemoryMinimumBytes ($MemoryGB / 2 * 1GB) -MemoryMaximumBytes ($MemoryGB * 2 * 1GB)
        
        # Add network adapter
        Get-VMNetworkAdapter -VMName $Name | Remove-VMNetworkAdapter
        Add-VMNetworkAdapter -VMName $Name -SwitchName $Switch -Name 'AitherNet'
        
        # Add DVD drive if ISO specified
        if ($ISO -and (Test-Path $ISO)) {
            Write-AitherInfo "Attaching ISO: $ISO"
            Add-VMDvdDrive -VMName $Name -Path $ISO
            
            # Set boot order to DVD first
            $dvd = Get-VMDvdDrive -VMName $Name
            Set-VMFirmware -VMName $Name -FirstBootDevice $dvd
        }
        
        # Disable secure boot for Linux
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off
        
        # Enable integration services
        Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface'
        
        Write-AitherSuccess "VM '$Name' created successfully"
        return $true
    } catch {
        Write-AitherError "Failed to create VM: $_"
        return $false
    }
}

function Enable-GPUPassthrough {
    param(
        [string]$VMName,
        [string]$DeviceID
    )
    
    Write-AitherInfo "Configuring GPU passthrough for $VMName"
    
    if (-not $DeviceID) {
        # Find NVIDIA GPU
        $gpu = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -match 'NVIDIA' } | Select-Object -First 1
        if ($gpu) {
            $DeviceID = $gpu.InstanceId
            Write-AitherInfo "Found GPU: $($gpu.FriendlyName)"
        } else {
            Write-AitherWarning "No NVIDIA GPU found for passthrough"
            return $false
        }
    }
    
    try {
        # GPU-P (GPU Partitioning) for supported cards
        $partitionable = Get-VMHostPartitionableGpu
        if ($partitionable) {
            Write-AitherInfo "Configuring GPU-P partitioning"
            Set-VM -Name $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace 32GB
            Add-VMGpuPartitionAdapter -VMName $VMName
            Write-AitherSuccess "GPU-P enabled for $VMName"
            return $true
        } else {
            # DDA (Discrete Device Assignment) for older cards
            Write-AitherInfo "GPU-P not available, attempting DDA"
            
            # Disable device on host
            $locationPath = (Get-PnpDeviceProperty -InstanceId $DeviceID -KeyName DEVPKEY_Device_LocationPaths).Data[0]
            
            if ($locationPath) {
                Dismount-VMHostAssignableDevice -LocationPath $locationPath -Force
                Add-VMAssignableDevice -VMName $VMName -LocationPath $locationPath
                Write-AitherSuccess "DDA GPU passthrough configured"
                return $true
            }
        }
    } catch {
        Write-AitherWarning "GPU passthrough configuration failed: $_"
        return $false
    }
    
    return $false
}

function Install-AitherNodeOnVM {
    param(
        [string]$VMName,
        [string]$IPAddress,
        [PSCredential]$Credential,
        [string[]]$Services
    )
    
    Write-AitherInfo "Installing AitherNode on $VMName..."
    
    # Wait for VM to be ready
    $maxWait = 300
    $waited = 0
    while ($waited -lt $maxWait) {
        $vm = Get-VM -Name $VMName
        if ($vm.State -eq 'Running') {
            $heartbeat = Get-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
            if ($heartbeat.PrimaryStatusDescription -eq 'OK') {
                Write-AitherInfo "VM is running and responsive"
                break
            }
        }
        Start-Sleep -Seconds 10
        $waited += 10
        Write-AitherInfo "Waiting for VM to be ready... ($waited/$maxWait seconds)"
    }
    
    if ($waited -ge $maxWait) {
        Write-AitherWarning "Timeout waiting for VM to be ready"
        return $false
    }
    
    # Get VM IP if not specified
    if (-not $IPAddress) {
        $adapters = Get-VMNetworkAdapter -VMName $VMName
        $IPAddress = $adapters.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    }
    
    if (-not $IPAddress) {
        Write-AitherWarning "Could not determine VM IP address"
        return $false
    }
    
    Write-AitherInfo "VM IP: $IPAddress"
    
    # Create deployment script
    $servicesJson = ($Services | ConvertTo-Json -Compress)
    $deployScript = @"

# AitherNode Remote Deployment Script
`$ErrorActionPreference = 'Stop'

Write-Host 'Installing AitherNode...'

# Install prerequisites
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Python...'
    winget install Python.Python.3.11 --silent --accept-source-agreements --accept-package-agreements
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Git...'
    winget install Git.Git --silent --accept-source-agreements --accept-package-agreements
}

# Clone AitherOS
`$aitherPath = 'C:\AitherOS'
if (-not (Test-Path `$aitherPath)) {
    git clone https://github.com/Aither-AI/AitherOS.git `$aitherPath
}

Set-Location `$aitherPath

# Create virtual environment
python -m venv .venv
.\.venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt

# Configure services to run
`$services = @'
$servicesJson
'@ | ConvertFrom-Json

`$configPath = Join-Path `$aitherPath 'config' 'node-config.yaml'
@"
node_id: '$VMName'
services: `$services
mesh:
  enabled: true
  discovery: auto
"@ | Set-Content `$configPath

Write-Host 'AitherNode installed successfully'

"@
    
    try {
        if ($Credential) {
            # Use PSSession for remote deployment
            $session = New-PSSession -ComputerName $IPAddress -Credential $Credential -ErrorAction Stop
            Invoke-Command -Session $session -ScriptBlock { param($s) Invoke-Expression $s } -ArgumentList $deployScript
            Remove-PSSession $session
        } else {
            # Try with current credentials
            Invoke-Command -ComputerName $IPAddress -ScriptBlock { param($s) Invoke-Expression $s } -ArgumentList $deployScript
        }
        
        Write-AitherSuccess "AitherNode installed on $VMName"
        return $true
    } catch {
        Write-AitherError "Remote installation failed: $_"
        Write-AitherInfo "You may need to install AitherNode manually on the VM"
        return $false
    }
}

function Join-ExoCluster {
    param(
        [string]$VMName,
        [string]$IPAddress
    )
    
    Write-AitherInfo "Joining $VMName to AitherExo cluster..."
    
    $joinScript = @"
`$ErrorActionPreference = 'Stop'

# Start exo node
Set-Location 'C:\AitherOS'
.\.venv\Scripts\Activate.ps1

# Install exo if not present
pip install exo

# Start exo with UDP discovery
Start-Process -FilePath python -ArgumentList '-m', 'exo.main', '--discovery-module', 'udp', '--wait-for-peers', '1' -NoNewWindow

Write-Host 'Exo node started and joining cluster'
"@
    
    try {
        Invoke-Command -ComputerName $IPAddress -ScriptBlock { param($s) Invoke-Expression $s } -ArgumentList $joinScript
        Write-AitherSuccess "$VMName joined AitherExo cluster"
        return $true
    } catch {
        Write-AitherWarning "Could not auto-join exo cluster: $_"
        return $false
    }
}

#endregion

#region Main Execution

Write-ScriptHeader -ScriptName 'Deploy Hyper-V VM' -ScriptDescription "Deploy AitherOS node to Hyper-V - Template: $Template"

# Validate prerequisites
if (-not (Test-HyperVEnabled)) {
    Write-AitherError "Hyper-V is not enabled. Run 0105_Install-HyperV.ps1 first."
    exit 1
}

# Check admin
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-AitherError "Administrator privileges required"
    exit 1
}

# Get template config
$templateConfig = $TemplateConfigs[$Template]
Write-AitherInfo "Template: $($templateConfig.Description)"
Write-AitherInfo "Services: $($templateConfig.Services -join ', ')"

# Validate resources
if ($MemoryGB -lt $templateConfig.MinMemoryGB) {
    Write-AitherWarning "Template '$Template' recommends at least $($templateConfig.MinMemoryGB)GB RAM"
}
if ($CPUs -lt $templateConfig.MinCPUs) {
    Write-AitherWarning "Template '$Template' recommends at least $($templateConfig.MinCPUs) CPUs"
}
if ($templateConfig.RequiresGPU -and -not $EnableGPU) {
    Write-AitherWarning "Template '$Template' benefits from GPU passthrough (-EnableGPU)"
}

# Check if VM already exists
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-AitherError "VM '$VMName' already exists. Remove it first or choose a different name."
    exit 1
}

# Ensure virtual switch exists
if (-not (Test-SwitchExists -Name $SwitchName)) {
    Write-AitherWarning "Virtual switch '$SwitchName' not found"
    
    if ($SwitchName -eq 'Default Switch') {
        Write-AitherInfo "Attempting to create 'Default Switch'..."
        New-AitherVirtualSwitch -Name 'Default Switch' -Type 'Internal'
    } else {
        New-AitherVirtualSwitch -Name $SwitchName -Type 'Internal'
    }
}

# Create the VM
$vmCreated = New-AitherVM -Name $VMName -MemoryGB $MemoryGB -CPUs $CPUs -DiskGB $DiskSizeGB -Switch $SwitchName -ISO $ISOPath -Image $ImagePath

if (-not $vmCreated) {
    Write-AitherError "VM creation failed"
    exit 1
}

# GPU Passthrough
if ($EnableGPU -or $templateConfig.RequiresGPU) {
    Enable-GPUPassthrough -VMName $VMName -DeviceID $GPUDeviceID
}

# Configure static IP if specified
if ($IPAddress) {
    Write-AitherInfo "Static IP will be configured after VM starts: $IPAddress"
}

# Start VM if requested
if ($AutoStart) {
    Write-AitherInfo "Starting VM..."
    Start-VM -Name $VMName
    
    # Install AitherNode if requested
    if ($InstallAitherNode) {
        Install-AitherNodeOnVM -VMName $VMName -IPAddress $IPAddress -Credential $VMCredential -Services $templateConfig.Services
    }
    
    # Join Exo cluster if requested
    if ($JoinExoCluster) {
        Join-ExoCluster -VMName $VMName -IPAddress $IPAddress
    }
}

# Output summary
Write-Host ""
Write-AitherSuccess "═══════════════════════════════════════════════════════"
Write-AitherSuccess "VM Deployment Complete"
Write-AitherSuccess "═══════════════════════════════════════════════════════"
Write-Host ""
Write-Host "  VM Name:    $VMName" -ForegroundColor Cyan
Write-Host "  Template:   $Template ($($templateConfig.Description))" -ForegroundColor Cyan
Write-Host "  Memory:     ${MemoryGB}GB" -ForegroundColor Cyan
Write-Host "  CPUs:       $CPUs" -ForegroundColor Cyan
Write-Host "  Disk:       ${DiskSizeGB}GB" -ForegroundColor Cyan
Write-Host "  Network:    $SwitchName" -ForegroundColor Cyan

if ($IPAddress) {
    Write-Host "  IP:         $IPAddress" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Services to deploy:" -ForegroundColor Yellow
foreach ($svc in $templateConfig.Services) {
    Write-Host "  • $svc" -ForegroundColor White
}

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
if (-not $AutoStart) {
    Write-Host "  1. Start-VM -Name '$VMName'" -ForegroundColor White
}
if (-not $InstallAitherNode) {
    Write-Host "  2. Install AitherNode on the VM" -ForegroundColor White
}
if (-not $JoinExoCluster -and $Template -eq 'exo-node') {
    Write-Host "  3. Join the exo cluster: .\0815_Manage-AitherExo.ps1 -Action Join" -ForegroundColor White
}

Write-ScriptFooter -ScriptName 'Deploy Hyper-V VM'

#endregion
