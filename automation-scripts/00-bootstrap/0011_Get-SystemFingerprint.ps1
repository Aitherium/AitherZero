#Requires -Version 7.0

<#
.SYNOPSIS
    Gather a comprehensive system fingerprint — hardware, OS, apps, processes, disks, network, GPU, Docker, and more.
.DESCRIPTION
    Enumerates every meaningful dimension of the host machine and returns a structured
    JSON fingerprint that can be ingested by AI agents, MCP tools, and CodeGraph/Neurons.

    The fingerprint includes:
      - Hardware: CPU, RAM, GPU, motherboard, BIOS
      - OS: Edition, build, install date, uptime, locale, timezone
      - Disks: Volumes, partitions, usage, health
      - Network: Adapters, IPs, DNS, routes, firewall profile
      - Processes: Running processes with memory/CPU
      - Applications: Installed software (winget/system)
      - Services: Running Windows services
      - Docker: Containers, images, compose projects
      - Environment: PATH, env vars, PowerShell modules
      - File system summary: Workspace tree, file counts by extension
      - Security: Defender status, firewall, BitLocker

    Exit Codes:
      0 - Success
      1 - Partial failure (some sections failed)
      2 - Critical failure

.PARAMETER Sections
    Comma-separated list of sections to collect. Default: All.
    Valid: Hardware, OS, Disks, Network, Processes, Applications, Services,
           Docker, Environment, FileSystem, Security, GPU, Summary
.PARAMETER OutputFormat
    Output format: Json (default), Summary, Markdown
.PARAMETER OutputPath
    Write fingerprint to this file path (in addition to stdout)
.PARAMETER Quick
    Skip slow sections (Applications, full FileSystem scan) for faster results
.PARAMETER AsJson
    Alias for -OutputFormat Json (backward compat with 0011)
.NOTES
    Stage: Environment
    Order: 0011
    Dependencies: None
    Tags: system, fingerprint, hardware, inventory, diagnostics
    AllowParallel: true
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$Sections,

    [Parameter()]
    [ValidateSet('Json', 'Summary', 'Markdown')]
    [string]$OutputFormat = 'Json',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$Quick,

    [Parameter()]
    [switch]$AsJson
)

# Source common init
. "$PSScriptRoot/../_init.ps1"

$ErrorActionPreference = 'Continue'  # Don't fail on individual section errors
Set-StrictMode -Version Latest

if ($AsJson) { $OutputFormat = 'Json' }

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Safe-Invoke {
    <#
    .SYNOPSIS
        Run a scriptblock, return $null on failure instead of throwing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([scriptblock]$Block, [string]$Label = 'unknown')
    try { & $Block }
    catch {
        Write-Warning "[Fingerprint] Section '$Label' failed: $_"
        $null
    }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    return "{0:N2} KB" -f ($Bytes / 1KB)
}

# ─── Section Defaults ────────────────────────────────────────────────────────

$allSections = @(
    'Hardware', 'OS', 'Disks', 'Network', 'Processes', 'Applications',
    'Services', 'Docker', 'Environment', 'FileSystem', 'Security', 'GPU'
)

if (-not $Sections -or $Sections.Count -eq 0) {
    if ($Quick) {
        $Sections = @('Hardware', 'OS', 'Disks', 'Network', 'Processes', 'Services', 'Docker', 'Environment', 'GPU')
    } else {
        $Sections = $allSections
    }
}

# ─── Master fingerprint object ───────────────────────────────────────────────

$fingerprint = [ordered]@{
    _meta = [ordered]@{
        GeneratedAt  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')
        GeneratedBy  = 'AitherZero/0011_Get-SystemFingerprint'
        Version      = '2.0.0'
        MachineName  = [System.Environment]::MachineName
        Sections     = $Sections
        Quick        = [bool]$Quick
    }
}

$sectionErrors = @()

# ─── HARDWARE ─────────────────────────────────────────────────────────────────

