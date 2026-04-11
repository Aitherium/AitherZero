#Requires -Version 7.0
<#
.SYNOPSIS
    Validates all prerequisites for AitherOS installation.

.DESCRIPTION
    Checks system requirements including:
    - Operating system compatibility (Windows 10+, Linux, macOS)
    - Available disk space (minimum 50GB recommended)
    - Available RAM (minimum 16GB recommended, 32GB+ for full setup)
    - CPU cores (minimum 4, recommended 8+)
    - GPU availability for AI workloads
    - Required software (Git, Docker/Podman)
    - Network connectivity

.PARAMETER MinDiskSpaceGB
    Minimum required disk space in GB. Default: 50

.PARAMETER MinMemoryGB
    Minimum required RAM in GB. Default: 16

.PARAMETER MinCPUCores
    Minimum required CPU cores. Default: 4

.PARAMETER RequireGPU
    Whether to require a GPU. Default: $false

.PARAMETER SkipNetworkCheck
    Skip network connectivity check. Default: $false

.EXAMPLE
    .\0001_Validate-Prerequisites.ps1 -Verbose
    
.EXAMPLE
    .\0001_Validate-Prerequisites.ps1 -MinMemoryGB 32 -RequireGPU

.NOTES
    Category: bootstrap
    Dependencies: None
    Platform: Windows, Linux, macOS
    Exit Codes:
        0 - All prerequisites met
        2 - Prerequisites not met (see output for details)
#>

[CmdletBinding()]
param(
    [int]$MinDiskSpaceGB = 50,
    [int]$MinMemoryGB = 16,
    [int]$MinCPUCores = 4,
    [switch]$RequireGPU,
    [switch]$SkipNetworkCheck
)

$ErrorActionPreference = 'Stop'

# Import shared utilities if available
$initPath = Join-Path (Split-Path $PSScriptRoot -Parent) '_init.ps1'
if (Test-Path $initPath) {
    . $initPath
}

function Write-CheckResult {
    param(
        [string]$Check,
        [bool]$Passed,
        [string]$Details = ""
    )
    
    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "$status " -ForegroundColor $color -NoNewline
    Write-Host "$Check" -NoNewline
    if ($Details) {
        Write-Host " - $Details" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
    
    return $Passed
}

function Get-OSInfo {
    $os = @{
        Platform = ""
        Version = ""
        Is64Bit = [Environment]::Is64BitOperatingSystem
    }
    
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $os.Platform = "Windows"
        $winVer = [System.Environment]::OSVersion.Version
        $os.Version = "$($winVer.Major).$($winVer.Minor).$($winVer.Build)"
    }
    elseif ($IsLinux) {
        $os.Platform = "Linux"
        if (Test-Path /etc/os-release) {
            $osRelease = Get-Content /etc/os-release | ConvertFrom-StringData
            $os.Version = $osRelease.PRETTY_NAME -replace '"', ''
        }
    }
    elseif ($IsMacOS) {
        $os.Platform = "macOS"
        $os.Version = (sw_vers -productVersion 2>$null) ?? "Unknown"
    }
    
    return $os
}

function Test-DockerAvailable {
    try {
        $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
        if ($dockerVersion) {
            return @{ Available = $true; Version = $dockerVersion; Engine = "Docker" }
        }
    } catch { }
    
    try {
        $podmanVersion = podman version --format '{{.Server.Version}}' 2>$null
        if ($podmanVersion) {
            return @{ Available = $true; Version = $podmanVersion; Engine = "Podman" }
        }
    } catch { }
    
    return @{ Available = $false; Version = $null; Engine = $null }
}

function Test-GitAvailable {
    try {
        $gitVersion = git --version 2>$null
        if ($gitVersion -match 'git version (.+)') {
            return @{ Available = $true; Version = $Matches[1] }
        }
    } catch { }
    
    return @{ Available = $false; Version = $null }
}

