#Requires -Version 7.0

<#
.SYNOPSIS
    Reclaim VRAM and system RAM by killing non-essential GPU/memory consumers.
.DESCRIPTION
    Toggle to free VRAM on NVIDIA GPU by terminating Windows desktop apps that
    silently consume GPU memory (Steam, NVIDIA Overlay, Photos, Radeon, etc.).
    
    Also provides modes for RAM optimization (Ollama model unload, Docker cache drop).
    
    Designed for 128GB DDR5 + RTX 5090 systems where VRAM is the bottleneck.
    
    Exit Codes:
        0 - Success
        1 - No VRAM-consuming processes found
        2 - Execution error
    
.PARAMETER Mode
    What to reclaim:
      - VRAM   : Kill GPU-hogging Windows processes (default)
      - RAM    : Force WSL2 memory reclaim + Ollama cleanup
      - Full   : Both VRAM + RAM reclamation
      - Status : Show current usage without changing anything

.PARAMETER Force
    Skip confirmation prompt and kill immediately.

.PARAMETER DryRun
    Show what would be killed without actually doing it.

.PARAMETER Custom
    Additional process names to kill (comma-separated).

.EXAMPLE
    # Check current VRAM/RAM usage
    ./9020_Optimize-GPUMemory.ps1 -Mode Status

    # Kill VRAM hogs (with confirmation)
    ./9020_Optimize-GPUMemory.ps1

    # Kill everything, no confirmation
    ./9020_Optimize-GPUMemory.ps1 -Mode Full -Force

    # Dry run — see what would die
    ./9020_Optimize-GPUMemory.ps1 -DryRun

.NOTES
    Stage: Maintenance
    Order: 9020
    Dependencies: none
    Tags: gpu, vram, memory, optimization, nvidia
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('VRAM', 'RAM', 'Full', 'Status')]
    [string]$Mode = 'VRAM',

    [switch]$Force,

    [switch]$DryRun,

    [string[]]$Custom
)

. "$PSScriptRoot/../_init.ps1"

# =============================================================================
# VRAM Hog Definitions
# =============================================================================
# These Windows processes silently consume GPU memory even when not in use.
# Sorted by typical VRAM consumption (highest first).

$VRAMTargets = @(
    @{ Name = 'steam';              Desc = 'Steam Client';           EstMB = '200-500' }
    @{ Name = 'steamwebhelper';     Desc = 'Steam Web Helper';       EstMB = '100-300' }
    @{ Name = 'GameOverlayUI';     Desc = 'Steam Overlay';          EstMB = '50-150'  }
    @{ Name = 'nv_ui';             Desc = 'NVIDIA Overlay UI';      EstMB = '200-500' }
    @{ Name = 'NVIDIA Share';      Desc = 'NVIDIA ShadowPlay';      EstMB = '100-300' }
    @{ Name = 'nvcontainer';       Desc = 'NVIDIA Container';       EstMB = '50-150'  }
    @{ Name = 'Microsoft.Photos';  Desc = 'Windows Photos';         EstMB = '100-300' }
    @{ Name = 'RadeonSoftware';    Desc = 'AMD Radeon Software';    EstMB = '50-150'  }
    @{ Name = 'AMDRSSrcExt';       Desc = 'AMD RSS Extension';      EstMB = '20-50'   }
    @{ Name = 'M365Copilot';       Desc = 'M365 Copilot';           EstMB = '50-100'  }
    @{ Name = 'WidgetBoard';       Desc = 'Windows Widgets';        EstMB = '50-100'  }
    @{ Name = 'Widgets';           Desc = 'Windows Widgets';        EstMB = '50-100'  }
    @{ Name = 'WidgetService';     Desc = 'Widget Service';         EstMB = '20-50'   }
    @{ Name = 'gamebar';           Desc = 'Xbox Game Bar';          EstMB = '50-100'  }
    @{ Name = 'GameBar';           Desc = 'Xbox Game Bar';          EstMB = '50-100'  }
    @{ Name = 'GameBarPresenceWriter'; Desc = 'Game Bar Writer';    EstMB = '20-50'   }
    @{ Name = 'EpicGamesLauncher'; Desc = 'Epic Games Launcher';   EstMB = '100-300' }
    @{ Name = 'Discord';           Desc = 'Discord';                EstMB = '100-300' }
    @{ Name = 'Spotify';           Desc = 'Spotify';                EstMB = '50-150'  }
    @{ Name = 'Teams';             Desc = 'Microsoft Teams';        EstMB = '100-300' }
)

# =============================================================================
# Functions
# =============================================================================

function Get-NvidiaStatus {
    <#
    .SYNOPSIS
        Get current NVIDIA GPU status via nvidia-smi.
    #>
    try {
        $smiOutput = & nvidia-smi --query-gpu=name,memory.used,memory.total,memory.free,utilization.gpu --format=csv,noheader,nounits 2>&1
        if ($LASTEXITCODE -eq 0 -and $smiOutput) {
            $parts = $smiOutput -split ','
            return @{
                Name     = $parts[0].Trim()
                UsedMB   = [int]$parts[1].Trim()
                TotalMB  = [int]$parts[2].Trim()
                FreeMB   = [int]$parts[3].Trim()
                UtilPct  = [int]$parts[4].Trim()
            }
        }
    }
    catch {
        Write-Warning "nvidia-smi not available: $_"
    }
    return $null
}