if ('Hardware' -in $Sections) {
    $fingerprint.Hardware = Safe-Invoke -Label 'Hardware' {
        $hw = [ordered]@{
            ProcessorCount = [System.Environment]::ProcessorCount
            Is64Bit        = [System.Environment]::Is64BitOperatingSystem
        }

        if ($IsWindows) {
            $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cpu) {
                $hw.CPU = [ordered]@{
                    Name             = $cpu.Name.Trim()
                    Manufacturer     = $cpu.Manufacturer
                    Cores            = $cpu.NumberOfCores
                    LogicalProcessors = $cpu.NumberOfLogicalProcessors
                    MaxClockMHz      = $cpu.MaxClockSpeed
                    Architecture     = switch ($cpu.Architecture) { 0 {'x86'} 5 {'ARM'} 9 {'x64'} 12 {'ARM64'} default {"$($cpu.Architecture)"} }
                    L2CacheKB        = $cpu.L2CacheSize
                    L3CacheKB        = $cpu.L3CacheSize
                }
            }

            $mb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($mb) {
                $hw.Motherboard = [ordered]@{
                    Manufacturer = $mb.Manufacturer
                    Product      = $mb.Product
                    SerialNumber = $mb.SerialNumber
                }
            }

            $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($bios) {
                $hw.BIOS = [ordered]@{
                    Manufacturer = $bios.Manufacturer
                    Version      = $bios.SMBIOSBIOSVersion
                    ReleaseDate  = $bios.ReleaseDate
                }
            }

            $mem = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
            if ($mem) {
                $hw.RAM = [ordered]@{
                    TotalGB = [Math]::Round(($mem | Measure-Object -Property Capacity -Sum).Sum / 1GB, 2)
                    Sticks  = @($mem | ForEach-Object {
                        [ordered]@{
                            SizeGB       = [Math]::Round($_.Capacity / 1GB, 2)
                            Speed        = $_.ConfiguredClockSpeed
                            Manufacturer = $_.Manufacturer
                            PartNumber   = ($_.PartNumber -replace '\s+', ' ').Trim()
                        }
                    })
                }
            }
        } elseif ($IsLinux) {
            if (Test-Path '/proc/cpuinfo') {
                $cpuModel = Get-Content '/proc/cpuinfo' | Select-String 'model name' | Select-Object -First 1
                if ($cpuModel) { $hw.CPUName = ($cpuModel -replace 'model name\s*:\s*', '').Trim() }
            }
            if (Test-Path '/proc/meminfo') {
                $memLine = Get-Content '/proc/meminfo' | Select-String 'MemTotal:' | ForEach-Object { $_ -replace '[^0-9]', '' }
                if ($memLine) { $hw.TotalRAM_GB = [Math]::Round([long]$memLine / 1024 / 1024, 2) }
            }
        } elseif ($IsMacOS) {
            $hw.CPUName = (& sysctl -n machdep.cpu.brand_string 2>$null)
            $memSize = & sysctl -n hw.memsize 2>$null
            if ($memSize) { $hw.TotalRAM_GB = [Math]::Round([long]$memSize / 1GB, 2) }
        }

        $hw
    }
}

# ─── OPERATING SYSTEM ────────────────────────────────────────────────────────

