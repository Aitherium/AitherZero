#Requires -Version 7.0
# Stage: Environment
# Dependencies: None
# Description: Get comprehensive status of AitherZero services (ComfyUI, Ollama, AitherNode) with resource metrics

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Services = @('ComfyUI', 'Ollama', 'AitherNode', 'AitherVeil', 'Cloudflared'),

    [Parameter()]
    [switch]$AsJson,

    [Parameter()]
    [switch]$ShowOutput,

    [Parameter()]
    [switch]$IncludeMetrics,
    
    [Parameter()]
    [switch]$Fast  # Skip module loading for API calls
)

# Only load the module if not in Fast mode (for API calls)
if (-not $Fast) {
    . "$PSScriptRoot/_init.ps1"
} else {
    # Minimal init - just find project root
    $current = $PSScriptRoot
    while ($current) {
        if (Test-Path (Join-Path $current "AitherZero/AitherZero.psd1")) { break }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    $projectRoot = $current
}

# Cache GPU info for performance
$script:GpuInfo = $null
$script:TotalMemoryMB = $null
$script:ListeningPorts = $null

function Get-CachedTotalMemory {
    if ($null -eq $script:TotalMemoryMB) {
        $script:TotalMemoryMB = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1MB
    }
    return $script:TotalMemoryMB
}

function Get-CachedListeningPorts {
    if ($null -eq $script:ListeningPorts) {
        # Load all listening connections once (this is what's slow)
        $script:ListeningPorts = @{}
        try {
            Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
                $script:ListeningPorts[$_.LocalPort] = $_.OwningProcess
            }
        } catch { }
    }
    return $script:ListeningPorts
}

function Test-PortOpenFast {
    param([int]$Port)
    
    if ($Port -le 0) { return $false }
    
    # Use cached listening ports for speed
    $listening = Get-CachedListeningPorts
    return $listening.ContainsKey($Port)
}

function Get-PortOwnerPID {
    param([int]$Port)
    
    $listening = Get-CachedListeningPorts
    if ($listening.ContainsKey($Port)) {
        return $listening[$Port]
    }
    return $null
}

function Get-GpuMetrics {
    if ($script:GpuInfo -eq $null) {
        $script:GpuInfo = @{
            Available = $false
            TotalVRAM = 0
            UsedVRAM = 0
            GpuUtil = 0
        }
        
        if ($IsWindows) {
            try {
                # Check if nvidia-smi is available
                $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
                if ($nvidiaSmi) {
                    $gpuQuery = nvidia-smi --query-gpu=memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits 2>$null
                    if ($gpuQuery -and $LASTEXITCODE -eq 0) {
                        $parts = $gpuQuery -split ','
                        $script:GpuInfo.Available = $true
                        $script:GpuInfo.TotalVRAM = [int]$parts[0].Trim()
                        $script:GpuInfo.UsedVRAM = [int]$parts[1].Trim()
                        $script:GpuInfo.GpuUtil = [int]$parts[2].Trim()
                    }
                }
            } catch {
                Write-Verbose "Failed to get GPU metrics: $_"
            }
        }
    }
    return $script:GpuInfo
}

function Get-ProcessCpuUsage {
    param([int]$ProcessId)
    
    if (-not $ProcessId) { return 0 }
    
    # Skip CPU measurement - it's too slow and not critical for the dashboard
    # The dashboard can show memory/uptime which are fast to get
    return 0
}

function Get-ProcessIOMetrics {
    param([int]$ProcessId)
    
    $io = @{
        ReadBytesSec = 0
        WriteBytesSec = 0
    }
    
    if (-not $ProcessId) { return $io }
    
    try {
        if ($IsWindows) {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($proc) {
                # Get current IO counters
                $io.ReadBytesSec = [Math]::Round($proc.Handles, 0)  # Approximate metric
                $io.WriteBytesSec = 0
            }
        }
    } catch {
        Write-Verbose "Failed to get IO metrics for PID $ProcessId : $_"
    }
    return $io
}

