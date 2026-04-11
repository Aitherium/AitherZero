#Requires -Version 7.0
<#
.SYNOPSIS
    Downloads and installs Sysinternals Suite tools.
.DESCRIPTION
    Downloads the complete Sysinternals Suite from Microsoft and extracts it
    to a system-accessible location. Adds to PATH for easy access.
    
    Key tools included:
    - PsExec: Remote/elevated command execution
    - Process Explorer: Advanced task manager
    - Process Monitor: Real-time process monitoring
    - Autoruns: Startup program management
    - TCPView: Network connection viewer
    - And many more...

.PARAMETER InstallPath
    Where to install Sysinternals (default: C:\Sysinternals)

.PARAMETER AddToPath
    Add installation directory to system PATH (default: true)

.PARAMETER AcceptEula
    Pre-accept the Sysinternals EULA (default: true for automation)

.EXAMPLE
    .\0012_Install-Sysinternals.ps1
    
.EXAMPLE
    .\0012_Install-Sysinternals.ps1 -InstallPath "D:\Tools\Sysinternals"
#>
[CmdletBinding()]
param(
    [string]$InstallPath = "C:\Sysinternals",
    [switch]$AddToPath = $true,
    [switch]$AcceptEula = $true
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "+===============================================+" -ForegroundColor Cyan
Write-Host "|        Sysinternals Suite Installer          |" -ForegroundColor Cyan
Write-Host "+===============================================+" -ForegroundColor Cyan
Write-Host ""

# Check if already installed
$psexec = Get-Command PsExec64.exe -ErrorAction SilentlyContinue
if ($psexec) {
    Write-Host "[OK] Sysinternals already installed: $($psexec.Source)" -ForegroundColor Green
    
    # Still set EULA acceptance if requested
    if ($AcceptEula) {
        reg add "HKCU\Software\Sysinternals" /v EulaAccepted /t REG_DWORD /d 1 /f 2>$null | Out-Null
        reg add "HKCU\Software\Sysinternals\PsExec" /v EulaAccepted /t REG_DWORD /d 1 /f 2>$null | Out-Null
    }
    return @{ Success = $true; Path = (Split-Path $psexec.Source -Parent) }
}

# Download URL
$downloadUrl = "https://download.sysinternals.com/files/SysinternalsSuite.zip"
$zipPath = "$env:TEMP\SysinternalsSuite.zip"

Write-Host "[*] Install path: $InstallPath" -ForegroundColor Gray
Write-Host "[*] Downloading Sysinternals Suite..." -ForegroundColor Cyan

try {
    # Download
    $ProgressPreference = 'SilentlyContinue'  # Speed up download
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    $ProgressPreference = 'Continue'
    
    Write-Host "[OK] Downloaded: $([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB" -ForegroundColor Green
    
    # Create install directory
    if (-not (Test-Path $InstallPath)) {
        New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
        Write-Host "[OK] Created directory: $InstallPath" -ForegroundColor Green
    }
    
    # Extract
    Write-Host "[*] Extracting..." -ForegroundColor Cyan
    Expand-Archive -Path $zipPath -DestinationPath $InstallPath -Force
    Write-Host "[OK] Extracted to: $InstallPath" -ForegroundColor Green
    
    # Cleanup zip
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    
    # Add to PATH if requested
    if ($AddToPath) {
        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($currentPath -notlike "*$InstallPath*") {
            Write-Host "[*] Adding to system PATH..." -ForegroundColor Cyan
            
            # Try machine-level first (needs admin)
            try {
                [Environment]::SetEnvironmentVariable("Path", "$currentPath;$InstallPath", "Machine")
                Write-Host "[OK] Added to system PATH" -ForegroundColor Green
            } catch {
                # Fall back to user PATH
                $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPath -notlike "*$InstallPath*") {
                    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallPath", "User")
                    Write-Host "[OK] Added to user PATH" -ForegroundColor Green
                }
            }
            
            # Update current session
            $env:Path = "$env:Path;$InstallPath"
        } else {
            Write-Host "[OK] Already in PATH" -ForegroundColor Green
        }
    }
    
    # Accept EULA via registry
    if ($AcceptEula) {
        Write-Host "[*] Accepting Sysinternals EULA..." -ForegroundColor Cyan
        
        # Global acceptance
        reg add "HKCU\Software\Sysinternals" /v EulaAccepted /t REG_DWORD /d 1 /f 2>$null | Out-Null
        
        # Per-tool acceptance for common tools
        @('PsExec', 'PsExec64', 'ProcessMonitor', 'Procmon', 'Procmon64', 
          'ProcessExplorer', 'Procexp', 'Procexp64', 'Autoruns', 'Autoruns64',
          'TCPView', 'TCPView64', 'Handle', 'Handle64', 'ListDLLs', 'ListDLLs64') | ForEach-Object {
            reg add "HKCU\Software\Sysinternals\$_" /v EulaAccepted /t REG_DWORD /d 1 /f 2>$null | Out-Null
        }
        
        Write-Host "[OK] EULA accepted for all tools" -ForegroundColor Green
    }
    
    # Verify installation
    $psexec64 = Join-Path $InstallPath "PsExec64.exe"
    if (Test-Path $psexec64) {
        Write-Host ""
        Write-Host "[OK] Sysinternals Suite installed successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "Key tools available:" -ForegroundColor Cyan
        Write-Host "  PsExec64.exe  - Run processes remotely/elevated" -ForegroundColor Gray
        Write-Host "  procexp64.exe - Process Explorer" -ForegroundColor Gray
        Write-Host "  procmon64.exe - Process Monitor" -ForegroundColor Gray
        Write-Host "  autoruns64.exe - Startup manager" -ForegroundColor Gray
        Write-Host "  tcpview64.exe - Network connections" -ForegroundColor Gray
        Write-Host ""
        
        return @{ 
            Success = $true
            Path = $InstallPath
            PsExec = $psexec64
        }
    } else {
        throw "PsExec64.exe not found after extraction"
    }
    
} catch {
    Write-Host "[X] Failed to install Sysinternals: $_" -ForegroundColor Red
    return @{ Success = $false; Error = $_.ToString() }
} finally {
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}