if ('OS' -in $Sections) {
    $fingerprint.OS = Safe-Invoke -Label 'OS' {
        $os = [ordered]@{
            Platform           = if ($IsWindows) { 'Windows' } elseif ($IsLinux) { 'Linux' } elseif ($IsMacOS) { 'macOS' } else { 'Unknown' }
            Version            = [System.Environment]::OSVersion.VersionString
            PowerShellVersion  = $PSVersionTable.PSVersion.ToString()
            PowerShellEdition  = $PSVersionTable.PSEdition
            DotNetVersion      = [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
            ProcessArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        }

        if ($IsWindows) {
            $winOS = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($winOS) {
                $os.Edition      = $winOS.Caption
                $os.Build        = $winOS.BuildNumber
                $os.InstallDate  = $winOS.InstallDate.ToString('yyyy-MM-dd')
                $os.LastBoot     = $winOS.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:ss')
                $os.Uptime       = ((Get-Date) - $winOS.LastBootUpTime).ToString('d\.hh\:mm\:ss')
                $os.RegisteredUser = $winOS.RegisteredUser
            }

            $os.Locale   = (Get-Culture).Name
            $os.TimeZone = (Get-TimeZone).DisplayName
            $os.SystemDrive = $env:SystemDrive
            $os.WindowsDir  = $env:windir

            # Windows Update build info
            try {
                $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
                $displayVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
                if ($ubr) { $os.BuildRevision = $ubr }
                if ($displayVersion) { $os.DisplayVersion = $displayVersion }
            } catch {}
        } elseif ($IsLinux -and (Test-Path '/etc/os-release')) {
            $osRelease = Get-Content '/etc/os-release' -ErrorAction SilentlyContinue
            $os.Distribution = ($osRelease | Select-String 'PRETTY_NAME=' | ForEach-Object { $_ -replace 'PRETTY_NAME=|"', '' })
        } elseif ($IsMacOS) {
            $os.ProductVersion = & sw_vers -productVersion 2>$null
        }

        $os
    }
}

# ─── GPU ──────────────────────────────────────────────────────────────────────

if ('GPU' -in $Sections) {
    $fingerprint.GPU = Safe-Invoke -Label 'GPU' {
        $gpus = @()

        if ($IsWindows) {
            $videoCards = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            foreach ($vc in $videoCards) {
                $gpus += [ordered]@{
                    Name         = $vc.Name
                    Driver       = $vc.DriverVersion
                    VRAM_MB      = [Math]::Round($vc.AdapterRAM / 1MB, 0)
                    Status       = $vc.Status
                    Resolution   = "$($vc.CurrentHorizontalResolution)x$($vc.CurrentVerticalResolution)"
                    RefreshRate  = $vc.CurrentRefreshRate
                }
            }

            # NVIDIA-specific
            $nvSmi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
            if ($nvSmi) {
                try {
                    $nvInfo = & nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,driver_version,compute_cap --format=csv,noheader,nounits 2>$null
                    if ($nvInfo) {
                        $fields = ($nvInfo | Select-Object -First 1) -split ',\s*'
                        if ($fields.Count -ge 4) {
                            $gpus[0].NVIDIA = [ordered]@{
                                VRAM_Total_MB  = [int]$fields[1]
                                VRAM_Used_MB   = [int]$fields[2]
                                Temperature_C  = [int]$fields[3]
                                DriverVersion  = if ($fields.Count -ge 5) { $fields[4] } else { $null }
                                ComputeCapability = if ($fields.Count -ge 6) { $fields[5] } else { $null }
                            }
                        }
                    }

                    # CUDA version
                    $cudaVer = & nvidia-smi --query 2>$null | Select-String 'CUDA Version'
                    if ($cudaVer) { $gpus[0].NVIDIA.CUDAVersion = ($cudaVer -replace '.*CUDA Version:\s*', '').Trim() }
                } catch {}
            }
        } elseif ($IsLinux) {
            $lspci = & lspci 2>$null | Select-String 'VGA|3D|Display'
            if ($lspci) { $gpus += @{ Devices = @($lspci | ForEach-Object { $_.ToString().Trim() }) } }
        }

        $gpus
    }
}

# ─── DISKS ────────────────────────────────────────────────────────────────────

if ('Disks' -in $Sections) {
    $fingerprint.Disks = Safe-Invoke -Label 'Disks' {
        $disks = [ordered]@{}

        # Logical volumes
        $disks.Volumes = @(
            [System.IO.DriveInfo]::GetDrives() |
                Where-Object { $_.IsReady } |
                ForEach-Object {
                    [ordered]@{
                        Name        = $_.Name
                        Label       = $_.VolumeLabel
                        Type        = $_.DriveType.ToString()
                        Format      = $_.DriveFormat
                        TotalGB     = [Math]::Round($_.TotalSize / 1GB, 2)
                        FreeGB      = [Math]::Round($_.AvailableFreeSpace / 1GB, 2)
                        UsedGB      = [Math]::Round(($_.TotalSize - $_.AvailableFreeSpace) / 1GB, 2)
                        UsedPercent = [Math]::Round((($_.TotalSize - $_.AvailableFreeSpace) / $_.TotalSize) * 100, 1)
                    }
                }
        )

        # Physical disks (Windows)
        if ($IsWindows) {
            $physDisks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
            if ($physDisks) {
                $disks.Physical = @($physDisks | ForEach-Object {
                    [ordered]@{
                        Model       = $_.Model
                        MediaType   = $_.MediaType
                        Interface   = $_.InterfaceType
                        SizeGB      = [Math]::Round($_.Size / 1GB, 2)
                        Partitions  = $_.Partitions
                        SerialNumber = $_.SerialNumber
                    }
                })
            }
        }

        $disks
    }
}

# ─── NETWORK ─────────────────────────────────────────────────────────────────

if ('Network' -in $Sections) {
    $fingerprint.Network = Safe-Invoke -Label 'Network' {
        $net = [ordered]@{}

        # Hostname + domain
        $net.Hostname = [System.Net.Dns]::GetHostName()
        try { $net.FQDN = [System.Net.Dns]::GetHostEntry('').HostName } catch {}

        # Adapters via .NET (cross-platform)
        $net.Adapters = @(
            [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
                ForEach-Object {
                    $props = $_.GetIPProperties()
                    [ordered]@{
                        Name       = $_.Name
                        Type       = $_.NetworkInterfaceType.ToString()
                        Speed_Mbps = [Math]::Round($_.Speed / 1000000, 0)
                        MAC        = $_.GetPhysicalAddress().ToString() -replace '(..)(?=.)', '$1:'
                        IPv4       = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
                        IPv6       = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetworkV6' } | ForEach-Object { $_.Address.ToString() })
                        Gateway    = @($props.GatewayAddresses | ForEach-Object { $_.Address.ToString() })
                        DNS        = @($props.DnsAddresses | ForEach-Object { $_.ToString() })
                    }
                }
        )

        # Firewall profile (Windows)
        if ($IsWindows) {
            try {
                $fwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
                if ($fwProfiles) {
                    $net.Firewall = @($fwProfiles | ForEach-Object {
                        [ordered]@{ Profile = $_.Name; Enabled = $_.Enabled }
                    })
                }
            } catch {}
        }

        # External IP (optional, quick HTTP call)
        try {
            $extIP = Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 3 -ErrorAction SilentlyContinue
            if ($extIP.ip) { $net.ExternalIP = $extIP.ip }
        } catch {}

        $net
    }
}

# ─── PROCESSES ────────────────────────────────────────────────────────────────

if ('Processes' -in $Sections) {
    $fingerprint.Processes = Safe-Invoke -Label 'Processes' {
        $procs = [ordered]@{}
        $allProcs = Get-Process -ErrorAction SilentlyContinue

        $procs.TotalCount = $allProcs.Count

        # Top 25 by memory
        $procs.TopByMemory = @(
            $allProcs |
                Sort-Object WorkingSet64 -Descending |
                Select-Object -First 25 |
                ForEach-Object {
                    [ordered]@{
                        Name     = $_.ProcessName
                        PID      = $_.Id
                        Memory   = Format-Bytes $_.WorkingSet64
                        MemoryMB = [Math]::Round($_.WorkingSet64 / 1MB, 1)
                        CPU_s    = [Math]::Round($_.CPU, 1)
                        Threads  = $_.Threads.Count
                    }
                }
        )

        # Summary by process name (grouped)
        $procs.GroupedSummary = @(
            $allProcs |
                Group-Object ProcessName |
                Sort-Object { ($_.Group | Measure-Object WorkingSet64 -Sum).Sum } -Descending |
                Select-Object -First 30 |
                ForEach-Object {
                    [ordered]@{
                        Name       = $_.Name
                        Instances  = $_.Count
                        TotalMemMB = [Math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
                    }
                }
        )

        $procs
    }
}

# ─── APPLICATIONS ─────────────────────────────────────────────────────────────

if ('Applications' -in $Sections) {
    $fingerprint.Applications = Safe-Invoke -Label 'Applications' {
        $apps = [ordered]@{}

        # Winget-based listing (fast, modern)
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            try {
                $wingetList = & winget list --accept-source-agreements 2>$null |
                    Select-Object -Skip 2 |
                    Where-Object { $_ -match '\S' } |
                    Select-Object -First 200
                $apps.WingetCount = $wingetList.Count
                $apps.WingetApps = @($wingetList | ForEach-Object { $_.Trim() })
            } catch {}
        }

        # Registry-based (Windows, more complete)
        if ($IsWindows -and -not $Quick) {
            $regPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $regApps = foreach ($rp in $regPaths) {
                Get-ItemProperty $rp -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName } |
                    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
                    ForEach-Object {
                        [ordered]@{
                            Name      = $_.DisplayName
                            Version   = $_.DisplayVersion
                            Publisher = $_.Publisher
                        }
                    }
            }
            $apps.InstalledCount = ($regApps | Select-Object -ExpandProperty Name -Unique).Count
            $apps.Installed = @($regApps | Sort-Object { $_.Name } -Unique | Select-Object -First 300)
        }

        # Key dev tools
        $devTools = @(
            @{ Name = 'git';    Cmd = 'git --version' },
            @{ Name = 'node';   Cmd = 'node --version' },
            @{ Name = 'npm';    Cmd = 'npm --version' },
            @{ Name = 'python'; Cmd = 'python --version' },
            @{ Name = 'docker'; Cmd = 'docker --version' },
            @{ Name = 'pwsh';   Cmd = 'pwsh --version' },
            @{ Name = 'dotnet'; Cmd = 'dotnet --version' },
            @{ Name = 'go';     Cmd = 'go version' },
            @{ Name = 'rustc';  Cmd = 'rustc --version' },
            @{ Name = 'java';   Cmd = 'java -version 2>&1' },
            @{ Name = 'code';   Cmd = 'code --version' },
            @{ Name = 'ollama'; Cmd = 'ollama --version' },
            @{ Name = 'kubectl'; Cmd = 'kubectl version --client --short 2>$null' },
            @{ Name = 'helm';   Cmd = 'helm version --short 2>$null' },
            @{ Name = 'terraform'; Cmd = 'terraform --version 2>$null' }
        )
        $apps.DevTools = [ordered]@{}
        foreach ($tool in $devTools) {
            if (Get-Command $tool.Name -ErrorAction SilentlyContinue) {
                try {
                    $ver = Invoke-Expression $tool.Cmd 2>$null | Select-Object -First 1
                    $apps.DevTools[$tool.Name] = $ver?.Trim()
                } catch {
                    $apps.DevTools[$tool.Name] = 'installed (version unknown)'
                }
            }
        }

        $apps
    }
}

# ─── SERVICES ─────────────────────────────────────────────────────────────────

if ('Services' -in $Sections) {
    $fingerprint.Services = Safe-Invoke -Label 'Services' {
        $svcs = [ordered]@{}

        if ($IsWindows) {
            $running = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }
            $svcs.RunningCount = $running.Count
            $svcs.Running = @($running | Sort-Object DisplayName | ForEach-Object {
                [ordered]@{
                    Name        = $_.Name
                    DisplayName = $_.DisplayName
                    StartType   = $_.StartType.ToString()
                }
            })

            # Key AitherOS services
            $aitherSvcs = $running | Where-Object { $_.Name -like '*aither*' -or $_.DisplayName -like '*aither*' }
            if ($aitherSvcs) {
                $svcs.AitherServices = @($aitherSvcs | ForEach-Object { $_.DisplayName })
            }
        } elseif ($IsLinux) {
            $systemd = & systemctl list-units --type=service --state=running --no-pager 2>$null
            if ($systemd) { $svcs.Running = @($systemd | Select-Object -First 100) }
        }

        $svcs
    }
}

