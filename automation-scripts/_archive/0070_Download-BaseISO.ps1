#Requires -Version 7.0

<#
.SYNOPSIS
    Download Base OS ISOs for Infrastructure Deployment

.DESCRIPTION
    Downloads base ISOs from official sources for customization.
    Supports Windows Server, Rocky Linux, and other distros.
    
    Config-driven via config.psd1 Infrastructure.ISOSources section.
    Downloads are verified via SHA256 checksum.

.PARAMETER OS
    Operating system to download: WindowsServer2022, WindowsServer2025,
    Rocky9, Ubuntu2404, AgenticOS

.PARAMETER Destination
    Download destination directory. Default from config.psd1

.PARAMETER Force
    Re-download even if file exists

.PARAMETER Verify
    Verify checksum after download (default: true)

.EXAMPLE
    ./0070_Download-BaseISO.ps1 -OS WindowsServer2022
    Downloads Windows Server 2022 evaluation ISO

.EXAMPLE
    ./0070_Download-BaseISO.ps1 -OS Rocky9 -Destination E:\ISOs
    Downloads Rocky Linux 9 to specified path

.NOTES
    File Name      : 0070_Download-BaseISO.ps1
    Stage          : Infrastructure
    Dependencies   : None
    Tags           : infrastructure, iso, download, automation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('WindowsServer2022', 'WindowsServer2025', 'Rocky9', 'Ubuntu2404', 'AgenticOS', 'All')]
    [string]$OS,

    [Parameter()]
    [string]$Destination,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$SkipVerify,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Download Base OS ISO"

# ISO Source definitions
$ISOSources = @{
    WindowsServer2022 = @{
        Name        = 'Windows Server 2022'
        Url         = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
        FileName    = 'WindowsServer2022.iso'
        Size        = '5.3 GB (evaluation)'
        Notes       = 'Microsoft Evaluation Center - 180 day trial'
        # Checksum varies by download date for eval ISOs
        Checksum    = $null
    }
    WindowsServer2025 = @{
        Name        = 'Windows Server 2025'
        Url         = 'https://go.microsoft.com/fwlink/?linkid=2293500'
        FileName    = 'WindowsServer2025.iso'
        Size        = '~5.5 GB (preview)'
        Notes       = 'Windows Server 2025 Preview'
        Checksum    = $null
    }
    Rocky9 = @{
        Name        = 'Rocky Linux 9.4'
        Url         = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.4-x86_64-minimal.iso'
        FileName    = 'Rocky-9.4-x86_64-minimal.iso'
        Size        = '1.8 GB'
        Checksum    = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/CHECKSUM'
        ChecksumAlgo = 'SHA256'
    }
    Ubuntu2404 = @{
        Name        = 'Ubuntu 24.04 LTS Server'
        Url         = 'https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso'
        FileName    = 'ubuntu-24.04-live-server-amd64.iso'
        Size        = '2.6 GB'
        Checksum    = 'https://releases.ubuntu.com/24.04/SHA256SUMS'
        ChecksumAlgo = 'SHA256'
    }
    AgenticOS = @{
        Name        = 'AgenticOS (Rocky-based)'
        Url         = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.4-x86_64-minimal.iso'
        FileName    = 'AgenticOS-base.iso'
        Size        = '1.8 GB (customize with 0195)'
        Notes       = 'Downloads Rocky base, use 0195 to inject AitherZero artifacts'
        Checksum    = 'https://download.rockylinux.org/pub/rocky/9/isos/x86_64/CHECKSUM'
        ChecksumAlgo = 'SHA256'
    }
}

