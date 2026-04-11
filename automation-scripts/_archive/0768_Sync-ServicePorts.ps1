#Requires -Version 7.0

<#
.SYNOPSIS
    Synchronizes port configurations across all Aither service files.
.DESCRIPTION
    Reads the single source of truth (ports.json) and updates:
    - services.psd1 (PowerShell config)
    - AitherWatch.py (monitoring config)
    - Individual Python service files
    - Start scripts
    
    This ensures all port references are consistent across the ecosystem.
.PARAMETER ShowOutput
    Display detailed output
.PARAMETER DryRun
    Preview changes without modifying files
.PARAMETER SourceFile
    Path to ports.json (default: AitherOS/AitherNode/config/ports.json)
.EXAMPLE
    ./0768_Sync-ServicePorts.ps1 -ShowOutput
    Syncs all ports and shows what was updated
.EXAMPLE
    ./0768_Sync-ServicePorts.ps1 -DryRun -ShowOutput
    Preview what would be changed without modifying files
#>

[CmdletBinding()]
param(
    [switch]$ShowOutput,
    [switch]$DryRun,
    [string]$SourceFile
)

# Initialize
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = "Stop"
$script:ModifiedFiles = @()
$script:Errors = @()

# ============================================================================
# CONFIGURATION
# ============================================================================

$repoRoot = $env:AITHERZERO_ROOT
if (-not $repoRoot) {
    $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
}

if (-not $SourceFile) {
    $SourceFile = Join-Path $repoRoot "AitherOS/AitherNode/config/ports.json"
}

$servicesPsd1 = Join-Path $repoRoot "AitherZero/config/services.psd1"
$aitherWatchPy = Join-Path $repoRoot "AitherOS/AitherNode/AitherWatch.py"
$aitherNodeDir = Join-Path $repoRoot "AitherOS/AitherNode"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($ShowOutput) {
        $color = switch ($Level) {
            "Error" { "Red" }
            "Warning" { "Yellow" }
            "Success" { "Green" }
            default { "White" }
        }
        Write-Host $Message -ForegroundColor $color
    }
}

function Load-PortsConfig {
    param([string]$Path)
    
    if (-not (Test-Path $Path)) {
        throw "Ports config not found: $Path"
    }
    
    $json = Get-Content $Path -Raw | ConvertFrom-Json
    return $json.services
}

function Update-ServicesPsd1 {
    param($PortsConfig, [string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "  ⚠️ services.psd1 not found: $FilePath" -Level Warning
        return
    }
    
    $content = Get-Content $FilePath -Raw
    $modified = $false
    
    foreach ($service in $PortsConfig.PSObject.Properties) {
        $serviceName = $service.Name
        $port = $service.Value.port
        
        # Match pattern: Port = NNNN (with various spacing)
        # Look for the service block and update its port
        $pattern = "(?<=\s+$serviceName\s*=\s*@\{[^}]*Port\s*=\s*)\d+"
        
        if ($content -match $pattern) {
            $currentPort = $Matches[0]
            if ($currentPort -ne $port.ToString()) {
                Write-Log "  📝 $serviceName`: $currentPort → $port" -Level Information
                $content = $content -replace $pattern, $port.ToString()
                $modified = $true
            }
        }
    }
    
    if ($modified) {
        if ($DryRun) {
            Write-Log "  [DRY RUN] Would update services.psd1" -Level Warning
        } else {
            Set-Content -Path $FilePath -Value $content -NoNewline
            $script:ModifiedFiles += $FilePath
        }
    } else {
        Write-Log "  ✓ services.psd1 already in sync" -Level Success
    }
}

function Update-AitherWatchPy {
    param($PortsConfig, [string]$FilePath)
    
    if (-not (Test-Path $FilePath)) {
        Write-Log "  ⚠️ AitherWatch.py not found: $FilePath" -Level Warning
        return
    }
    
    $content = Get-Content $FilePath -Raw
    $modified = $false
    
    foreach ($service in $PortsConfig.PSObject.Properties) {
        $serviceName = $service.Name
        $port = $service.Value.port
        $serviceId = $serviceName.ToLower()
        
        # Match pattern in ComponentConfig blocks:
        # id="aitherpulse", ... port=8081
        # We look for the id and then the port on a nearby line
        
        # Pattern: endpoint and port within same ComponentConfig block
        $endpointPattern = "(?<=id=`"$serviceId`"[^)]+endpoint=`"http://localhost:)\d+(?=/)"
        $portPattern = "(?<=id=`"$serviceId`"[^)]+\n\s+port=)\d+"
        
        # Simpler approach: just find port=NNNN after the id
        if ($content -match "id=`"$serviceId`"[^)]+port=(\d+)") {
            $currentPort = $Matches[1]
            if ($currentPort -ne $port.ToString()) {
                Write-Log "  📝 $serviceName in AitherWatch: $currentPort → $port" -Level Information
                
                # Replace both endpoint port and port= value
                $blockPattern = "(id=`"$serviceId`"[^)]+endpoint=`"http://localhost:)\d+(/"
                $content = $content -replace $blockPattern, "`${1}$port`${2}"
                
                $blockPattern2 = "(id=`"$serviceId`"[^)]+\n\s+port=)\d+"
                $content = $content -replace $blockPattern2, "`${1}$port"
                
                $modified = $true
            }
        }
    }
    
    if ($modified) {
        if ($DryRun) {
            Write-Log "  [DRY RUN] Would update AitherWatch.py" -Level Warning
        } else {
            Set-Content -Path $FilePath -Value $content -NoNewline
            $script:ModifiedFiles += $FilePath
        }
    } else {
        Write-Log "  ✓ AitherWatch.py already in sync" -Level Success
    }
}