# ─── DOCKER ───────────────────────────────────────────────────────────────────

if ('Docker' -in $Sections) {
    $fingerprint.Docker = Safe-Invoke -Label 'Docker' {
        $dk = [ordered]@{ Available = $false }

        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $dk.Available = $true
            try { $dk.Version = (& docker version --format '{{.Server.Version}}' 2>$null) } catch {}
            try { $dk.Platform = (& docker version --format '{{.Server.Platform.Name}}' 2>$null) } catch {}

            # Running containers
            try {
                $containers = & docker ps --format '{{json .}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($containers) {
                    $dk.RunningContainers = @($containers | ForEach-Object {
                        [ordered]@{
                            Name    = $_.Names
                            Image   = $_.Image
                            Status  = $_.Status
                            Ports   = $_.Ports
                            Created = $_.CreatedAt
                        }
                    })
                    $dk.ContainerCount = $dk.RunningContainers.Count
                } else {
                    $dk.ContainerCount = 0
                    $dk.RunningContainers = @()
                }
            } catch {
                $dk.ContainerCount = 0
            }

            # All containers (including stopped)
            try {
                $allContainers = & docker ps -a --format '{{json .}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                $dk.TotalContainers = if ($allContainers) { @($allContainers).Count } else { 0 }
            } catch {}

            # Images
            try {
                $images = & docker images --format '{{json .}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($images) {
                    $dk.Images = @($images | Select-Object -First 50 | ForEach-Object {
                        [ordered]@{
                            Repository = $_.Repository
                            Tag        = $_.Tag
                            Size       = $_.Size
                            Created    = $_.CreatedAt
                        }
                    })
                    $dk.ImageCount = @($images).Count
                }
            } catch {}

            # Docker disk usage
            try {
                $dfOutput = & docker system df --format '{{json .}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($dfOutput) {
                    $dk.DiskUsage = @($dfOutput | ForEach-Object {
                        [ordered]@{ Type = $_.Type; Total = $_.TotalCount; Size = $_.Size; Reclaimable = $_.Reclaimable }
                    })
                }
            } catch {}
        }

        $dk
    }
}

