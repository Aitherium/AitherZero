<#
.SYNOPSIS
    Tests AitherOS container images in a VM.
    
.DESCRIPTION
    Launches a virtual machine using QEMU/KVM to test the AitherOS
    bootable container image before deployment.
    
.PARAMETER ImagePath
    Path to ISO or raw disk image

.PARAMETER Memory
    VM memory in GB (default: 8)

.PARAMETER CPUs
    Number of vCPUs (default: 4)

.PARAMETER EnableGPU
    Enable GPU passthrough (requires VFIO setup)

.PARAMETER VNC
    Enable VNC display (default port 5900)

.PARAMETER SSH
    Forward SSH port (host:guest format, e.g., 2222:22)

.PARAMETER ShowOutput
    Show verbose output

.EXAMPLE
    ./0073_Test-AitherOSVM.ps1 -ImagePath ./build/iso/aitheros.iso
    
.EXAMPLE
    ./0073_Test-AitherOSVM.ps1 -ImagePath ./aitheros.qcow2 -Memory 16 -EnableGPU
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ImagePath,
    
    [Parameter()]
    [int]$Memory = 8,
    
    [Parameter()]
    [int]$CPUs = 4,
    
    [Parameter()]
    [switch]$EnableGPU,
    
    [Parameter()]
    [switch]$VNC,
    
    [Parameter()]
    [string]$SSH = '2222:22',
    
    [Parameter()]
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Stop'

# Source shared utilities
$initPath = Join-Path $PSScriptRoot '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AitherOS VM Test Environment                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Validate image
if (-not (Test-Path $ImagePath)) {
    Write-Error "Image not found: $ImagePath"
    exit 1
}

$imageExt = [System.IO.Path]::GetExtension($ImagePath).ToLower()
$isISO = $imageExt -eq '.iso'

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Image:    $ImagePath"
Write-Host "  Type:     $(if ($isISO) { 'ISO (installer)' } else { 'Disk image' })"
Write-Host "  Memory:   ${Memory}GB"
Write-Host "  CPUs:     $CPUs"
Write-Host "  GPU:      $EnableGPU"
Write-Host "  SSH:      $SSH"

# Check for QEMU
$qemu = Get-Command 'qemu-system-x86_64' -ErrorAction SilentlyContinue

if (-not $qemu) {
    # Try common Windows paths
    $qemuPaths = @(
        'C:\Program Files\qemu\qemu-system-x86_64.exe',
        'C:\msys64\mingw64\bin\qemu-system-x86_64.exe'
    )
    
    foreach ($path in $qemuPaths) {
        if (Test-Path $path) {
            $qemu = $path
            break
        }
    }
}

if (-not $qemu) {
    Write-Host ""
    Write-Host "QEMU not found. Install QEMU or use Hyper-V/VMware instead." -ForegroundColor Red
    Write-Host ""
    Write-Host "Alternative: Use Hyper-V Quick Create with the ISO" -ForegroundColor Yellow
    exit 1
}

# Build QEMU command
$qemuArgs = @(
    '-machine', 'q35,accel=kvm'
    '-cpu', 'host'
    '-smp', $CPUs
    '-m', "${Memory}G"
    '-enable-kvm'
)

# Disk/ISO configuration
if ($isISO) {
    # Create temporary disk for installation
    $tempDisk = Join-Path ([System.IO.Path]::GetTempPath()) 'aitheros-test.qcow2'
    
    if (-not (Test-Path $tempDisk)) {
        Write-Host ""
        Write-Host "Creating test disk: $tempDisk" -ForegroundColor Cyan
        & qemu-img create -f qcow2 $tempDisk 64G
    }
    
    $qemuArgs += @(
        '-cdrom', $ImagePath
        '-drive', "file=$tempDisk,format=qcow2,if=virtio"
        '-boot', 'd'
    )
} else {
    $qemuArgs += @(
        '-drive', "file=$ImagePath,format=qcow2,if=virtio"
    )
}

# Networking with SSH forward
$sshParts = $SSH -split ':'
$hostPort = $sshParts[0]
$guestPort = $sshParts[1]

$qemuArgs += @(
    '-nic', "user,hostfwd=tcp::${hostPort}-:${guestPort}"
)

# Display
if ($VNC) {
    $qemuArgs += @('-vnc', ':0')
    Write-Host "  VNC:      localhost:5900" -ForegroundColor Cyan
} else {
    $qemuArgs += @('-display', 'gtk')
}

# GPU passthrough (advanced)
if ($EnableGPU) {
    Write-Host ""
    Write-Host "  ⚠ GPU passthrough requires VFIO setup and unbinding GPU from host" -ForegroundColor Yellow
    # This would need specific VFIO device IDs
    # $qemuArgs += @('-device', 'vfio-pci,host=XX:XX.X')
}

# UEFI firmware
$ovmfPaths = @(
    '/usr/share/OVMF/OVMF_CODE.fd',
    '/usr/share/edk2/ovmf/OVMF_CODE.fd',
    'C:\Program Files\qemu\share\edk2-x86_64-code.fd'
)

foreach ($ovmf in $ovmfPaths) {
    if (Test-Path $ovmf) {
        $qemuArgs += @('-bios', $ovmf)
        break
    }
}

Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host "  Starting VM..." -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host ""
Write-Host "  SSH access: ssh -p $hostPort root@localhost" -ForegroundColor Yellow
Write-Host "  Press Ctrl+Alt+G to release mouse capture" -ForegroundColor DarkGray
Write-Host ""

# Launch QEMU
$qemuPath = if ($qemu -is [System.Management.Automation.CommandInfo]) { $qemu.Source } else { $qemu }
& $qemuPath $qemuArgs