try {
    # Get destination from config if not specified
    if (-not $Destination) {
        try {
            $config = Get-AitherConfigs
            $Destination = $config.Paths.Data.ISOs
            if (-not $Destination) {
                $Destination = $config.Infrastructure.Defaults.ISOPath
            }
        } catch {
            # Fallback
        }
        
        if (-not $Destination) {
            $Destination = if ($IsWindows) { 'E:\ISOs' } else { "$HOME/aitherzero/isos" }
        }
    }
    
    # Expand any variables
    $Destination = [System.Environment]::ExpandEnvironmentVariables($Destination)
    
    # Create destination directory
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-ScriptLog "Created directory: $Destination"
    }
    
    Write-ScriptLog "Destination: $Destination"
    Write-ScriptLog ""
    
    # Determine which ISOs to download
    $toDownload = if ($OS -eq 'All') {
        $ISOSources.Keys
    } else {
        @($OS)
    }
    
    foreach ($isoKey in $toDownload) {
        $iso = $ISOSources[$isoKey]
        $destPath = Join-Path $Destination $iso.FileName
        
        Write-ScriptLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-ScriptLog "  $($iso.Name)"
        Write-ScriptLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-ScriptLog "  Size: $($iso.Size)"
        if ($iso.Notes) {
            Write-ScriptLog "  Notes: $($iso.Notes)"
        }
        Write-ScriptLog "  URL: $($iso.Url)"
        Write-ScriptLog "  Dest: $destPath"
        Write-ScriptLog ""
        
        # Check if already exists
        if ((Test-Path $destPath) -and -not $Force) {
            Write-ScriptLog "  ✓ Already exists (use -Force to re-download)" -Level 'Information'
            Write-ScriptLog ""
            continue
        }
        
        # Download
        Write-ScriptLog "  Downloading... (this may take a while)"
        
        try {
            # Use BITS on Windows for resume support, curl elsewhere
            if ($IsWindows) {
                $bitsJob = Start-BitsTransfer -Source $iso.Url -Destination $destPath -Asynchronous
                
                # Monitor progress
                while ($bitsJob.JobState -eq 'Transferring' -or $bitsJob.JobState -eq 'Connecting') {
                    $pct = [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 1)
                    Write-Progress -Activity "Downloading $($iso.Name)" -Status "$pct% Complete" -PercentComplete $pct
                    Start-Sleep -Milliseconds 500
                }
                
                if ($bitsJob.JobState -eq 'Transferred') {
                    Complete-BitsTransfer -BitsJob $bitsJob
                    Write-ScriptLog "  ✓ Download complete"
                } else {
                    throw "BITS transfer failed: $($bitsJob.JobState)"
                }
            } else {
                # Use curl for Linux/macOS
                $curlArgs = @('-L', '-o', $destPath, '--progress-bar', $iso.Url)
                & curl @curlArgs
                
                if ($LASTEXITCODE -ne 0) {
                    throw "curl failed with exit code $LASTEXITCODE"
                }
                Write-ScriptLog "  ✓ Download complete"
            }
            
            # Verify if checksum available
            if (-not $SkipVerify -and $iso.Checksum) {
                Write-ScriptLog "  Verifying checksum..."
                
                $algo = if ($iso.ChecksumAlgo) { $iso.ChecksumAlgo } else { 'SHA256' }
                $actualHash = (Get-FileHash -Path $destPath -Algorithm $algo).Hash
                
                if ($iso.Checksum -like 'http*') {
                    # Download checksum file
                    $checksumContent = Invoke-RestMethod -Uri $iso.Checksum
                    $expectedHash = ($checksumContent -split "`n" | Where-Object { $_ -like "*$($iso.FileName)*" } | 
                                    Select-Object -First 1) -replace '.*([A-Fa-f0-9]{64}).*', '$1'
                } else {
                    $expectedHash = $iso.Checksum
                }
                
                if ($expectedHash -and ($actualHash -eq $expectedHash)) {
                    Write-ScriptLog "  ✓ Checksum verified ($algo)"
                } elseif ($expectedHash) {
                    Write-ScriptLog "  ⚠ Checksum mismatch!" -Level 'Warning'
                    Write-ScriptLog "    Expected: $expectedHash"
                    Write-ScriptLog "    Actual:   $actualHash"
                } else {
                    Write-ScriptLog "  ⚠ Could not parse checksum file" -Level 'Warning'
                }
            }
            
        } catch {
            Write-ScriptLog "  ✗ Download failed: $_" -Level 'Error'
            continue
        }
        
        Write-ScriptLog ""
    }
    
    # Summary
    Write-ScriptLog "╔══════════════════════════════════════════════════════════════╗"
    Write-ScriptLog "║                    ISO Download Complete                      ║"
    Write-ScriptLog "╚══════════════════════════════════════════════════════════════╝"
    Write-ScriptLog ""
    Write-ScriptLog "Downloaded ISOs are in: $Destination"
    Write-ScriptLog ""
    Write-ScriptLog "Next steps:"
    Write-ScriptLog "  1. Customize: ./0195_Inject-ISO-Artifacts.ps1 -IsoPath <iso> -Platform <os>"
    Write-ScriptLog "  2. Deploy:    Use customized ISO in Hyper-V or tofu-base-lab"
    Write-ScriptLog ""
    
    exit 0

} catch {
    Write-ScriptLog "Download failed: $_" -Level 'Error'
    exit 1
}