function Get-SystemRAMStatus {
    <#
    .SYNOPSIS
        Get current system RAM status.
    #>
    $os = Get-CimInstance Win32_OperatingSystem
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedGB = [math]::Round($totalGB - $freeGB, 1)
    return @{
        TotalGB = $totalGB
        UsedGB  = $usedGB
        FreeGB  = $freeGB
        UsedPct = [math]::Round(($usedGB / $totalGB) * 100, 0)
    }
}

function Show-Status {
    <#
    .SYNOPSIS
        Display current VRAM and RAM status with identified targets.
    #>
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          AitherOS GPU & Memory Status                       ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    # GPU Status
    $gpu = Get-NvidiaStatus
    if ($gpu) {
        $usedPct = [math]::Round(($gpu.UsedMB / $gpu.TotalMB) * 100, 0)
        $barLen = 40
        $filled = [math]::Round($usedPct / 100 * $barLen)
        $empty = $barLen - $filled
        $bar = ('█' * $filled) + ('░' * $empty)
        
        $barColor = if ($usedPct -gt 90) { 'Red' } elseif ($usedPct -gt 70) { 'Yellow' } else { 'Green' }
        
        Write-Host "  🎮 GPU: $($gpu.Name)" -ForegroundColor White
        Write-Host -NoNewline "  VRAM: ["
        Write-Host -NoNewline $bar -ForegroundColor $barColor
        Write-Host "] $usedPct% ($($gpu.UsedMB) / $($gpu.TotalMB) MB)"
        Write-Host "  Free: $($gpu.FreeMB) MB" -ForegroundColor $(if ($gpu.FreeMB -lt 2000) { 'Red' } else { 'Green' })
    }
    else {
        Write-Host "  GPU: nvidia-smi not available" -ForegroundColor Yellow
    }

    # RAM Status
    Write-Host ""
    $ram = Get-SystemRAMStatus
    $ramBarLen = 40
    $ramFilled = [math]::Round($ram.UsedPct / 100 * $ramBarLen)
    $ramEmpty = $ramBarLen - $ramFilled
    $ramBar = ('█' * $ramFilled) + ('░' * $ramEmpty)
    $ramColor = if ($ram.UsedPct -gt 90) { 'Red' } elseif ($ram.UsedPct -gt 70) { 'Yellow' } else { 'Green' }

    Write-Host "  🧠 RAM: $($ram.TotalGB) GB DDR5" -ForegroundColor White
    Write-Host -NoNewline "  Used: ["
    Write-Host -NoNewline $ramBar -ForegroundColor $ramColor
    Write-Host "] $($ram.UsedPct)% ($($ram.UsedGB) / $($ram.TotalGB) GB)"
    Write-Host "  Free: $($ram.FreeGB) GB" -ForegroundColor $(if ($ram.FreeGB -lt 4) { 'Red' } else { 'Green' })

    # Find running VRAM targets
    Write-Host ""
    Write-Host "  📋 VRAM Targets Found:" -ForegroundColor Yellow
    $found = @()
    foreach ($target in $VRAMTargets) {
        $procs = Get-Process -Name $target.Name -ErrorAction SilentlyContinue
        if ($procs) {
            $ramMB = [math]::Round(($procs | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 0)
            Write-Host "    ✗ $($target.Desc.PadRight(25)) PID: $(($procs.Id -join ',').PadRight(12)) RAM: ${ramMB}MB  VRAM: ~$($target.EstMB)MB" -ForegroundColor Red
            $found += $target
        }
    }
    if (-not $found) {
        Write-Host "    ✓ No VRAM-hogging processes detected!" -ForegroundColor Green
    }

    # Ollama status
    Write-Host ""
    Write-Host "  🦙 Ollama Models:" -ForegroundColor Yellow
    try {
        $ollamaPs = & ollama ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $ollamaPs) {
                if ($line -match 'GPU|CPU') {
                    Write-Host "    $line"
                }
            }
        }
    }
    catch {
        Write-Host "    Ollama not running" -ForegroundColor DarkGray
    }

    Write-Host ""
    return $found
}

function Invoke-VRAMReclaim {
    <#
    .SYNOPSIS
        Kill VRAM-consuming Windows processes.
    #>
    param([switch]$WhatIf)

    $killed = @()
    $allTargets = $VRAMTargets.Clone()
    
    # Add custom targets
    if ($Custom) {
        foreach ($name in $Custom) {
            $allTargets += @{ Name = $name; Desc = "Custom: $name"; EstMB = '???' }
        }
    }

    foreach ($target in $allTargets) {
        $procs = Get-Process -Name $target.Name -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($proc in $procs) {
                if ($WhatIf) {
                    Write-Host "  [DRY RUN] Would kill: $($target.Desc) (PID $($proc.Id))" -ForegroundColor Yellow
                }
                else {
                    try {
                        Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                        Write-Host "  ✓ Killed: $($target.Desc) (PID $($proc.Id))" -ForegroundColor Green
                        $killed += $target.Desc
                    }
                    catch {
                        Write-Host "  ✗ Failed to kill $($target.Desc) (PID $($proc.Id)): $_" -ForegroundColor Red
                    }
                }
            }
        }
    }

    return $killed
}

