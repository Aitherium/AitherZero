#Requires -Version 7.0
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Build a custom Windows Server 2025 Core ISO with AitherOS bootstrap baked in.

.DESCRIPTION
    Takes a stock Windows Server 2025 evaluation/retail ISO and produces a custom ISO
    containing:
      - Autounattend.xml for zero-touch installation (UEFI GPT, WinRM, admin account)
      - First-boot PowerShell script that bootstraps AitherOS (Docker, PSRemoting, node join)
      - Optional driver injection (virtio, storage, NIC)
      - Optional package/feature injection

    Uses DISM and oscdimg (from Windows ADK) to mount, modify, and repack the ISO.

    The resulting ISO can be:
      - Mounted to a Hyper-V VM via OpenTofu (modules/vm/ iso_path)
      - Written to USB via 3005_Create-BootableUSB.ps1
      - Served over PXE for network boot

.PARAMETER SourceISO
    Path to the stock Windows Server 2025 ISO.

.PARAMETER OutputPath
    Directory for the built ISO. Defaults to config IsoSharePath.

.PARAMETER OutputName
    Filename for the custom ISO. Default: AitherOS-Server2025-Core.iso

.PARAMETER Edition
    Windows edition index to extract. Default: 'Windows Server 2025 SERVERSTANDARDCORE'
    Use 'DISM /Get-WimInfo /WimFile:install.wim' to list indices.

.PARAMETER EditionIndex
    Numeric edition index (alternative to Edition name). Default: auto-detect Core.

.PARAMETER ComputerName
    Computer name baked into Autounattend.xml. Default: AITHER-NODE

.PARAMETER AdminPassword
    Local Administrator password. Default: generated and written to output.

.PARAMETER TimeZone
    Windows timezone. Default: 'Eastern Standard Time'

.PARAMETER ProductKey
    Product key for activation. Omit for eval/KMS.

.PARAMETER DriverPaths
    Array of paths containing .inf driver packages to inject.

.PARAMETER FirstBootScriptPath
    Custom first-boot script. If omitted, generates the standard AitherOS bootstrap.

.PARAMETER AitherOSBranch
    Git branch for the AitherOS bootstrap clone. Default: 'develop'

.PARAMETER MeshCoreUrl
    URL of the MeshCore endpoint for auto-join. Default: http://192.168.1.100:8125

.PARAMETER NodeProfile
    AitherOS deployment profile (Full, Core, Minimal, GPU, Edge). Default: Core

.PARAMETER IncludeOpenSSH
    Install and enable OpenSSH Server during first boot.

.PARAMETER IncludeHyperV
    Enable nested Hyper-V role during first boot.

.PARAMETER SkipCleanup
    Keep temporary mount/work directories after build.

.PARAMETER DryRun
    Show what would happen without modifying anything.

.EXAMPLE
    .\3105_Build-WindowsISO.ps1 -SourceISO 'C:\ISOs\Server2025.iso'
    Builds a custom Core ISO with default settings.

.EXAMPLE
    .\3105_Build-WindowsISO.ps1 -SourceISO 'D:\ISOs\26100.iso' -ComputerName 'AITHER-GPU-01' -NodeProfile GPU -IncludeOpenSSH
    Builds a GPU-optimized node ISO with SSH.

.NOTES
    Requires: Windows ADK (oscdimg.exe), DISM, Administrator privileges.
    The oscdimg.exe path is auto-detected from ADK install or can be set via $env:OSCDIMG_PATH.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$SourceISO,

    [string]$OutputPath,

    [string]$OutputName = 'AitherOS-Server2025-Core.iso',

    [string]$Edition = 'Windows Server 2025 SERVERSTANDARDCORE',

    [int]$EditionIndex = 0,

    [string]$ComputerName = 'AITHER-NODE',

    [securestring]$AdminPassword,

    [string]$TimeZone = 'Eastern Standard Time',

    [string]$ProductKey,

    [string[]]$DriverPaths,

    [string]$FirstBootScriptPath,

    [string]$AitherOSBranch = 'develop',

    [string]$MeshCoreUrl = 'http://192.168.1.100:8125',

    [ValidateSet('Full', 'Core', 'Minimal', 'GPU', 'Edge')]
    [string]$NodeProfile = 'Core',

    [switch]$IncludeOpenSSH,

    [switch]$IncludeHyperV,

    [switch]$SkipCleanup,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────
