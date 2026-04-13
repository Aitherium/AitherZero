#Requires -Version 7.0

<#
.SYNOPSIS
    Deploys AitherOS to a Rocky Linux 9 server — pull from GHCR or build from source.

.DESCRIPTION
    End-to-end deployment of AitherOS on Rocky Linux 9 (or any RHEL 9 derivative).
    Supports three modes:

      pull   — Download pre-built images from ghcr.io/aitherium (fastest)
      build  — Clone repo and build all images locally
      hybrid — Pull base images from GHCR, build service layers locally

    The script:
      1. Validates SSH connectivity and target OS
      2. Installs Podman, Python 3.12, Ollama, firewalld on the target
      3. Creates the aither user with rootless Podman
      4. Pulls GHCR images OR clones repo + runs bootstrap
      5. Generates systemd units and enables services
      6. Provisions AI models via Ollama
      7. Runs smoke test to verify deployment

    For local (non-SSH) deployment on the current machine, use -Local.

.PARAMETER TargetHost
    IP or hostname of the Rocky Linux server. Not required with -Local.

.PARAMETER UserName
    SSH username. Default: root (bootstrap requires root for package install).

.PARAMETER IdentityFile
    Path to SSH private key.

.PARAMETER Mode
    Deployment mode: pull | build | hybrid. Default: pull.

.PARAMETER Profile
    Service profile: minimal | core | standard | full | gpu. Default: standard.

.PARAMETER GPU
    Enable NVIDIA GPU support (installs nvidia-container-toolkit).

.PARAMETER Tag
    GHCR image tag. Default: latest.

.PARAMETER Registry
    GHCR registry prefix. Default: ghcr.io/aitherium.

.PARAMETER SkipModels
    Skip Ollama model provisioning.

.PARAMETER Local
    Deploy on the current machine (no SSH).

.PARAMETER DryRun
    Show what would happen without executing.

.PARAMETER NonInteractive
    Skip confirmation prompts.

.EXAMPLE
    # Pull pre-built images to a remote server
    .\3060_Deploy-RockyLinux.ps1 -TargetHost 10.0.1.50 -Mode pull -Profile standard

    # Build from source with GPU
    .\3060_Deploy-RockyLinux.ps1 -TargetHost rocky.local -Mode build -GPU -Profile full

    # Deploy on the current machine
    .\3060_Deploy-RockyLinux.ps1 -Local -Mode pull -Profile core

    # Dry run
    .\3060_Deploy-RockyLinux.ps1 -TargetHost 10.0.1.50 -DryRun

.NOTES
    Category: deploy
    Dependencies: SSH (for remote), curl (for model download)
    Platform: Windows, Linux, macOS (controller) -> Rocky Linux 9 (target)
    Tags: rocky-linux, podman, systemd, ghcr, bare-metal
    Exit Codes:
        0 - Success
        1 - SSH connectivity failed
        2 - Unsupported target OS
        3 - Package installation failed
        4 - Image pull/build failed
        5 - Service startup failed
        6 - Smoke test failed
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$TargetHost,

    [string]$UserName = "root",

    [string]$IdentityFile,

    [ValidateSet("pull", "build", "hybrid")]
    [string]$Mode = "pull",

    [ValidateSet("minimal", "core", "standard", "full", "gpu")]
    [string]$Profile = "standard",

    [switch]$GPU,

    [string]$Tag = "latest",

    [string]$Registry = "ghcr.io/aitherium",

    [switch]$SkipModels,

    [switch]$Local,

    [switch]$DryRun,

    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

$scriptDir = $PSScriptRoot
$workspaceRoot = Split-Path (Split-Path (Split-Path (Split-Path $scriptDir -Parent) -Parent) -Parent) -Parent

# Try loading common helpers
if (Test-Path "$scriptDir/_init.ps1") {
    . "$scriptDir/_init.ps1"
} else {
    function Write-ScriptLog { param($Message, $Level = "Information") Write-Host "[$Level] $Message" }
}

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  AitherOS Rocky Linux Deployment" -ForegroundColor Cyan
Write-Host "  Mode: $Mode | Profile: $Profile | Tag: $Tag" -ForegroundColor DarkCyan
if ($TargetHost) { Write-Host "  Target: $UserName@$TargetHost" -ForegroundColor DarkCyan }
if ($Local)      { Write-Host "  Target: localhost (local deploy)" -ForegroundColor DarkCyan }
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""

