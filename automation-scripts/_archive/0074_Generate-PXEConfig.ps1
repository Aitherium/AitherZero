<#
.SYNOPSIS
    Generates PXE boot configuration for network installation of AitherOS.
    
.DESCRIPTION
    Creates the necessary PXE/iPXE configuration files for network-based
    installation of AitherOS. Supports BIOS and UEFI boot modes.
    
.PARAMETER OutputDir
    Directory for PXE configuration files

.PARAMETER ServerIP
    IP address of the PXE/TFTP server

.PARAMETER ImageUrl
    URL to the AitherOS container image or ISO

.PARAMETER HTTPRoot
    Path to HTTP server root directory

.PARAMETER ShowOutput
    Show verbose output

.EXAMPLE
    ./0074_Generate-PXEConfig.ps1 -ServerIP 192.168.1.10
    
.EXAMPLE
    ./0074_Generate-PXEConfig.ps1 -OutputDir /srv/tftp -HTTPRoot /srv/http
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir = './build/pxe',
    
    [Parameter()]
    [string]$ServerIP = '192.168.1.1',
    
    [Parameter()]
    [string]$ImageUrl = 'ghcr.io/aitherium/aitheros:latest',
    
    [Parameter()]
    [string]$HTTPRoot,
    
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
Write-Host "║           AitherOS PXE Configuration Generator                ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Create output directory
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Output:     $OutputDir"
Write-Host "  Server IP:  $ServerIP"
Write-Host "  Image:      $ImageUrl"

# Create pxelinux.cfg directory
$pxeConfigDir = Join-Path $OutputDir 'pxelinux.cfg'
New-Item -ItemType Directory -Path $pxeConfigDir -Force | Out-Null

# Generate BIOS PXE config (pxelinux)
$biosConfig = @"
# AitherOS PXE Boot Configuration (BIOS)
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

DEFAULT aitheros
TIMEOUT 50
PROMPT 1

MENU TITLE AitherOS Network Boot
MENU AUTOBOOT Booting AitherOS in # seconds...

LABEL aitheros
    MENU LABEL ^AitherOS Atomic (Auto Install)
    KERNEL vmlinuz
    INITRD initrd.img
    APPEND rd.bootc.image=$ImageUrl console=tty0 console=ttyS0,115200n8 ip=dhcp

LABEL aitheros-interactive
    MENU LABEL ^AitherOS Atomic (Interactive)
    KERNEL vmlinuz
    INITRD initrd.img
    APPEND rd.bootc.image=$ImageUrl console=tty0 console=ttyS0,115200n8 ip=dhcp rd.break

LABEL local
    MENU LABEL Boot from ^Local Disk
    LOCALBOOT 0

LABEL memtest
    MENU LABEL ^Memory Test
    KERNEL memtest86+
"@

$biosConfig | Out-File -FilePath (Join-Path $pxeConfigDir 'default') -Encoding UTF8 -Force
Write-Host "  ✓ Created: pxelinux.cfg/default" -ForegroundColor Green

# Generate UEFI GRUB config
$grubConfigDir = Join-Path $OutputDir 'grub'
New-Item -ItemType Directory -Path $grubConfigDir -Force | Out-Null

$grubConfig = @"
# AitherOS GRUB Configuration (UEFI)
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

set default=0
set timeout=5

menuentry 'AitherOS Atomic (Auto Install)' {
    linuxefi vmlinuz rd.bootc.image=$ImageUrl console=tty0 console=ttyS0,115200n8 ip=dhcp
    initrdefi initrd.img
}

menuentry 'AitherOS Atomic (Interactive)' {
    linuxefi vmlinuz rd.bootc.image=$ImageUrl console=tty0 console=ttyS0,115200n8 ip=dhcp rd.break
    initrdefi initrd.img
}

menuentry 'Boot from Local Disk' {
    exit
}
"@

$grubConfig | Out-File -FilePath (Join-Path $grubConfigDir 'grub.cfg') -Encoding UTF8 -Force
Write-Host "  ✓ Created: grub/grub.cfg" -ForegroundColor Green

# Generate iPXE script
$ipxeConfig = @"
#!ipxe
# AitherOS iPXE Boot Script
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

set server http://${ServerIP}
set image $ImageUrl

menu AitherOS Network Boot
item --gap -- -----------------------------------------
item aitheros     AitherOS Atomic (Auto Install)
item interactive  AitherOS Atomic (Interactive)
item --gap -- -----------------------------------------
item local        Boot from Local Disk
item shell        iPXE Shell
choose --default aitheros --timeout 5000 target && goto `${target}

:aitheros
kernel `${server}/vmlinuz rd.bootc.image=`${image} console=tty0 ip=dhcp
initrd `${server}/initrd.img
boot

:interactive
kernel `${server}/vmlinuz rd.bootc.image=`${image} console=tty0 ip=dhcp rd.break
initrd `${server}/initrd.img
boot

:local
exit

:shell
shell
"@

$ipxeConfig | Out-File -FilePath (Join-Path $OutputDir 'boot.ipxe') -Encoding UTF8 -Force
Write-Host "  ✓ Created: boot.ipxe" -ForegroundColor Green

# Generate dnsmasq config snippet
$dnsmasqConfig = @"
# AitherOS PXE - dnsmasq configuration snippet
# Add to /etc/dnsmasq.conf or /etc/dnsmasq.d/aitheros.conf

# Enable TFTP
enable-tftp
tftp-root=$OutputDir

# PXE boot for BIOS clients
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0

# PXE boot for UEFI clients
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,grub/grubx64.efi

# iPXE chain loading
dhcp-match=set:ipxe,175
dhcp-boot=tag:ipxe,boot.ipxe
"@

$dnsmasqConfig | Out-File -FilePath (Join-Path $OutputDir 'dnsmasq-aitheros.conf') -Encoding UTF8 -Force
Write-Host "  ✓ Created: dnsmasq-aitheros.conf" -ForegroundColor Green

# Summary
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host "  PXE Configuration Generated!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Blue
Write-Host ""
Write-Host "  Files created in: $OutputDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Copy vmlinuz and initrd.img from the ISO to $OutputDir"
Write-Host "    2. Configure DHCP server with dnsmasq-aitheros.conf"
Write-Host "    3. Start TFTP server pointing to $OutputDir"
Write-Host "    4. Boot clients via network"
Write-Host ""