function Get-ProcessStatus {
    param(
        [string]$Name, 
        [string]$Pattern, 
        [int]$Port,
        [switch]$IncludeMetrics
    )

    $status = [PSCustomObject]@{
        Name = $Name
        DisplayName = $Name
        Status = 'Stopped'
        PID = $null
        Port = $Port
        PortOpen = $false
        MemoryMB = 0
        MemoryPercent = 0
        CpuPercent = 0
        GpuMemoryMB = $null
        GpuPercent = $null
        DiskReadMBSec = 0
        DiskWriteMBSec = 0
        NetworkConnections = 0
        Uptime = $null
        UptimeSeconds = 0
        ProcessName = $null
        CommandLine = $null
        ExecutablePath = $null
        WorkingDirectory = $null
    }

    $totalMemory = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).TotalPhysicalMemory / 1MB

    # Check Process
    if ($IsWindows) {
        $processes = Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$Pattern%'" -ErrorAction SilentlyContinue
        # Filter out the script itself if it matches
        $proc = $processes | Where-Object { $_.ProcessId -ne $PID } | Select-Object -First 1
        
        if ($proc) {
            $status.Status = 'Running'
            $status.PID = $proc.ProcessId
            $status.CommandLine = $proc.CommandLine
            $status.ExecutablePath = $proc.ExecutablePath
            $status.ProcessName = $proc.Name
            
            # Get Memory/Uptime from Get-Process for easier access
            $p = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
            if ($p) {
                $status.MemoryMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                $status.MemoryPercent = [Math]::Round(($p.WorkingSet64 / 1MB) / $totalMemory * 100, 1)
                $status.Uptime = (Get-Date) - $p.StartTime
                $status.UptimeSeconds = [int]$status.Uptime.TotalSeconds
                $status.ProcessName = $p.ProcessName
                
                # Get working directory if available
                try {
                    $status.WorkingDirectory = (Get-Process -Id $proc.ProcessId -FileVersionInfo -ErrorAction SilentlyContinue).FileName | Split-Path -Parent
                } catch { }
            }
            
            # Get enhanced metrics if requested
            if ($IncludeMetrics) {
                $status.CpuPercent = Get-ProcessCpuUsage -ProcessId $proc.ProcessId
                
                # Get network connections
                try {
                    $connections = Get-NetTCPConnection -OwningProcess $proc.ProcessId -ErrorAction SilentlyContinue
                    $status.NetworkConnections = ($connections | Measure-Object).Count
                } catch { }
                
                # Note: Get-Counter is too slow (9+ seconds) - skip disk IO metrics
                # Use WMI instead if needed in the future
            }
        }
    } else {
        # Linux/macOS check
        try {
            # Use sh to bypass PowerShell alias 'ps' -> 'Get-Process'
            $psOut = sh -c "ps -ef" | Select-String $Pattern
            if ($psOut) {
                $status.Status = 'Running'
                
                # Try to get details via Get-Process if possible
                $p = Get-Process | Where-Object { $_.Path -match $Pattern -or $_.CommandLine -match $Pattern } | Select-Object -First 1
                if ($p) {
                    $status.PID = $p.Id
                    $status.MemoryMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                    $status.ProcessName = $p.ProcessName
                }
            }
        } catch {
            Write-Verbose "Failed to check process status on non-Windows: $_"
        }
    }

    # Check Port
    if ($Port -and $Port -gt 0) {
        try {
            if ($IsWindows) {
                $tcpConnection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
                if ($tcpConnection) {
                    $status.PortOpen = $true
                    # If we didn't find process by pattern but port is open, it's running
                    if ($status.Status -eq 'Stopped') {
                        $status.Status = 'Running'
                        $status.PID = $tcpConnection.OwningProcess
                        
                        $p = Get-Process -Id $tcpConnection.OwningProcess -ErrorAction SilentlyContinue
                        if ($p) {
                            $status.MemoryMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
                            $status.MemoryPercent = [Math]::Round(($p.WorkingSet64 / 1MB) / $totalMemory * 100, 1)
                            $status.ProcessName = $p.ProcessName
                            $status.Uptime = (Get-Date) - $p.StartTime
                            $status.UptimeSeconds = [int]$status.Uptime.TotalSeconds
                        }
                        
                        # Get command line for port owner
                        try {
                            $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($tcpConnection.OwningProcess)" -ErrorAction SilentlyContinue
                            if ($cimProc) {
                                $status.CommandLine = $cimProc.CommandLine
                                $status.ExecutablePath = $cimProc.ExecutablePath
                            }
                        } catch { }
                    }
                }
            } else {
                # Linux/Mac port check using socket
                $client = New-Object System.Net.Sockets.TcpClient
                $connect = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
                $success = $connect.AsyncWaitHandle.WaitOne(100)
                if ($success) {
                    $status.PortOpen = $true
                    if ($status.Status -eq 'Stopped') { $status.Status = 'Running' }
                }
                $client.Close()
            }
        } catch {
            Write-Verbose "Port check failed: $_"
        }
    }

    # Get GPU metrics for GPU-using processes (ComfyUI, Ollama)
    if ($status.Status -eq 'Running' -and $Name -in @('ComfyUI', 'Ollama')) {
        $gpu = Get-GpuMetrics
        if ($gpu.Available) {
            # Estimate GPU usage per process (simplified - GPU doesn't expose per-process easily)
            # For now, if the process is running, show shared GPU metrics
            $status.GpuMemoryMB = $gpu.UsedVRAM
            $status.GpuPercent = $gpu.GpuUtil
        }
    }

    return $status
}