# ─── ENVIRONMENT ──────────────────────────────────────────────────────────────

if ('Environment' -in $Sections) {
    $fingerprint.Environment = Safe-Invoke -Label 'Environment' {
        $env_info = [ordered]@{}

        # Key env vars
        $env_info.PATH = ($env:PATH -split [IO.Path]::PathSeparator) | Select-Object -First 50
        $env_info.PSModulePath = ($env:PSModulePath -split [IO.Path]::PathSeparator)
        $env_info.TEMP = $env:TEMP
        $env_info.HOME = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
        $env_info.USER = if ($env:USER) { $env:USER } else { $env:USERNAME }
        $env_info.SHELL = $env:SHELL

        # AitherOS-specific vars
        $aitherVars = Get-ChildItem env: -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'AITHER*' -or $_.Name -like 'PROJECT_ROOT*' -or $_.Name -like 'GENESIS*' -or $_.Name -like 'OLLAMA*' }
        $env_info.AitherVars = [ordered]@{}
        foreach ($v in $aitherVars) { $env_info.AitherVars[$v.Name] = $v.Value }

        # PowerShell modules
        $env_info.LoadedModules = @(Get-Module | ForEach-Object { [ordered]@{ Name = $_.Name; Version = $_.Version.ToString() } })

        # Installed PowerShell modules (top-level)
        $env_info.InstalledModules = @(
            Get-Module -ListAvailable -ErrorAction SilentlyContinue |
                Select-Object Name, Version -Unique |
                Sort-Object Name |
                Select-Object -First 100 |
                ForEach-Object { [ordered]@{ Name = $_.Name; Version = $_.Version.ToString() } }
        )

        $env_info
    }
}