function Update-PythonServices {
    param($PortsConfig, [string]$Directory)
    
    $pyFiles = Get-ChildItem -Path $Directory -Filter "Aither*.py" -File
    
    foreach ($file in $pyFiles) {
        $serviceName = $file.BaseName
        $serviceConfig = $PortsConfig.$serviceName
        
        if (-not $serviceConfig) {
            continue
        }
        
        $port = $serviceConfig.port
        $envVar = $serviceConfig.env_var
        
        $content = Get-Content $file.FullName -Raw
        $modified = $false
        
        # Pattern 1: default=NNNN in argparse
        $pattern1 = "(?<=default=)\d{4}(?=.*port)"
        if ($content -match $pattern1) {
            $currentPort = $Matches[0]
            if ($currentPort -ne $port.ToString()) {
                Write-Log "  📝 $serviceName`.py argparse: $currentPort → $port" -Level Information
                $content = $content -replace $pattern1, $port.ToString()
                $modified = $true
            }
        }
        
        # Pattern 2: port=NNNN in uvicorn.run
        $pattern2 = "(?<=uvicorn\.run\([^)]*port=)\d{4}"
        if ($content -match $pattern2) {
            $currentPort = $Matches[0]
            if ($currentPort -ne $port.ToString()) {
                Write-Log "  📝 $serviceName`.py uvicorn: $currentPort → $port" -Level Information
                $content = $content -replace $pattern2, $port.ToString()
                $modified = $true
            }
        }
        
        # Pattern 3: PORT = NNNN or "NNNN" in getenv
        $pattern3 = "(?<=${envVar}`",\s*[`"']?)\d{4}(?=[`"']?\))"
        if ($content -match $pattern3) {
            $currentPort = $Matches[0]
            if ($currentPort -ne $port.ToString()) {
                Write-Log "  📝 $serviceName`.py env default: $currentPort → $port" -Level Information
                $content = $content -replace $pattern3, $port.ToString()
                $modified = $true
            }
        }
        
        if ($modified) {
            if ($DryRun) {
                Write-Log "  [DRY RUN] Would update $($file.Name)" -Level Warning
            } else {
                Set-Content -Path $file.FullName -Value $content -NoNewline
                $script:ModifiedFiles += $file.FullName
            }
        }
    }
}

function Show-PortTable {
    param($PortsConfig)
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  AITHER SERVICE PORTS (from ports.json)" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $services = $PortsConfig.PSObject.Properties | Sort-Object { $_.Value.port }
    
    foreach ($service in $services) {
        $name = $service.Name
        $port = $service.Value.port
        $layer = $service.Value.layer
        $desc = $service.Value.description
        
        Write-Host "  $($name.PadRight(20)) : " -NoNewline -ForegroundColor White
        Write-Host "$($port.ToString().PadRight(6))" -NoNewline -ForegroundColor Green
        Write-Host " [L$layer] " -NoNewline -ForegroundColor DarkGray
        Write-Host $desc -ForegroundColor DarkGray
    }
    
    Write-Host ""
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log ""
Write-Log "🔄 Synchronizing Service Ports" -Level Information
Write-Log "   Source: $SourceFile" -Level Information
if ($DryRun) {
    Write-Log "   Mode: DRY RUN (no changes will be made)" -Level Warning
}
Write-Log ""

# Load configuration
try {
    $portsConfig = Load-PortsConfig -Path $SourceFile
    Write-Log "✓ Loaded $($portsConfig.PSObject.Properties.Count) service configurations" -Level Success
} catch {
    Write-Log "❌ Failed to load ports config: $_" -Level Error
    exit 1
}

# Show port table
if ($ShowOutput) {
    Show-PortTable -PortsConfig $portsConfig
}

# Update each target file
Write-Log "📁 Updating configuration files..." -Level Information
Write-Log ""

Write-Log "  → services.psd1" -Level Information
Update-ServicesPsd1 -PortsConfig $portsConfig -FilePath $servicesPsd1

Write-Log "  → AitherWatch.py" -Level Information
Update-AitherWatchPy -PortsConfig $portsConfig -FilePath $aitherWatchPy

Write-Log "  → Python service files" -Level Information
Update-PythonServices -PortsConfig $portsConfig -Directory $aitherNodeDir

# Summary
Write-Log ""
Write-Log "═══════════════════════════════════════════════════════════════" -Level Information

if ($DryRun) {
    Write-Log "DRY RUN complete. No files were modified." -Level Warning
} elseif ($script:ModifiedFiles.Count -gt 0) {
    Write-Log "✓ Modified $($script:ModifiedFiles.Count) file(s):" -Level Success
    foreach ($file in $script:ModifiedFiles) {
        Write-Log "  - $file" -Level Information
    }
} else {
    Write-Log "✓ All files already in sync!" -Level Success
}

Write-Log ""

exit 0
