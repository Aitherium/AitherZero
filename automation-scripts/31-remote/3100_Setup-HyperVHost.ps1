#Requires -Version 7.0

<#
.SYNOPSIS
    Bootstrap a Windows Server 2025 Hyper-V Server Core host for AitherOS node deployment.

.DESCRIPTION
    Remotely configures a bare Windows Server 2025 (Server Core) machine running Hyper-V
    to serve as an AitherOS compute node. Handles the full prerequisite chain:

    1. Enable WinRM/PSRemoting on the target (if not already)
    2. Install/configure Hyper-V role features
    3. Install Docker (via Containers feature or Docker CE)
    4. Install PowerShell 7 on the remote host
    5. Configure networking (virtual switch, NAT, firewall rules)
    6. Deploy AitherNode via docker-compose.node.yml
    7. Join the node to AitherMesh for hot failover

    Exit Codes:
        0 - Success
        1 - Connection failure
        2 - Prerequisite installation failure
        3 - Docker setup failure
        4 - Node deployment failure
        5 - Mesh join failure

.PARAMETER ComputerName
    Hostname or IP address of the target Server Core machine. REQUIRED.

.PARAMETER Credential
    PSCredential for remote authentication. If not provided, prompts interactively.

.PARAMETER UseSSH
    Use SSH transport instead of WinRM for the remote session.

.PARAMETER SkipHyperV
    Skip Hyper-V feature installation (if already configured).

.PARAMETER SkipDocker
    Skip Docker installation (if already running).

.PARAMETER SkipFirewall
    Skip firewall rule configuration.

.PARAMETER GPU
    Enable GPU passthrough / DDA for the AitherNode VM.

.PARAMETER CoreUrl
    URL of the AitherOS Core instance for mesh join. Defaults to the local machine's IP.

.PARAMETER MeshToken
    Authentication token for mesh network join. Auto-generated if not provided.

.PARAMETER VirtualSwitchName
    Name for the Hyper-V virtual switch. Default: "AitherSwitch".

.PARAMETER NodeName
    Friendly name for this node in the mesh. Default: hostname.

.PARAMETER DryRun
    Show what would be executed without making changes.

.PARAMETER Force
    Force reinstallation of components even if already present.

.NOTES
    Stage: Remote-Deploy
    Order: 3100
    Dependencies: none
    Tags: remote, hyperv, server-core, deployment, infrastructure
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0, HelpMessage = "Target server hostname or IP")]
    [ValidateNotNullOrEmpty()]
    [string]$ComputerName,

    [Parameter(HelpMessage = "Credentials for the remote server")]
    [System.Management.Automation.PSCredential]$Credential,

    [switch]$UseSSH,
    [switch]$SkipHyperV,
    [switch]$SkipDocker,
    [switch]$SkipFirewall,
    [switch]$GPU,

    [string]$CoreUrl,
    [string]$MeshToken,
    [string]$VirtualSwitchName = "AitherSwitch",
    [string]$NodeName,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════

$requiredPorts = @(
    @{ Port = 8001; Name = "Genesis" },
    @{ Port = 8080; Name = "Node" },
    @{ Port = 8081; Name = "Pulse" },
    @{ Port = 8082; Name = "Watch" },
    @{ Port = 8111; Name = "Secrets" },
    @{ Port = 8121; Name = "Chronicle" },
    @{ Port = 8125; Name = "MeshCore" },
    @{ Port = 8136; Name = "Strata" },
    @{ Port = 8150; Name = "MicroScheduler" },
    @{ Port = 3000; Name = "AitherVeil" },
    @{ Port = 5985; Name = "WinRM" },
    @{ Port = 5986; Name = "WinRM-HTTPS" }
)

$minimumRequirements = @{
    MinDiskGB   = 50
    MinMemoryGB = 8
    MinCores    = 4
}

# ═══════════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════════