# ─── FILE SYSTEM ──────────────────────────────────────────────────────────────

if ('FileSystem' -in $Sections) {
    $fingerprint.FileSystem = Safe-Invoke -Label 'FileSystem' {
        $fs = [ordered]@{}

        # Workspace root
        $wsRoot = if ($projectRoot) { $projectRoot } else { Get-Location }
        $fs.WorkspaceRoot = $wsRoot.ToString()

        # Top-level directory listing
        $fs.TopLevel = @(
            Get-ChildItem $wsRoot -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [ordered]@{
                        Name   = $_.Name
                        Type   = if ($_.PSIsContainer) { 'Directory' } else { 'File' }
                        SizeKB = if (-not $_.PSIsContainer) { [Math]::Round($_.Length / 1KB, 1) } else { $null }
                    }
                }
        )

        # File extension breakdown (workspace)
        if (-not $Quick) {
            $allFiles = Get-ChildItem $wsRoot -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '(node_modules|\.git|__pycache__|\.venv|\.next|dist|_archive|cache)' }

            $fs.TotalFiles = $allFiles.Count
            $fs.TotalSizeMB = [Math]::Round(($allFiles | Measure-Object Length -Sum).Sum / 1MB, 2)
            $fs.ByExtension = @(
                $allFiles |
                    Group-Object Extension |
                    Sort-Object Count -Descending |
                    Select-Object -First 30 |
                    ForEach-Object {
                        [ordered]@{
                            Extension = if ($_.Name) { $_.Name } else { '(none)' }
                            Count     = $_.Count
                            TotalMB   = [Math]::Round(($_.Group | Measure-Object Length -Sum).Sum / 1MB, 2)
                        }
                    }
            )
        }

        $fs
    }
}