function Invoke-RAMReclaim {
    <#
    .SYNOPSIS
        Reclaim system RAM — drop WSL2 caches, unload idle Ollama models.
    #>
    param([switch]$WhatIf)

    # 1. Unload idle Ollama models from memory
    Write-Host "  Checking Ollama for idle models..." -ForegroundColor Cyan
    try {
        $ollamaPs = & ollama ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Parse loaded models
            foreach ($line in $ollamaPs) {
                if ($line -match '^(\S+)\s') {
                    $modelName = $Matches[1]
                    if ($modelName -eq 'NAME') { continue } # Header
                    if ($WhatIf) {
                        Write-Host "  [DRY RUN] Would unload Ollama model: $modelName" -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "  Unloading Ollama model: $modelName..." -ForegroundColor Cyan
                        # Send generate request with keep_alive=0 to unload
                        try {
                            $body = @{ model = $modelName; keep_alive = 0 } | ConvertTo-Json
                            Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 10 | Out-Null
                            Write-Host "  ✓ Unloaded: $modelName" -ForegroundColor Green
                        }
                        catch {
                            Write-Host "  ✗ Failed to unload $modelName : $_" -ForegroundColor Red
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Host "  Ollama not accessible" -ForegroundColor DarkGray
    }

    # 2. Force WSL2 to drop cached memory
    Write-Host "  Dropping WSL2 page cache..." -ForegroundColor Cyan
    if (-not $WhatIf) {
        try {
            wsl -d docker-desktop -e sh -c "echo 1 > /proc/sys/vm/drop_caches" 2>&1 | Out-Null
            Write-Host "  ✓ WSL2 page cache dropped" -ForegroundColor Green
        }
        catch {
            Write-Host "  ✗ Could not drop WSL2 caches (may need admin): $_" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  [DRY RUN] Would drop WSL2 page cache" -ForegroundColor Yellow
    }
}

# =============================================================================
# Main Execution
# =============================================================================

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  AitherOS GPU/Memory Optimizer  |  Mode: $Mode" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Always show status first
$found = Show-Status

if ($Mode -eq 'Status') {
    exit 0
}

# Confirm unless -Force
if (-not $Force -and -not $DryRun) {
    Write-Host ""
    $action = switch ($Mode) {
        'VRAM'  { "Kill $($found.Count) VRAM-consuming processes" }
        'RAM'   { "Reclaim system RAM (unload Ollama models, drop WSL2 cache)" }
        'Full'  { "Kill $($found.Count) VRAM processes AND reclaim system RAM" }
    }
    $confirm = Read-Host "  $action? [Y/n]"
    if ($confirm -and $confirm -notin @('Y', 'y', 'Yes', 'yes', '')) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""

# Execute reclamation
$gpuBefore = Get-NvidiaStatus
$ramBefore = Get-SystemRAMStatus

if ($Mode -in @('VRAM', 'Full')) {
    Write-Host "  🎯 Reclaiming VRAM..." -ForegroundColor Cyan
    $killed = Invoke-VRAMReclaim -WhatIf:$DryRun
}

if ($Mode -in @('RAM', 'Full')) {
    Write-Host ""
    Write-Host "  🧠 Reclaiming RAM..." -ForegroundColor Cyan
    Invoke-RAMReclaim -WhatIf:$DryRun
}

# Show results
if (-not $DryRun) {
    Start-Sleep -Seconds 2  # Let processes die and GPU release memory
    
    Write-Host ""
    Write-Host "  ═══ Results ═══" -ForegroundColor Green
    
    $gpuAfter = Get-NvidiaStatus
    $ramAfter = Get-SystemRAMStatus
    
    if ($gpuBefore -and $gpuAfter) {
        $vramFreed = $gpuAfter.FreeMB - $gpuBefore.FreeMB
        Write-Host "  VRAM freed: ~${vramFreed} MB ($($gpuBefore.FreeMB) → $($gpuAfter.FreeMB) MB free)" -ForegroundColor $(if ($vramFreed -gt 0) { 'Green' } else { 'Yellow' })
    }
    
    $ramFreed = [math]::Round($ramAfter.FreeGB - $ramBefore.FreeGB, 1)
    Write-Host "  RAM freed:  ~${ramFreed} GB ($($ramBefore.FreeGB) → $($ramAfter.FreeGB) GB free)" -ForegroundColor $(if ($ramFreed -gt 0) { 'Green' } else { 'Yellow' })
}

Write-Host ""
Write-Host "  Done!" -ForegroundColor Green
Write-Host ""