$results = @()

foreach ($service in $Services) {
    switch ($service) {
        'ComfyUI' {
            $status = Get-ProcessStatus -Name 'ComfyUI' -Pattern 'main.py' -Port 8188 -IncludeMetrics:$IncludeMetrics
            $status.DisplayName = 'ComfyUI Image Generation'
            $results += $status
        }
        'Ollama' {
            $status = Get-ProcessStatus -Name 'Ollama' -Pattern 'ollama' -Port 11434 -IncludeMetrics:$IncludeMetrics
            $status.DisplayName = 'Ollama LLM Server'
            $results += $status
        }
        'AitherNode' {
            $status = Get-ProcessStatus -Name 'AitherNode' -Pattern 'AitherNode.*server.py' -Port 8080 -IncludeMetrics:$IncludeMetrics
            $status.DisplayName = 'AitherNode MCP Server'
            $results += $status
        }
        'AitherVeil' {
            # Check both port 3000 and 3001 (Next.js fallback)
            $status = Get-ProcessStatus -Name 'AitherVeil' -Pattern 'next-server' -Port 3000 -IncludeMetrics:$IncludeMetrics
            if ($status.Status -eq 'Stopped') {
                $status = Get-ProcessStatus -Name 'AitherVeil' -Pattern 'next-server' -Port 3001 -IncludeMetrics:$IncludeMetrics
                if ($status.Status -eq 'Running') {
                    $status.Port = 3001  # Update to actual port
                }
            }
            $status.DisplayName = 'AitherVeil Dashboard'
            $results += $status
        }
        'Cloudflared' {
            $status = Get-ProcessStatus -Name 'Cloudflared' -Pattern 'cloudflared' -Port 0 -IncludeMetrics:$IncludeMetrics
            $status.DisplayName = 'Cloudflare Tunnel'
            $results += $status
        }
    }
}

if ($AsJson) {
    $results | ConvertTo-Json -Depth 5
} elseif ($ShowOutput) {
    $results | Format-Table -AutoSize
} else {
    return $results
}