# ─── SECURITY ─────────────────────────────────────────────────────────────────

if ('Security' -in $Sections) {
    $fingerprint.Security = Safe-Invoke -Label 'Security' {
        $sec = [ordered]@{}

        if ($IsWindows) {
            # Windows Defender
            try {
                $defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue
                if ($defenderStatus) {
                    $sec.Defender = [ordered]@{
                        RealTimeProtection = $defenderStatus.RealTimeProtectionEnabled
                        AntivirusEnabled   = $defenderStatus.AntivirusEnabled
                        LastScanTime       = $defenderStatus.QuickScanEndTime?.ToString('yyyy-MM-dd HH:mm')
                        SignatureVersion   = $defenderStatus.AntivirusSignatureVersion
                        LastSignatureUpdate = $defenderStatus.AntivirusSignatureLastUpdated?.ToString('yyyy-MM-dd HH:mm')
                    }
                }
            } catch {}

            # BitLocker
            try {
                $bitlocker = Get-BitLockerVolume -ErrorAction SilentlyContinue
                if ($bitlocker) {
                    $sec.BitLocker = @($bitlocker | ForEach-Object {
                        [ordered]@{
                            MountPoint       = $_.MountPoint
                            ProtectionStatus = $_.ProtectionStatus.ToString()
                            EncryptionMethod = $_.EncryptionMethod.ToString()
                        }
                    })
                }
            } catch {}

            # UAC level
            try {
                $uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
                if ($uac) {
                    $sec.UAC = [ordered]@{
                        Enabled             = [bool]$uac.EnableLUA
                        ConsentPromptLevel  = $uac.ConsentPromptBehaviorAdmin
                    }
                }
            } catch {}

            # Is admin?
            $sec.IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        $sec
    }
}

# ─── ASSEMBLE OUTPUT ──────────────────────────────────────────────────────────

# Add summary if errors
if ($sectionErrors.Count -gt 0) {
    $fingerprint._meta.Errors = $sectionErrors
}

# Calculate a quick hash fingerprint for change detection
$jsonStr = $fingerprint | ConvertTo-Json -Depth 15 -Compress
$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($jsonStr))
$fingerprint._meta.FingerprintHash = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''