function Get-SystemResources {
    $resources = @{
        CPUCores = 0
        MemoryGB = 0
        DiskFreeGB = 0
        GPUAvailable = $false
        GPUName = ""
    }
    
    # CPU Cores
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $resources.CPUCores = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors
        $resources.MemoryGB = [math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $resources.DiskFreeGB = [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
        
        # Check for GPU
        $gpus = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft|Basic' }
        if ($gpus) {
            $resources.GPUAvailable = $true
            $resources.GPUName = ($gpus | Select-Object -First 1).Name
        }
    }
    elseif ($IsLinux) {
        $resources.CPUCores = [int](nproc 2>$null) 
        $memInfo = Get-Content /proc/meminfo | Where-Object { $_ -match '^MemTotal' }
        if ($memInfo -match '(\d+)') {
            $resources.MemoryGB = [math]::Round([int64]$Matches[1] / 1024 / 1024, 1)
        }
        $dfOutput = df -BG / | Select-Object -Skip 1
        if ($dfOutput -match '(\d+)G') {
            $resources.DiskFreeGB = [int]$Matches[1]
        }
        
        # Check for NVIDIA GPU
        if (Test-Path /usr/bin/nvidia-smi) {
            try {
                $gpuName = nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
                if ($gpuName) {
                    $resources.GPUAvailable = $true
                    $resources.GPUName = $gpuName.Trim()
                }
            } catch { }
        }
    }
    elseif ($IsMacOS) {
        $resources.CPUCores = [int](sysctl -n hw.logicalcpu 2>$null)
        $memBytes = [int64](sysctl -n hw.memsize 2>$null)
        $resources.MemoryGB = [math]::Round($memBytes / 1GB, 1)
        $dfOutput = df -g / | Select-Object -Skip 1
        if ($dfOutput -match '(\d+)') {
            $resources.DiskFreeGB = [int]$Matches[1]
        }
        
        # Check for Apple Silicon (GPU integrated)
        $chipInfo = sysctl -n machdep.cpu.brand_string 2>$null
        if ($chipInfo -match 'Apple') {
            $resources.GPUAvailable = $true
            $resources.GPUName = "Apple Silicon (integrated)"
        }
    }
    
    return $resources
}

function Test-NetworkConnectivity {
    param([string[]]$Hosts = @("github.com", "hub.docker.com", "huggingface.co"))
    
    $results = @()
    foreach ($host in $Hosts) {
        try {
            $response = Test-Connection -TargetName $host -Count 1 -Quiet -TimeoutSeconds 5
            $results += @{ Host = $host; Reachable = $response }
        } catch {
            $results += @{ Host = $host; Reachable = $false }
        }
    }
    
    return $results
}

# ============================================================================
# MAIN VALIDATION
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Prerequisites Validation" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

$allPassed = $true

# 1. Operating System
Write-Host "Operating System" -ForegroundColor Yellow
Write-Host "-" * 40

$osInfo = Get-OSInfo
$osSupported = $osInfo.Platform -in @("Windows", "Linux", "macOS") -and $osInfo.Is64Bit

$result = Write-CheckResult -Check "Platform: $($osInfo.Platform)" -Passed $osSupported -Details $osInfo.Version
$allPassed = $allPassed -and $result

$result = Write-CheckResult -Check "64-bit OS" -Passed $osInfo.Is64Bit
$allPassed = $allPassed -and $result

Write-Host ""

# 2. System Resources
Write-Host "System Resources" -ForegroundColor Yellow
Write-Host "-" * 40

$resources = Get-SystemResources

$cpuPassed = $resources.CPUCores -ge $MinCPUCores
$result = Write-CheckResult -Check "CPU Cores (min: $MinCPUCores)" -Passed $cpuPassed -Details "$($resources.CPUCores) cores"
$allPassed = $allPassed -and $result

$memPassed = $resources.MemoryGB -ge $MinMemoryGB
$result = Write-CheckResult -Check "Memory (min: ${MinMemoryGB}GB)" -Passed $memPassed -Details "$($resources.MemoryGB) GB"
$allPassed = $allPassed -and $result

$diskPassed = $resources.DiskFreeGB -ge $MinDiskSpaceGB
$result = Write-CheckResult -Check "Disk Space (min: ${MinDiskSpaceGB}GB)" -Passed $diskPassed -Details "$($resources.DiskFreeGB) GB free"
$allPassed = $allPassed -and $result

if ($RequireGPU) {
    $gpuPassed = $resources.GPUAvailable
    $gpuDetails = if ($resources.GPUAvailable) { $resources.GPUName } else { "Not detected" }
    $result = Write-CheckResult -Check "GPU Available" -Passed $gpuPassed -Details $gpuDetails
    $allPassed = $allPassed -and $result
} else {
    $gpuDetails = if ($resources.GPUAvailable) { $resources.GPUName } else { "Not detected (optional)" }
    Write-CheckResult -Check "GPU Available (optional)" -Passed $true -Details $gpuDetails | Out-Null
}

Write-Host ""

# 3. Required Software
Write-Host "Required Software" -ForegroundColor Yellow
Write-Host "-" * 40

$git = Test-GitAvailable
$result = Write-CheckResult -Check "Git" -Passed $git.Available -Details $(if ($git.Available) { "v$($git.Version)" } else { "Not installed" })
$allPassed = $allPassed -and $result

$docker = Test-DockerAvailable
$result = Write-CheckResult -Check "Container Runtime" -Passed $docker.Available -Details $(if ($docker.Available) { "$($docker.Engine) v$($docker.Version)" } else { "Docker/Podman not found" })
$allPassed = $allPassed -and $result

# Check PowerShell version
$psPassed = $PSVersionTable.PSVersion.Major -ge 7
$result = Write-CheckResult -Check "PowerShell 7+" -Passed $psPassed -Details "v$($PSVersionTable.PSVersion)"
$allPassed = $allPassed -and $result

Write-Host ""

# 4. Network Connectivity
if (-not $SkipNetworkCheck) {
    Write-Host "Network Connectivity" -ForegroundColor Yellow
    Write-Host "-" * 40
    
    $networkResults = Test-NetworkConnectivity
    foreach ($net in $networkResults) {
        $result = Write-CheckResult -Check $net.Host -Passed $net.Reachable
        # Network failures are warnings, not blockers
    }
    
    Write-Host ""
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host "=" * 60 -ForegroundColor Cyan

if ($allPassed) {
    Write-Host "`n  All prerequisites met! Ready for AitherOS installation.`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n  Some prerequisites not met. Please resolve the issues above.`n" -ForegroundColor Red
    
    # Provide remediation hints
    Write-Host "Remediation Steps:" -ForegroundColor Yellow
    
    if (-not $git.Available) {
        Write-Host "  - Install Git: https://git-scm.com/downloads" -ForegroundColor Gray
    }
    
    if (-not $docker.Available) {
        if ($osInfo.Platform -eq "Windows") {
            Write-Host "  - Install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Gray
        } elseif ($osInfo.Platform -eq "Linux") {
            Write-Host "  - Install Docker: curl -fsSL https://get.docker.com | sh" -ForegroundColor Gray
        } elseif ($osInfo.Platform -eq "macOS") {
            Write-Host "  - Install Docker Desktop: https://www.docker.com/products/docker-desktop/" -ForegroundColor Gray
        }
    }
    
    if (-not $memPassed) {
        Write-Host "  - Consider upgrading RAM to at least ${MinMemoryGB}GB" -ForegroundColor Gray
    }
    
    if (-not $diskPassed) {
        Write-Host "  - Free up disk space or use a larger drive" -ForegroundColor Gray
    }
    
    Write-Host ""
    exit 2
}