# Resolve paths and prerequisites
# ─────────────────────────────────────────────
$scriptRoot = $PSScriptRoot
$projectRoot = (Resolve-Path (Join-Path $scriptRoot '..\..\..\..')).Path

# Try loading AitherZero config for default paths
try {
    Import-Module (Join-Path $projectRoot 'AitherZero\AitherZero.psd1') -Force -ErrorAction SilentlyContinue
    $azConfig = Import-PowerShellDataFile (Join-Path $projectRoot 'AitherZero\config\domains\infrastructure.psd1')
    if (-not $OutputPath) {
        $OutputPath = $azConfig.Infrastructure.Directories.IsoSharePath
    }
}
catch {
    Write-Warning "Could not load AitherZero config: $($_.Exception.Message)"
}

if (-not $OutputPath) { $OutputPath = 'C:\ISOs' }
if (-not (Test-Path $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

# Find oscdimg.exe
$oscdimg = $env:OSCDIMG_PATH
if (-not $oscdimg) {
    $adkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $adkPaths) {
        if (Test-Path $p) { $oscdimg = $p; break }
    }
}

if (-not $oscdimg -or -not (Test-Path $oscdimg)) {
    # Try auto-installing Windows ADK
    Write-Host "  oscdimg.exe not found — attempting auto-install of Windows ADK..." -ForegroundColor Yellow
    $adkInstaller = Join-Path $scriptRoot '..\01-infrastructure\0101_Install-WindowsADK.ps1'
    if (-not (Test-Path $adkInstaller)) {
        $adkInstaller = Join-Path $projectRoot 'AitherZero\library\automation-scripts\01-infrastructure\0101_Install-WindowsADK.ps1'
    }

    if (Test-Path $adkInstaller) {
        try {
            & $adkInstaller -ErrorAction Stop
            # Re-check after install
            if ($env:OSCDIMG_PATH -and (Test-Path $env:OSCDIMG_PATH)) {
                $oscdimg = $env:OSCDIMG_PATH
            }
            else {
                foreach ($p in $adkPaths) {
                    if (Test-Path $p) { $oscdimg = $p; break }
                }
            }
        }
        catch {
            Write-Warning "  Auto-install failed: $($_.Exception.Message)"
        }
    }

    # Final check — if still not found, throw with manual instructions
    if (-not $oscdimg -or -not (Test-Path $oscdimg)) {
        throw @"
oscdimg.exe not found and auto-install failed. Install Windows ADK manually:
  winget install Microsoft.WindowsADK
  winget install Microsoft.ADKWinPEAddons
Or set `$env:OSCDIMG_PATH to the full path.
Or run: .\01-infrastructure\0101_Install-WindowsADK.ps1
"@
    }
    else {
        Write-Host "  oscdimg.exe found after auto-install: $oscdimg" -ForegroundColor Green
    }
}

# Verify DISM
if (-not (Get-Command dism.exe -ErrorAction SilentlyContinue)) {
    throw "DISM not found. This script must run on Windows with DISM available."
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " AitherOS Custom ISO Builder" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Source:      $SourceISO"
Write-Host "  Output:      $OutputPath\$OutputName"
Write-Host "  Computer:    $ComputerName"
Write-Host "  Profile:     $NodeProfile"
Write-Host "  Branch:      $AitherOSBranch"
Write-Host "  MeshCore:    $MeshCoreUrl"
Write-Host "  OpenSSH:     $IncludeOpenSSH"
Write-Host "  Drivers:     $($DriverPaths.Count) path(s)"
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] Would build custom ISO. Exiting." -ForegroundColor Yellow
    return
}

# ─────────────────────────────────────────────
# Work directory setup
# ─────────────────────────────────────────────
$workDir = Join-Path $env:TEMP "AitherISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$mountDir = Join-Path $workDir 'mount'
$extractDir = Join-Path $workDir 'iso_extract'
$floppy = Join-Path $workDir 'floppy'

New-Item -Path $workDir, $mountDir, $extractDir, $floppy -ItemType Directory -Force | Out-Null

try {
    # ─────────────────────────────────────────
    # Step 1: Mount source ISO and extract
    # ─────────────────────────────────────────
    Write-Host "`n[1/7] Mounting source ISO..." -ForegroundColor Yellow
    $mountResult = Mount-DiskImage -ImagePath (Resolve-Path $SourceISO).Path -PassThru
    $driveLetter = ($mountResult | Get-Volume).DriveLetter
    $isoRoot = "${driveLetter}:\"

    Write-Host "  Mounted at $isoRoot"

    # Copy ISO contents to work directory (need write access)
    Write-Host "  Extracting ISO contents to $extractDir ..."
    robocopy "$isoRoot" "$extractDir" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null

    # Dismount source ISO early
    Dismount-DiskImage -ImagePath (Resolve-Path $SourceISO).Path | Out-Null

    # ─────────────────────────────────────────
    # Step 2: Identify and validate WIM
    # ─────────────────────────────────────────
    Write-Host "`n[2/7] Inspecting install image..." -ForegroundColor Yellow
    $wimPath = Join-Path $extractDir 'sources\install.wim'
    if (-not (Test-Path $wimPath)) {
        # ESD format - need to convert
        $esdPath = Join-Path $extractDir 'sources\install.esd'
        if (Test-Path $esdPath) {
            Write-Host "  Found ESD format, converting to WIM..."
            $wimPath = Join-Path $extractDir 'sources\install.wim'
            dism /Export-Image /SourceImageFile:$esdPath /SourceIndex:$EditionIndex /DestinationImageFile:$wimPath /Compress:max /CheckIntegrity
            Remove-Item $esdPath -Force
        }
        else {
            throw "Neither install.wim nor install.esd found in ISO"
        }
    }

    # List available editions
    $wimInfo = dism /Get-WimInfo /WimFile:$wimPath 2>&1 | Out-String
    Write-Host "  Available editions:`n$wimInfo"

    # Auto-detect Core index if not specified
    if ($EditionIndex -eq 0) {
        $match = [regex]::Match($wimInfo, 'Index\s*:\s*(\d+)\s*\r?\n\s*Name\s*:\s*.*SERVERSTANDARDCORE', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $EditionIndex = [int]$match.Groups[1].Value
            Write-Host "  Auto-detected Server Core index: $EditionIndex" -ForegroundColor Green
        }
        else {
            # Fallback: try index 3 (common for Server Core)
            $EditionIndex = 3
            Write-Warning "Could not auto-detect Core index. Using index $EditionIndex. Verify with DISM /Get-WimInfo."
        }
    }

    # ─────────────────────────────────────────
    # Step 3: Mount WIM and customize
    # ─────────────────────────────────────────
    Write-Host "`n[3/7] Mounting WIM for offline customization..." -ForegroundColor Yellow
    dism /Mount-Wim /WimFile:$wimPath /Index:$EditionIndex /MountDir:$mountDir

    # Inject drivers if provided
    if ($DriverPaths.Count -gt 0) {
        Write-Host "`n[3a] Injecting drivers..." -ForegroundColor Yellow
        foreach ($dp in $DriverPaths) {
            if (Test-Path $dp) {
                Write-Host "  Adding drivers from $dp"
                dism /Image:$mountDir /Add-Driver /Driver:$dp /Recurse /ForceUnsigned
            }
            else {
                Write-Warning "Driver path not found: $dp"
            }
        }
    }

    # Enable features in the offline image
    Write-Host "`n[3b] Enabling Windows features..." -ForegroundColor Yellow
    # WinRM requires these
    dism /Image:$mountDir /Enable-Feature /FeatureName:WCF-HTTP-Activation45 /All 2>$null
    dism /Image:$mountDir /Enable-Feature /FeatureName:NetFx4-AdvSrvs /All 2>$null

    if ($IncludeHyperV) {
        Write-Host "  Enabling Hyper-V role..."
        dism /Image:$mountDir /Enable-Feature /FeatureName:Microsoft-Hyper-V /All 2>$null
        dism /Image:$mountDir /Enable-Feature /FeatureName:Microsoft-Hyper-V-Management-PowerShell /All 2>$null
    }

    if ($IncludeOpenSSH) {
        Write-Host "  Enabling OpenSSH Server..."
        dism /Image:$mountDir /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 2>$null
    }

    # ─────────────────────────────────────────
    # Step 4: Generate Autounattend.xml
    # ─────────────────────────────────────────
    Write-Host "`n[4/7] Generating Autounattend.xml..." -ForegroundColor Yellow

    # Generate admin password
    $plainPassword = if ($AdminPassword) {
        [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
        )
    }
    else {
        # Generate a random password and save it
        $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%'
        $pw = -join (1..20 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
        $credFile = Join-Path $OutputPath "$ComputerName.credentials.txt"
        "Computer: $ComputerName`nAdmin Password: $pw`nGenerated: $(Get-Date -Format 'o')" | Set-Content $credFile -Force
        Write-Host "  Admin credentials saved to: $credFile" -ForegroundColor Green
        $pw
    }

    $productKeyXml = if ($ProductKey) {
        @"
                <ProductKey>
                    <Key>$ProductKey</Key>
                    <WillShowUI>OnError</WillShowUI>
                </ProductKey>
"@
    }
    else { '' }

    $autounattendXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">

    <!-- ========== WindowsPE: Disk & Install ========== -->
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            $productKeyXml
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <!-- EFI System Partition -->
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>300</Size>
                            <Type>EFI</Type>
                        </CreatePartition>
                        <!-- MSR -->
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Size>128</Size>
                            <Type>MSR</Type>
                        </CreatePartition>
                        <!-- Windows -->
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>FAT32</Format>
                            <Label>EFI</Label>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>3</PartitionID>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>$EditionIndex</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                </OSImage>
            </ImageInstall>
            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>AitherOS</FullName>
                <Organization>Aitherium</Organization>
            </UserData>
        </component>
    </settings>

    <!-- ========== Specialize: Networking & Computer ========== -->
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>$ComputerName</ComputerName>
            <TimeZone>$TimeZone</TimeZone>
        </component>
        <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <fDenyTSConnections>false</fDenyTSConnections>
        </component>
        <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <FirewallGroups>
                <FirewallGroup wcm:action="add" keyValue="RemoteDesktop">
                    <Active>true</Active>
                    <Group>Remote Desktop</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
                <FirewallGroup wcm:action="add" keyValue="WinRM">
                    <Active>true</Active>
                    <Group>Windows Remote Management</Group>
                    <Profile>all</Profile>
                </FirewallGroup>
            </FirewallGroups>
        </component>
    </settings>

    <!-- ========== OOBE: Admin + First Logon ========== -->
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"
                   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$plainPassword</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>Administrator</Username>
                <Password>
                    <Value>$plainPassword</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -ExecutionPolicy Bypass -File C:\AitherOS\first-boot.ps1</CommandLine>
                    <Description>AitherOS First Boot Bootstrap</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
"@

    # Write Autounattend.xml into the ISO root
    $autounattendXml | Set-Content (Join-Path $extractDir 'Autounattend.xml') -Encoding UTF8
    Write-Host "  Autounattend.xml written" -ForegroundColor Green

    # ─────────────────────────────────────────
    # Step 5: Generate first-boot script
    # ─────────────────────────────────────────
    Write-Host "`n[5/7] Generating first-boot bootstrap script..." -ForegroundColor Yellow

    $firstBootDir = Join-Path $mountDir 'AitherOS'
    New-Item -Path $firstBootDir -ItemType Directory -Force | Out-Null

    if ($FirstBootScriptPath -and (Test-Path $FirstBootScriptPath)) {
        Copy-Item $FirstBootScriptPath (Join-Path $firstBootDir 'first-boot.ps1') -Force
        Write-Host "  Using custom first-boot script: $FirstBootScriptPath"
    }
    else {
        $sshBlock = if ($IncludeOpenSSH) {
            @'

# ── OpenSSH Server ──────────────────────────
Write-Output "[AitherOS] Configuring OpenSSH Server..."
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server (sshd)" `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
    -ErrorAction SilentlyContinue
'@
        }
        else { '' }

        $firstBootScript = @"
#Requires -Version 5.1
# AitherOS First Boot Bootstrap — Auto-generated by 3105_Build-WindowsISO.ps1
# This script runs ONCE on first login via Autounattend.xml FirstLogonCommands.

`$ErrorActionPreference = 'Continue'
`$LogFile = 'C:\AitherOS\first-boot.log'
Start-Transcript -Path `$LogFile -Append

Write-Output "============================================"
Write-Output " AitherOS First Boot — `$(Get-Date -Format 'o')"
Write-Output " Computer: `$env:COMPUTERNAME"
Write-Output " Profile:  $NodeProfile"
Write-Output "============================================"

# ── Disable auto-logon after first boot ─────
Write-Output "[AitherOS] Disabling auto-logon..."
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value 0 -ErrorAction SilentlyContinue

# ── WinRM Configuration ─────────────────────
Write-Output "[AitherOS] Configuring WinRM..."
winrm quickconfig -force 2>`$null
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value `$true -Force
Set-Item WSMan:\localhost\Service\Auth\Basic -Value `$true -Force
Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Self-signed cert for HTTPS WinRM
`$cert = New-SelfSignedCertificate -DnsName `$env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
New-Item WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint `$cert.Thumbprint -Force -ErrorAction SilentlyContinue
Restart-Service WinRM

# Firewall rules
New-NetFirewallRule -Name "WinRM-HTTP" -DisplayName "WinRM HTTP" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 5985 -ErrorAction SilentlyContinue
New-NetFirewallRule -Name "WinRM-HTTPS" -DisplayName "WinRM HTTPS" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 5986 -ErrorAction SilentlyContinue
$sshBlock

# ── AitherOS Ports ──────────────────────────
Write-Output "[AitherOS] Opening AitherOS service ports..."
`$ports = @(8001, 8080, 8081, 8082, 8111, 8117, 8121, 8125, 8136, 8150, 3000, 2375, 2376)
foreach (`$port in `$ports) {
    New-NetFirewallRule -Name "AitherOS-`$port" -DisplayName "AitherOS port `$port" ``
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort `$port ``
        -ErrorAction SilentlyContinue
}

# ── Install PowerShell 7 ────────────────────
Write-Output "[AitherOS] Installing PowerShell 7..."
try {
    Invoke-Expression "& { `$(Invoke-RestMethod 'https://aka.ms/install-powershell.ps1') } -UseMSI -Quiet"
    Write-Output "  PowerShell 7 installed"
}
catch {
    Write-Warning "PowerShell 7 install failed: `$(`$_.Exception.Message)"
    # Fallback: winget
    winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements 2>`$null
}

# ── Install Docker ──────────────────────────
Write-Output "[AitherOS] Installing Docker..."
try {
    Install-WindowsFeature -Name Containers -IncludeManagementTools -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile 'C:\AitherOS\DockerInstaller.exe' -UseBasicParsing
    Start-Process 'C:\AitherOS\DockerInstaller.exe' -ArgumentList 'install', '--quiet', '--accept-license' -Wait -NoNewWindow
    Write-Output "  Docker installed"
}
catch {
    Write-Warning "Docker install failed: `$(`$_.Exception.Message)"
    # Alternative: Install Docker CE via script
    Invoke-WebRequest -Uri 'https://get.docker.com' -OutFile 'C:\AitherOS\get-docker.ps1' -UseBasicParsing -ErrorAction SilentlyContinue
}

# ── Clone AitherOS and bootstrap ────────────
Write-Output "[AitherOS] Cloning AitherOS repository..."
`$repoDir = 'C:\AitherOS\repo'
try {
    # Install git if not present
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        winget install --id Git.Git --source winget --accept-package-agreements --accept-source-agreements 2>`$null
        `$env:PATH += ";C:\Program Files\Git\cmd"
    }
    git clone --branch $AitherOSBranch --depth 1 'https://github.com/Aitherium/AitherOS.git' `$repoDir
    Write-Output "  Repository cloned"
}
catch {
    Write-Warning "Git clone failed: `$(`$_.Exception.Message)"
}

# ── Signal ready to MeshCore ────────────────
Write-Output "[AitherOS] Signaling MeshCore at $MeshCoreUrl ..."
try {
    `$body = @{
        node_name = `$env:COMPUTERNAME
        role      = 'standby'
        profile   = '$NodeProfile'
        endpoints = @{
            health = "http://`$((Get-NetIPAddress -AddressFamily IPv4 | Where-Object { `$_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1).IPAddress):8081/health"
        }
    } | ConvertTo-Json -Depth 3
    Invoke-RestMethod -Uri '$MeshCoreUrl/mesh/join' -Method POST -Body `$body -ContentType 'application/json' -TimeoutSec 10
    Write-Output "  Mesh join request sent"
}
catch {
    Write-Warning "MeshCore join failed (will retry via watchdog): `$(`$_.Exception.Message)"
}

# ── Marker file ─────────────────────────────
`$marker = @{
    BootstrapComplete = `$true
    Timestamp         = Get-Date -Format 'o'
    ComputerName      = `$env:COMPUTERNAME
    Profile           = '$NodeProfile'
    Branch            = '$AitherOSBranch'
}
`$marker | ConvertTo-Json | Set-Content 'C:\AitherOS\bootstrap-complete.json' -Force

Write-Output ""
Write-Output "============================================"
Write-Output " AitherOS First Boot COMPLETE"
Write-Output " See log: `$LogFile"
Write-Output "============================================"

Stop-Transcript

# Reboot to finalize
Write-Output "Rebooting in 30 seconds..."
shutdown /r /t 30 /c "AitherOS first boot complete — rebooting"
"@
        $firstBootScript | Set-Content (Join-Path $firstBootDir 'first-boot.ps1') -Encoding UTF8
        Write-Host "  Generated standard AitherOS first-boot script" -ForegroundColor Green
    }

    # Also copy bootstrap.ps1 and docker-compose into the image
    $bootstrapSrc = Join-Path $projectRoot 'bootstrap.ps1'
    if (Test-Path $bootstrapSrc) {
        Copy-Item $bootstrapSrc (Join-Path $firstBootDir 'bootstrap.ps1') -Force
        Write-Host "  Copied bootstrap.ps1 into image"
    }

    # ─────────────────────────────────────────
    # Step 6: Unmount WIM and save
    # ─────────────────────────────────────────
    Write-Host "`n[6/7] Committing changes and unmounting WIM..." -ForegroundColor Yellow
    dism /Unmount-Wim /MountDir:$mountDir /Commit
    Write-Host "  WIM committed" -ForegroundColor Green

    # ─────────────────────────────────────────
    # Step 7: Rebuild ISO
    # ─────────────────────────────────────────
    Write-Host "`n[7/7] Building custom ISO..." -ForegroundColor Yellow

    $outputFile = Join-Path $OutputPath $OutputName

    # Find boot files for UEFI
    $efiBoot = Join-Path $extractDir 'efi\microsoft\boot\efisys.bin'
    $biosEtfsboot = Join-Path $extractDir 'boot\etfsboot.com'

    if ((Test-Path $efiBoot) -and (Test-Path $biosEtfsboot)) {
        # Dual-boot ISO (BIOS + UEFI)
        $oscdimgArgs = @(
            '-m', '-o', '-u2', '-udfver102',
            "-bootdata:2#p0,e,b`"$biosEtfsboot`"#pEF,e,b`"$efiBoot`"",
            "`"$extractDir`"",
            "`"$outputFile`""
        )
    }
    elseif (Test-Path $efiBoot) {
        # UEFI only
        $oscdimgArgs = @(
            '-m', '-o', '-u2', '-udfver102',
            "-bootdata:1#pEF,e,b`"$efiBoot`"",
            "`"$extractDir`"",
            "`"$outputFile`""
        )
    }
    else {
        throw "Boot files not found in ISO. Expected efisys.bin and/or etfsboot.com"
    }

    Write-Host "  Running oscdimg..."
    & $oscdimg @oscdimgArgs
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed with exit code $LASTEXITCODE" }

    $isoSize = [math]::Round((Get-Item $outputFile).Length / 1GB, 2)
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host " ISO BUILD COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Output: $outputFile"
    Write-Host "  Size:   ${isoSize} GB"
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Deploy with OpenTofu:  tofu apply -var 'iso_path=$outputFile'"
    Write-Host "    2. Or use Elysium:        Invoke-AitherElysiumDeploy -ComputerName <ip> -ISOPath '$outputFile'"
    Write-Host "    3. Or create VM directly: New-AitherHyperVNode -ISOPath '$outputFile'"
    Write-Host ""
}
finally {
    if (-not $SkipCleanup) {
        Write-Host "`nCleaning up work directory..." -ForegroundColor Gray
        # Ensure WIM is unmounted if something went wrong
        dism /Unmount-Wim /MountDir:$mountDir /Discard 2>$null
        Dismount-DiskImage -ImagePath (Resolve-Path $SourceISO -ErrorAction SilentlyContinue).Path -ErrorAction SilentlyContinue
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "  Work directory preserved: $workDir" -ForegroundColor Yellow
    }
}