# Output
switch ($OutputFormat) {
    'Json' {
        $output = $fingerprint | ConvertTo-Json -Depth 15
        $output
    }
    'Summary' {
        Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║           AitherZero System Fingerprint                      ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

        if ($fingerprint.Contains('OS') -and $fingerprint.OS) {
            Write-Host "`n  OS: $($fingerprint.OS.Edition ?? $fingerprint.OS.Platform) ($($fingerprint.OS.Build ?? $fingerprint.OS.Version))" -ForegroundColor Green
            if ($fingerprint.OS.Uptime) { Write-Host "  Uptime: $($fingerprint.OS.Uptime)" -ForegroundColor White }
        }
        if ($fingerprint.Contains('Hardware') -and $fingerprint.Hardware) {
            Write-Host "  CPU: $($fingerprint.Hardware.CPU?.Name ?? $fingerprint.Hardware.CPUName ?? 'N/A') ($($fingerprint.Hardware.ProcessorCount) logical)" -ForegroundColor Green
            Write-Host "  RAM: $($fingerprint.Hardware.RAM?.TotalGB ?? $fingerprint.Hardware.TotalRAM_GB ?? 'N/A') GB" -ForegroundColor Green
        }
        if ($fingerprint.Contains('GPU') -and $fingerprint.GPU) {
            foreach ($g in $fingerprint.GPU) { Write-Host "  GPU: $($g.Name)" -ForegroundColor Green }
        }
        if ($fingerprint.Contains('Disks') -and $fingerprint.Disks?.Volumes) {
            foreach ($v in $fingerprint.Disks.Volumes) {
                $color = if ($v.UsedPercent -gt 90) { 'Red' } elseif ($v.UsedPercent -gt 80) { 'Yellow' } else { 'White' }
                Write-Host "  Disk $($v.Name): $($v.FreeGB)GB free / $($v.TotalGB)GB ($($v.UsedPercent)% used)" -ForegroundColor $color
            }
        }
        if ($fingerprint.Contains('Docker') -and $fingerprint.Docker?.Available) {
            Write-Host "  Docker: $($fingerprint.Docker.ContainerCount) running / $($fingerprint.Docker.TotalContainers) total containers" -ForegroundColor Cyan
        }
        if ($fingerprint.Contains('Processes') -and $fingerprint.Processes) {
            Write-Host "  Processes: $($fingerprint.Processes.TotalCount) running" -ForegroundColor White
        }
        Write-Host "  Hash: $($fingerprint._meta.FingerprintHash.Substring(0,16))..." -ForegroundColor DarkGray
        Write-Host ""
    }
    'Markdown' {
        $md = @()
        $md += "# System Fingerprint — $($fingerprint._meta.MachineName)"
        $md += "_Generated: $($fingerprint._meta.GeneratedAt)_"
        $md += ""
        $md += "## OS"
        if ($fingerprint.OS) {
            $fingerprint.OS.GetEnumerator() | ForEach-Object { $md += "- **$($_.Key):** $($_.Value)" }
        }
        $md += ""
        $md += "## Hardware"
        if ($fingerprint.Hardware?.CPU) {
            $md += "- **CPU:** $($fingerprint.Hardware.CPU.Name) ($($fingerprint.Hardware.CPU.Cores) cores / $($fingerprint.Hardware.CPU.LogicalProcessors) threads)"
        }
        if ($fingerprint.Hardware?.RAM) {
            $md += "- **RAM:** $($fingerprint.Hardware.RAM.TotalGB) GB"
        }
        $md += ""
        $md += "## Disks"
        if ($fingerprint.Disks?.Volumes) {
            foreach ($v in $fingerprint.Disks.Volumes) {
                $md += "| $($v.Name) | $($v.Label) | $($v.TotalGB) GB | $($v.FreeGB) GB free | $($v.UsedPercent)% |"
            }
        }
        $md += ""
        $md += "## Docker"
        if ($fingerprint.Docker?.Available) {
            $md += "- **Containers:** $($fingerprint.Docker.ContainerCount) running"
            if ($fingerprint.Docker.RunningContainers) {
                foreach ($c in $fingerprint.Docker.RunningContainers) {
                    $md += "  - ``$($c.Name)`` ($($c.Image)) - $($c.Status)"
                }
            }
        }
        $md += ""
        $md += "---"
        $md += "_Hash: $($fingerprint._meta.FingerprintHash)_"
        $output = $md -join "`n"
        $output
    }
}

# Write to file if requested
if ($OutputPath) {
    $outDir = Split-Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
    $output | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "Fingerprint written to: $OutputPath" -ForegroundColor Green
}

exit 0