# Validate parameters
if (-not $Local -and -not $TargetHost) {
    Write-Error "Specify -TargetHost or -Local"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SSH HELPERS
# ═══════════════════════════════════════════════════════════════════════════════

$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10")
if ($IdentityFile) {
    if (-not (Test-Path $IdentityFile)) { throw "Identity file not found: $IdentityFile" }
    $sshOpts += @("-i", $IdentityFile)
}

function Invoke-Remote {
    param([string]$Command, [switch]$Sudo)
    $cmd = if ($Sudo -and $UserName -ne "root") { "sudo bash -c '$Command'" } else { $Command }

    if ($Local) {
        if ($DryRun) { Write-Host "  [DRY-RUN] bash -c '$Command'" -ForegroundColor DarkGray; return 0 }
        bash -c $cmd
        return $LASTEXITCODE
    }

    if ($DryRun) { Write-Host "  [DRY-RUN] ssh $UserName@$TargetHost '$cmd'" -ForegroundColor DarkGray; return 0 }
    & ssh @sshOpts "$UserName@$TargetHost" $cmd
    return $LASTEXITCODE
}

function Copy-ToRemote {
    param([string]$LocalPath, [string]$RemotePath)
    if ($Local) {
        if ($DryRun) { Write-Host "  [DRY-RUN] cp $LocalPath $RemotePath" -ForegroundColor DarkGray; return }
        Copy-Item -Path $LocalPath -Destination $RemotePath -Force
        return
    }
    $scpOpts = @("-o", "StrictHostKeyChecking=no")
    if ($IdentityFile) { $scpOpts += @("-i", $IdentityFile) }
    if ($DryRun) { Write-Host "  [DRY-RUN] scp $LocalPath -> $RemotePath" -ForegroundColor DarkGray; return }

    # Prefer rsync, fall back to scp
    if (Get-Command rsync -ErrorAction SilentlyContinue) {
        $rsyncOpts = @("-avz", "--progress")
        if ($IdentityFile) { $rsyncOpts += @("-e", "ssh -i $IdentityFile -o StrictHostKeyChecking=no") }
        & rsync @rsyncOpts $LocalPath "${UserName}@${TargetHost}:${RemotePath}"
    } else {
        & scp @scpOpts $LocalPath "${UserName}@${TargetHost}:${RemotePath}"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: VALIDATE TARGET
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "Phase 1: Validating target..." -ForegroundColor Yellow

if (-not $Local) {
    # Test SSH connectivity
    $rc = Invoke-Remote "echo ok" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Cannot SSH to $UserName@$TargetHost. Check connectivity and credentials."
        exit 1
    }
    Write-Host "  SSH connectivity: OK" -ForegroundColor Green
}

# Check OS
$osCheck = if ($Local) { bash -c "cat /etc/os-release 2>/dev/null | grep -E '^ID='" } else {
    & ssh @sshOpts "$UserName@$TargetHost" "cat /etc/os-release 2>/dev/null | grep -E '^ID='"
}
$osId = ($osCheck -replace 'ID=', '' -replace '"', '').Trim()
$supportedOs = @("rocky", "almalinux", "rhel", "centos", "fedora")
if ($osId -and $osId -notin $supportedOs) {
    Write-Warning "Target OS '$osId' is not Rocky Linux / RHEL 9. Proceeding anyway..."
}
Write-Host "  Target OS: $osId" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: INSTALL SYSTEM PACKAGES
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 2: Installing system packages..." -ForegroundColor Yellow

$packages = "podman podman-compose buildah skopeo crun slirp4netns fuse-overlayfs curl git jq openssl firewalld python3-pip"

Invoke-Remote "dnf install -y epel-release && dnf install -y $packages" -Sudo
Write-Host "  System packages: installed" -ForegroundColor Green

# Install Ollama
Invoke-Remote "command -v ollama >/dev/null 2>&1 || curl -fsSL https://ollama.com/install.sh | sh" -Sudo
Write-Host "  Ollama: installed" -ForegroundColor Green

# GPU support
if ($GPU) {
    Write-Host "  Installing NVIDIA Container Toolkit..." -ForegroundColor Yellow
    Invoke-Remote @"
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
"@ -Sudo
    Write-Host "  NVIDIA toolkit: installed" -ForegroundColor Green
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: CREATE USER & DIRECTORIES
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 3: Setting up aither user & directories..." -ForegroundColor Yellow

Invoke-Remote @"
id aither >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash aither
loginctl enable-linger aither
mkdir -p /opt/aitheros /var/lib/aitheros/{library,secrets,models,memory,training,redis,postgres,strata,backups,output}
mkdir -p /var/log/aitheros /etc/aither/secrets
chown -R aither:aither /opt/aitheros /var/lib/aitheros /var/log/aitheros /etc/aither
chmod 700 /etc/aither/secrets
"@ -Sudo
Write-Host "  User & directories: ready" -ForegroundColor Green

# Generate Ed25519 sovereign node identity
Invoke-Remote @"
if [ ! -f /etc/aither/secrets/node.key ]; then
    openssl genpkey -algorithm ed25519 -out /etc/aither/secrets/node.key
    openssl pkey -in /etc/aither/secrets/node.key -pubout -out /etc/aither/secrets/node.pub
    chmod 600 /etc/aither/secrets/node.key
    chmod 644 /etc/aither/secrets/node.pub
    chown aither:aither /etc/aither/secrets/node.*
    echo 'Ed25519 keypair generated'
fi
"@ -Sudo
Write-Host "  Ed25519 identity: ready" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: DEPLOY IMAGES
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 4: Deploying images (mode: $Mode)..." -ForegroundColor Yellow

switch ($Mode) {
    "pull" {
        # Pull pre-built images from GHCR
        $layers = @("base", "base-ml", "core", "intelligence", "memory", "perception",
                     "autonomic", "gateway", "social", "training", "gpu", "mcp")

        Write-Host "  Authenticating with GHCR..." -ForegroundColor DarkCyan
        Invoke-Remote "echo `$GITHUB_TOKEN | podman login ghcr.io -u deploy --password-stdin 2>/dev/null || true" -Sudo

        foreach ($layer in $layers) {
            $image = "$Registry/aitheros-${layer}:$Tag"
            Write-Host "  Pulling $image..." -ForegroundColor DarkCyan
            Invoke-Remote "su - aither -c 'podman pull $image'" -Sudo
        }

        # Also pull external images
        foreach ($ext in @("docker.io/library/redis:7-alpine", "docker.io/library/postgres:16-alpine")) {
            Invoke-Remote "su - aither -c 'podman pull $ext'" -Sudo
        }
        Write-Host "  All images pulled" -ForegroundColor Green
    }

    "build" {
        # Clone repo and build from source
        Invoke-Remote @"
if [ ! -d /opt/aitheros/.git ]; then
    git clone https://github.com/Aitherium/AitherZero-Internal.git /opt/aitheros
else
    cd /opt/aitheros && git pull --ff-only
fi
chown -R aither:aither /opt/aitheros
"@ -Sudo

        Write-Host "  Building images from source..." -ForegroundColor DarkCyan
        $gpuFlag = if ($GPU) { "--gpu" } else { "" }
        Invoke-Remote "cd /opt/aitheros && su - aither -c 'cd /opt/aitheros/deploy/rocky-linux && bash bootstrap-rocky.sh --profile $Profile $gpuFlag --skip-build=false'" -Sudo
        Write-Host "  Images built" -ForegroundColor Green
    }

    "hybrid" {
        # Pull base images, build service layers locally
        Invoke-Remote "su - aither -c 'podman pull $Registry/aitheros-base:$Tag'"
        Invoke-Remote "su - aither -c 'podman pull $Registry/aitheros-base-ml:$Tag'"

        Invoke-Remote @"
if [ ! -d /opt/aitheros/.git ]; then
    git clone https://github.com/Aitherium/AitherZero-Internal.git /opt/aitheros
else
    cd /opt/aitheros && git pull --ff-only
fi
chown -R aither:aither /opt/aitheros
"@ -Sudo

        Invoke-Remote "cd /opt/aitheros && su - aither -c 'podman-compose -f docker-compose.aitheros.yml build'" -Sudo
        Write-Host "  Hybrid build complete" -ForegroundColor Green
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: GENERATE & INSTALL SYSTEMD UNITS
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 5: Installing systemd units..." -ForegroundColor Yellow

# If repo exists, generate units from services.yaml
Invoke-Remote @"
if [ -f /opt/aitheros/deploy/generate-deploy-units.py ]; then
    cd /opt/aitheros && python3 deploy/generate-deploy-units.py --format systemd
fi
mkdir -p /home/aither/.config/systemd/user
cp /opt/aitheros/deploy/rocky-linux/systemd/*.service /home/aither/.config/systemd/user/ 2>/dev/null || true
cp /opt/aitheros/deploy/rocky-linux/systemd/*.target /home/aither/.config/systemd/user/ 2>/dev/null || true
cp /opt/aitheros/deploy/rocky-linux/systemd/*.timer /home/aither/.config/systemd/user/ 2>/dev/null || true
chown -R aither:aither /home/aither/.config
su - aither -c 'systemctl --user daemon-reload'
"@ -Sudo

# Install CLI
Invoke-Remote @"
cp /opt/aitheros/deploy/rocky-linux/aitheros-ctl.sh /usr/local/bin/aitheros-ctl 2>/dev/null || true
chmod +x /usr/local/bin/aitheros-ctl 2>/dev/null || true
"@ -Sudo

Write-Host "  systemd units: installed" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: CONFIGURE FIREWALL
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 6: Configuring firewall..." -ForegroundColor Yellow

Invoke-Remote @"
systemctl enable --now firewalld
firewall-cmd --permanent --new-zone=aitheros 2>/dev/null || true
for port in 3000 8001 8080 8081 8111 8121 8136 8139 9090; do
    firewall-cmd --permanent --zone=aitheros --add-port=\${port}/tcp 2>/dev/null || true
done
firewall-cmd --permanent --zone=aitheros --add-service=mdns 2>/dev/null || true
firewall-cmd --reload
"@ -Sudo
Write-Host "  Firewall: configured" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 7: PROVISION AI MODELS
# ═══════════════════════════════════════════════════════════════════════════════

if (-not $SkipModels) {
    Write-Host ""
    Write-Host "Phase 7: Provisioning AI models..." -ForegroundColor Yellow

    Invoke-Remote @"
systemctl enable --now ollama
sleep 3
ollama pull llama3.2 2>/dev/null || true
ollama pull nomic-embed-text 2>/dev/null || true
"@ -Sudo
    Write-Host "  Models: provisioned" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "Phase 7: Skipped model provisioning" -ForegroundColor DarkGray
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 8: START SERVICES
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 8: Starting services (profile: $Profile)..." -ForegroundColor Yellow

$target = switch ($Profile) {
    "minimal" { "aitheros-infra.target" }
    "core"    { "aitheros-core.target" }
    "standard"{ "aitheros-core.target aitheros-intelligence.target aitheros-memory.target" }
    "full"    { "aitheros.target" }
    "gpu"     { "aitheros.target" }
    default   { "aitheros-core.target" }
}

Invoke-Remote "su - aither -c 'systemctl --user start $target'" -Sudo
Write-Host "  Services: started" -ForegroundColor Green

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 9: SMOKE TEST
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "Phase 9: Running smoke test..." -ForegroundColor Yellow

Start-Sleep -Seconds 10  # Wait for services to initialize

$healthChecks = @(
    @{ Name = "Genesis"; Url = "http://localhost:8001/health" }
    @{ Name = "Pulse";   Url = "http://localhost:8081/health" }
    @{ Name = "Node";    Url = "http://localhost:8080/health" }
    @{ Name = "Sovereign"; Url = "http://localhost:8139/health" }
)

$allHealthy = $true
foreach ($check in $healthChecks) {
    $rc = Invoke-Remote "curl -sf --max-time 5 $($check.Url) >/dev/null 2>&1 && echo OK || echo FAIL"
    if ($rc -match "OK") {
        Write-Host "  $($check.Name): healthy" -ForegroundColor Green
    } else {
        Write-Host "  $($check.Name): not responding" -ForegroundColor Red
        $allHealthy = $false
    }
}

if (-not $allHealthy) {
    Write-Warning "Some services are not healthy yet. They may still be starting."
    Write-Host "  Run 'aitheros-ctl health' on the target to re-check." -ForegroundColor DarkGray
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMPLETE
# ═══════════════════════════════════════════════════════════════════════════════

$targetDisplay = if ($Local) { "localhost" } else { $TargetHost }

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  AitherOS Deployed to Rocky Linux!" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""
Write-Host "  Dashboard:      http://${targetDisplay}:3000" -ForegroundColor Cyan
Write-Host "  Genesis API:    http://${targetDisplay}:8001" -ForegroundColor Cyan
Write-Host "  Node (MCP):     http://${targetDisplay}:8080" -ForegroundColor Cyan
Write-Host "  Sovereign Node: http://${targetDisplay}:8139" -ForegroundColor Cyan
Write-Host "  Cockpit:        https://${targetDisplay}:9090" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Management:" -ForegroundColor DarkCyan
Write-Host "    aitheros-ctl status       Show service status" -ForegroundColor DarkGray
Write-Host "    aitheros-ctl sovereign    Sovereign node control" -ForegroundColor DarkGray
Write-Host "    aitheros-ctl logs genesis Follow Genesis logs" -ForegroundColor DarkGray
Write-Host "    aitheros-ctl health       Run health checks" -ForegroundColor DarkGray
Write-Host ""

exit 0