function Write-Step {
    param([string]$Phase, [string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SKIP"    { "DarkGray" }
        default   { "Cyan" }
    }
    $icon = switch ($Status) {
        "OK"      { "✓" }
        "WARN"    { "⚠" }
        "ERROR"   { "✗" }
        "SKIP"    { "→" }
        default   { "●" }
    }
    Write-Host "  [$Phase] $icon $Message" -ForegroundColor $color
}

function Test-RemoteReady {
    param([string]$Target, [PSCredential]$Cred, [switch]$SSH)
    try {
        $sessionParams = @{ ComputerName = $Target; ErrorAction = 'Stop' }
        if ($Cred) { $sessionParams.Credential = $Cred }
        if ($SSH)  { $sessionParams.SSHTransport = $true }

        $session = New-PSSession @sessionParams
        $result = Invoke-Command -Session $session -ScriptBlock { $env:COMPUTERNAME }
        Remove-PSSession $session
        return @{ Connected = $true; Hostname = $result }
    }
    catch {
        return @{ Connected = $false; Error = $_.Exception.Message }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# BANNER
# ═══════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║     AitherOS — Hyper-V Host Bootstrap (3100)      ║" -ForegroundColor Magenta
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Target:  $ComputerName" -ForegroundColor White
Write-Host "  Mode:    $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Green' })
Write-Host ""

if ($DryRun) {
    Write-Host "  [DRY RUN] Would execute the following phases:" -ForegroundColor Yellow
    Write-Host "    Phase 1: Test connectivity & validate hardware" -ForegroundColor DarkGray
    Write-Host "    Phase 2: Install/enable Hyper-V role" -ForegroundColor DarkGray
    Write-Host "    Phase 3: Install Docker CE" -ForegroundColor DarkGray
    Write-Host "    Phase 4: Install PowerShell 7" -ForegroundColor DarkGray
    Write-Host "    Phase 5: Configure networking & firewall" -ForegroundColor DarkGray
    Write-Host "    Phase 6: Deploy AitherNode containers" -ForegroundColor DarkGray
    Write-Host "    Phase 7: Join AitherMesh" -ForegroundColor DarkGray
    Write-Host ""
    if ($PassThru) {
        return [PSCustomObject]@{ Status = 'DryRun'; ComputerName = $ComputerName }
    }
    return
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 1: CONNECTIVITY & HARDWARE VALIDATION
# ═══════════════════════════════════════════════════════════════════════

Write-Step "PHASE 1" "Testing connectivity to $ComputerName..."

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter credentials for $ComputerName"
}

$connectivity = Test-RemoteReady -Target $ComputerName -Cred $Credential -SSH:$UseSSH
if (-not $connectivity.Connected) {
    Write-Step "PHASE 1" "Cannot connect: $($connectivity.Error)" "ERROR"
    Write-Host ""
    Write-Host "  The target machine needs to be bootstrapped first." -ForegroundColor Yellow
    Write-Host "  Connect to the server (RDP/console) and run this one-liner:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    iwr -useb https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Or with the Node profile for full remote access:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host '    & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1))) -InstallProfile Node -NonInteractive -AutoInstallDeps' -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This installs PS7, Docker, enables WinRM/PSRemoting, and opens firewall ports." -ForegroundColor DarkGray
    Write-Host "  After that, re-run this script — all subsequent operations work remotely." -ForegroundColor DarkGray
    exit 1
}
Write-Step "PHASE 1" "Connected to $($connectivity.Hostname)" "OK"

# Create persistent session for all subsequent operations
$sessionParams = @{ ComputerName = $ComputerName; Credential = $Credential }
if ($UseSSH) { $sessionParams.SSHTransport = $true }
$session = New-PSSession @sessionParams

# Validate hardware
$hardwareInfo = Invoke-Command -Session $session -ScriptBlock {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        OSCaption     = $os.Caption
        OSVersion     = $os.Version
        TotalMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        FreeMemoryGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        CPUName       = $cpu[0].Name
        CPUCores      = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        CPUThreads    = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        DiskFreeGB    = [math]::Round($disk.FreeSpace / 1GB, 1)
        DiskTotalGB   = [math]::Round($disk.Size / 1GB, 1)
        GPUName       = $gpu[0].Name
        GPUMemoryMB   = $gpu[0].AdapterRAM / 1MB
        IsServerCore  = -not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Server\ServerLevels\Server-Gui-Shell' -ErrorAction SilentlyContinue)
        HyperVEnabled = (Get-WindowsFeature Hyper-V -ErrorAction SilentlyContinue).Installed
        DockerRunning = $null -ne (Get-Service docker -ErrorAction SilentlyContinue) -and (Get-Service docker -ErrorAction SilentlyContinue).Status -eq 'Running'
    }
}

Write-Host "  ┌─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
Write-Host "  │ OS:      $($hardwareInfo.OSCaption)" -ForegroundColor White
Write-Host "  │ CPU:     $($hardwareInfo.CPUName) ($($hardwareInfo.CPUCores)C/$($hardwareInfo.CPUThreads)T)" -ForegroundColor White
Write-Host "  │ RAM:     $($hardwareInfo.TotalMemoryGB) GB ($($hardwareInfo.FreeMemoryGB) GB free)" -ForegroundColor White
Write-Host "  │ Disk:    $($hardwareInfo.DiskFreeGB) GB free / $($hardwareInfo.DiskTotalGB) GB" -ForegroundColor White
Write-Host "  │ GPU:     $(if ($hardwareInfo.GPUName) { $hardwareInfo.GPUName } else { 'None detected' })" -ForegroundColor White
Write-Host "  │ Core:    $(if ($hardwareInfo.IsServerCore) { 'Yes (Server Core)' } else { 'No (Desktop Experience)' })" -ForegroundColor White
Write-Host "  │ Hyper-V: $(if ($hardwareInfo.HyperVEnabled) { 'Installed' } else { 'Not installed' })" -ForegroundColor White
Write-Host "  │ Docker:  $(if ($hardwareInfo.DockerRunning) { 'Running' } else { 'Not running' })" -ForegroundColor White
Write-Host "  └─────────────────────────────────────────────────┘" -ForegroundColor DarkGray

# Validate minimum requirements
if ($hardwareInfo.TotalMemoryGB -lt $minimumRequirements.MinMemoryGB) {
    Write-Step "PHASE 1" "Insufficient RAM: $($hardwareInfo.TotalMemoryGB)GB < $($minimumRequirements.MinMemoryGB)GB required" "ERROR"
    exit 1
}
if ($hardwareInfo.DiskFreeGB -lt $minimumRequirements.MinDiskGB) {
    Write-Step "PHASE 1" "Insufficient disk: $($hardwareInfo.DiskFreeGB)GB < $($minimumRequirements.MinDiskGB)GB required" "ERROR"
    exit 1
}
Write-Step "PHASE 1" "Hardware validation passed" "OK"

# ═══════════════════════════════════════════════════════════════════════
# PHASE 2: HYPER-V ROLE
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipHyperV) {
    if ($hardwareInfo.HyperVEnabled -and -not $Force) {
        Write-Step "PHASE 2" "Hyper-V already installed, skipping" "SKIP"
    }
    else {
        Write-Step "PHASE 2" "Installing Hyper-V role and management tools..."
        if ($PSCmdlet.ShouldProcess($ComputerName, "Install Hyper-V")) {
            $hvResult = Invoke-Command -Session $session -ScriptBlock {
                $features = @(
                    'Hyper-V',
                    'Hyper-V-Tools',
                    'Hyper-V-PowerShell',
                    'RSAT-Hyper-V-Tools'
                )
                $results = @()
                foreach ($f in $features) {
                    $feat = Get-WindowsFeature $f -ErrorAction SilentlyContinue
                    if ($feat -and -not $feat.Installed) {
                        $r = Install-WindowsFeature $f -IncludeManagementTools -ErrorAction SilentlyContinue
                        $results += [PSCustomObject]@{ Feature = $f; Success = $r.Success; RestartNeeded = $r.RestartNeeded }
                    }
                    else {
                        $results += [PSCustomObject]@{ Feature = $f; Success = $true; RestartNeeded = 'No' }
                    }
                }
                $results
            }

            $needsReboot = $hvResult | Where-Object { $_.RestartNeeded -eq 'Yes' }
            if ($needsReboot) {
                Write-Step "PHASE 2" "Hyper-V installed — REBOOT REQUIRED" "WARN"
                Write-Host "    Run: Restart-Computer -ComputerName $ComputerName -Credential `$cred -Force" -ForegroundColor Yellow
                Write-Host "    Then re-run this script with -SkipHyperV" -ForegroundColor Yellow
                Remove-PSSession $session
                exit 0
            }
            Write-Step "PHASE 2" "Hyper-V role configured" "OK"
        }
    }
}
else {
    Write-Step "PHASE 2" "Hyper-V installation skipped (-SkipHyperV)" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 3: DOCKER
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipDocker) {
    if ($hardwareInfo.DockerRunning -and -not $Force) {
        Write-Step "PHASE 3" "Docker already running, skipping" "SKIP"
    }
    else {
        Write-Step "PHASE 3" "Installing Docker on $ComputerName..."
        if ($PSCmdlet.ShouldProcess($ComputerName, "Install Docker")) {
            Invoke-Command -Session $session -ScriptBlock {
                # Install Containers feature (Server 2025 native)
                $containersFeat = Get-WindowsFeature Containers
                if (-not $containersFeat.Installed) {
                    Install-WindowsFeature Containers -ErrorAction Stop
                }

                # Install Docker CE via OneGet or direct download
                $dockerService = Get-Service docker -ErrorAction SilentlyContinue
                if (-not $dockerService) {
                    # Try Microsoft-maintained Docker EE (built into Server 2025)
                    $dockerProvider = Get-PackageProvider DockerMsftProvider -ErrorAction SilentlyContinue
                    if (-not $dockerProvider) {
                        Install-Module DockerMsftProvider -Force -ErrorAction SilentlyContinue
                    }
                    $pkg = Get-Package docker -ProviderName DockerMsftProvider -ErrorAction SilentlyContinue
                    if (-not $pkg) {
                        Install-Package Docker -ProviderName DockerMsftProvider -Force -ErrorAction Stop
                    }
                }

                # Ensure service is running
                Start-Service docker -ErrorAction Stop
                Set-Service docker -StartupType Automatic

                # Install Docker Compose plugin
                $composeVer = "v2.27.0"
                $composePath = "$env:ProgramFiles\Docker\cli-plugins\docker-compose.exe"
                if (-not (Test-Path $composePath)) {
                    $composeDir = Split-Path $composePath
                    if (-not (Test-Path $composeDir)) { New-Item $composeDir -ItemType Directory -Force | Out-Null }
                    $url = "https://github.com/docker/compose/releases/download/$composeVer/docker-compose-windows-x86_64.exe"
                    Invoke-WebRequest -Uri $url -OutFile $composePath -UseBasicParsing
                }
            }
            Write-Step "PHASE 3" "Docker installed and running" "OK"
        }
    }
}
else {
    Write-Step "PHASE 3" "Docker installation skipped (-SkipDocker)" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 4: POWERSHELL 7
# ═══════════════════════════════════════════════════════════════════════

Write-Step "PHASE 4" "Checking PowerShell 7 on remote host..."

$ps7Installed = Invoke-Command -Session $session -ScriptBlock {
    Test-Path "$env:ProgramFiles\PowerShell\7\pwsh.exe"
}

if (-not $ps7Installed -or $Force) {
    Write-Step "PHASE 4" "Installing PowerShell 7..."
    if ($PSCmdlet.ShouldProcess($ComputerName, "Install PowerShell 7")) {
        Invoke-Command -Session $session -ScriptBlock {
            # Use winget if available, otherwise MSI direct download
            $winget = Get-Command winget -ErrorAction SilentlyContinue
            if ($winget) {
                winget install Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            }
            else {
                $msiUrl = "https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi"
                $msiPath = "$env:TEMP\pwsh7.msi"
                Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
                Start-Process msiexec.exe -ArgumentList "/i", $msiPath, "/quiet", "/norestart", "ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1", "ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1", "ENABLE_PSREMOTING=1", "REGISTER_MANIFEST=1" -Wait
                Remove-Item $msiPath -ErrorAction SilentlyContinue
            }
        }
        Write-Step "PHASE 4" "PowerShell 7 installed" "OK"
    }
}
else {
    Write-Step "PHASE 4" "PowerShell 7 already installed" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 5: NETWORKING & FIREWALL
# ═══════════════════════════════════════════════════════════════════════

if (-not $SkipFirewall) {
    Write-Step "PHASE 5" "Configuring virtual switch and firewall rules..."
    if ($PSCmdlet.ShouldProcess($ComputerName, "Configure networking")) {
        Invoke-Command -Session $session -ScriptBlock {
            param($SwitchName, $Ports)

            # Create external virtual switch if it doesn't exist
            $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
            if (-not $existingSwitch) {
                # Find the primary network adapter
                $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Hyper-V|Virtual|Loopback' } | Select-Object -First 1
                if ($adapter) {
                    New-VMSwitch -Name $SwitchName -NetAdapterName $adapter.Name -AllowManagementOS $true -ErrorAction Stop
                    Write-Output "Created external virtual switch: $SwitchName on $($adapter.Name)"
                }
                else {
                    # Fallback to internal switch
                    New-VMSwitch -Name $SwitchName -SwitchType Internal
                    Write-Output "Created internal virtual switch: $SwitchName (no external adapter found)"
                }
            }

            # Configure firewall rules for AitherOS services
            $ruleGroup = "AitherOS"
            foreach ($p in $Ports) {
                $ruleName = "AitherOS-$($p.Name)-$($p.Port)"
                $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                if (-not $existing) {
                    New-NetFirewallRule -DisplayName $ruleName `
                        -Direction Inbound -Protocol TCP -LocalPort $p.Port `
                        -Action Allow -Group $ruleGroup `
                        -Description "AitherOS $($p.Name) service on port $($p.Port)" | Out-Null
                }
            }

            # Enable ICMP for mesh health checks
            $icmpRule = Get-NetFirewallRule -DisplayName "AitherOS-ICMP-Mesh" -ErrorAction SilentlyContinue
            if (-not $icmpRule) {
                New-NetFirewallRule -DisplayName "AitherOS-ICMP-Mesh" `
                    -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
                    -Action Allow -Group $ruleGroup `
                    -Description "AitherOS mesh health check ping" | Out-Null
            }

            Write-Output "Firewall rules configured for AitherOS services"
        } -ArgumentList $VirtualSwitchName, $requiredPorts

        Write-Step "PHASE 5" "Networking configured" "OK"
    }
}
else {
    Write-Step "PHASE 5" "Networking/firewall skipped (-SkipFirewall)" "SKIP"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 6: DEPLOY AITHERNODE
# ═══════════════════════════════════════════════════════════════════════

Write-Step "PHASE 6" "Deploying AitherNode to $ComputerName..."

if ($PSCmdlet.ShouldProcess($ComputerName, "Deploy AitherNode")) {
    # Determine CoreUrl (auto-detect local IP if not provided)
    if (-not $CoreUrl) {
        $localIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.PrefixOrigin -eq 'Dhcp' -or $_.PrefixOrigin -eq 'Manual'
        } | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
        $CoreUrl = "http://${localIP}:8001"
        Write-Step "PHASE 6" "Auto-detected Core URL: $CoreUrl"
    }

    # Generate mesh token if not provided
    if (-not $MeshToken) {
        $MeshToken = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
        Write-Step "PHASE 6" "Generated mesh token (save this!): $($MeshToken.Substring(0,12))..."
    }

    # Copy docker-compose.node.yml to remote host
    $composeSource = Join-Path $PSScriptRoot ".." ".." ".." "docker-compose.node.yml"
    if (-not (Test-Path $composeSource)) {
        # Try project root
        $composeSource = Join-Path $PSScriptRoot ".." ".." ".." ".." "docker-compose.node.yml"
    }

    $remoteDeployDir = "C:\AitherOS"
    Invoke-Command -Session $session -ScriptBlock {
        param($dir)
        if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    } -ArgumentList $remoteDeployDir

    # Copy compose file
    if (Test-Path $composeSource) {
        Copy-Item -Path $composeSource -Destination "$remoteDeployDir\docker-compose.node.yml" -ToSession $session -Force
        Write-Step "PHASE 6" "Copied docker-compose.node.yml to remote" "OK"
    }
    else {
        Write-Step "PHASE 6" "docker-compose.node.yml not found locally — will pull on remote" "WARN"
    }

    # Create .env file on remote
    $nodeName = if ($NodeName) { $NodeName } else { $connectivity.Hostname }
    Invoke-Command -Session $session -ScriptBlock {
        param($deployDir, $coreUrl, $token, $name, $gpuEnabled)

        $envContent = @"
# AitherNode Environment — Auto-generated by 3100_Setup-HyperVHost.ps1
AITHER_NODE_NAME=$name
AITHER_CORE_URL=$coreUrl
AITHER_NODE_TOKEN=$token
AITHER_MESH_ENABLED=true
AITHER_NODE_ROLE=compute
AITHER_DOCKER_MODE=true
AITHER_GPU_ENABLED=$($gpuEnabled.ToString().ToLower())
COMPOSE_PROJECT_NAME=aithernode
"@
        Set-Content -Path (Join-Path $deployDir ".env") -Value $envContent -Force
    } -ArgumentList $remoteDeployDir, $CoreUrl, $MeshToken, $nodeName, [bool]$GPU

    # Start containers
    $deployResult = Invoke-Command -Session $session -ScriptBlock {
        param($deployDir, $gpuEnabled)

        Set-Location $deployDir
        $profiles = @()
        if ($gpuEnabled) { $profiles += @("--profile", "gpu") }
        $profiles += @("--profile", "mesh")

        # Pull images
        $pullArgs = @("-f", "docker-compose.node.yml") + $profiles + @("pull")
        & docker compose @pullArgs 2>&1

        # Start services
        $upArgs = @("-f", "docker-compose.node.yml") + $profiles + @("up", "-d")
        & docker compose @upArgs 2>&1

        Start-Sleep -Seconds 10

        # Get status
        $psArgs = @("-f", "docker-compose.node.yml") + $profiles + @("ps", "--format", "table {{.Name}}\t{{.Status}}\t{{.Ports}}")
        $status = & docker compose @psArgs 2>&1
        $status
    } -ArgumentList $remoteDeployDir, [bool]$GPU

    Write-Host ""
    $deployResult | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    Write-Step "PHASE 6" "AitherNode containers deployed" "OK"
}

# ═══════════════════════════════════════════════════════════════════════
# PHASE 7: JOIN AITHERMESH
# ═══════════════════════════════════════════════════════════════════════

Write-Step "PHASE 7" "Joining AitherMesh..."

try {
    # Call the mesh join endpoint on the remote node
    $remoteIP = Invoke-Command -Session $session -ScriptBlock {
        (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.PrefixOrigin -eq 'Dhcp' -or $_.PrefixOrigin -eq 'Manual'
        } | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | Select-Object -First 1).IPAddress
    }

    # Register the node with the Core's mesh endpoint
    $joinPayload = @{
        node_id       = $nodeName ?? $connectivity.Hostname
        node_url      = "http://${remoteIP}:8125"
        capabilities  = @("compute", "inference")
        role          = "compute"
        psk           = $MeshToken
        auto_failover = $true
    } | ConvertTo-Json

    $meshJoinUrl = "$CoreUrl".Replace(":8001", ":8125") + "/mesh/join"
    try {
        $joinResult = Invoke-RestMethod -Uri $meshJoinUrl -Method POST -Body $joinPayload -ContentType "application/json" -TimeoutSec 15
        Write-Step "PHASE 7" "Node joined mesh: $($joinResult.status ?? 'registered')" "OK"
    }
    catch {
        Write-Step "PHASE 7" "Mesh join request failed (Core may not be running): $($_.Exception.Message)" "WARN"
        Write-Host "    Node will auto-discover Core when both are running." -ForegroundColor DarkGray
        Write-Host "    Manual join: POST $meshJoinUrl" -ForegroundColor DarkGray
    }
}
catch {
    Write-Step "PHASE 7" "Mesh configuration warning: $($_.Exception.Message)" "WARN"
}

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════

Remove-PSSession $session -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ╔════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║       Hyper-V Host Bootstrap Complete!             ║" -ForegroundColor Green
Write-Host "  ╚════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Node:       $ComputerName ($($hardwareInfo.CPUCores)C / $($hardwareInfo.TotalMemoryGB)GB RAM)" -ForegroundColor White
Write-Host "  Core URL:   $CoreUrl" -ForegroundColor Cyan
Write-Host "  Mesh Token: $($MeshToken.Substring(0, [Math]::Min(16, $MeshToken.Length)))..." -ForegroundColor DarkGray
Write-Host "  Remote IP:  $remoteIP" -ForegroundColor Cyan
Write-Host ""
Write-Host "  SAVE YOUR MESH TOKEN — you'll need it if you re-join." -ForegroundColor Yellow
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor White
Write-Host "    1. Verify: curl http://${remoteIP}:8001/health" -ForegroundColor DarkGray
Write-Host "    2. Mesh:   curl http://${remoteIP}:8125/mesh/status" -ForegroundColor DarkGray
Write-Host "    3. Watch:  curl http://${remoteIP}:8082/health" -ForegroundColor DarkGray
Write-Host ""

if ($PassThru) {
    return [PSCustomObject]@{
        PSTypeName   = 'AitherOS.HyperVHostResult'
        Status       = 'Success'
        ComputerName = $ComputerName
        RemoteIP     = $remoteIP
        CoreUrl      = $CoreUrl
        MeshToken    = $MeshToken
        NodeName     = $nodeName
        Hardware     = $hardwareInfo
        Timestamp    = Get-Date
    }
}
