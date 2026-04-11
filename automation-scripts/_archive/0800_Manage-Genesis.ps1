#Requires -Version 7.0
<#
.SYNOPSIS
    Manages the AitherOS Genesis bootloader and ecosystem.
.DESCRIPTION
    This script manages the Genesis BMC (Baseboard Management Controller) for AitherOS.
    It can start Genesis itself (the bootloader), then use Genesis to boot all services.
    
    API Endpoint: http://localhost:8001

.PARAMETER Action
    The action to perform:
    - Start: Start Genesis bootloader process (if not running)
    - Boot: Boot all AitherOS services via Genesis
    - Stop: Shutdown Genesis and all services
    - Restart: Restart Genesis and services
    - Status: Get ecosystem status
    - Health: Get Genesis service health
    - Inventory: List all services
    - Install: Install Genesis as a system service
    - Reinitialize: IDEMPOTENT reinstall - handles ALL states (clean, broken, PAUSED, crashed)

.PARAMETER Profile
    Boot profile to use (default: core). Only used for Boot/Restart.

.PARAMETER Force
    Force the action (e.g., force shutdown).

.PARAMETER ShowOutput
    Show verbose output.

.EXAMPLE
    ./0800_Manage-Genesis.ps1 -Action Start
    Start the Genesis bootloader process.

.EXAMPLE
    ./0800_Manage-Genesis.ps1 -Action Boot -Profile full
    Boot all AitherOS services using the full profile.

.EXAMPLE
    ./0800_Manage-Genesis.ps1 -Action Stop -Force
    Force shutdown the ecosystem.

.EXAMPLE
    ./0800_Manage-Genesis.ps1 -Action Status
    Get the current status of all services.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Start', 'Boot', 'Stop', 'Restart', 'Status', 'Health', 'Inventory', 'Install', 'Reinitialize')]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [string]$Profile = "core",

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$ShowOutput
)

$GenesisUrl = "http://localhost:8001"
$GenesisPort = 8001

# Get paths
$ProjectRoot = $env:AITHERZERO_ROOT
if (-not $ProjectRoot) {
    $ProjectRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
}
$GenesisDir = Join-Path $ProjectRoot "AitherOS/AitherGenesis"
$GenesisService = Join-Path $GenesisDir "genesis_service.py"

# Load configuration from config.psd1
$ConfigPath = Join-Path $ProjectRoot "AitherZero/config/config.psd1"
$ConfigLocalPath = Join-Path $ProjectRoot "AitherZero/config/config.local.psd1"
$Config = $null
$WindowsServiceConfig = $null

if (Test-Path $ConfigPath) {
    try {
        $Config = Import-PowerShellDataFile -Path $ConfigPath
        # Merge local config if exists
        if (Test-Path $ConfigLocalPath) {
            $LocalConfig = Import-PowerShellDataFile -Path $ConfigLocalPath
            # Simple merge for WindowsService section
            if ($LocalConfig.WindowsService) {
                foreach ($key in $LocalConfig.WindowsService.Keys) {
                    if (-not $Config.WindowsService) { $Config.WindowsService = @{} }
                    $Config.WindowsService[$key] = $LocalConfig.WindowsService[$key]
                }
            }
        }
        $WindowsServiceConfig = $Config.WindowsService
    } catch {
        Write-Warning "Failed to load config.psd1: $_"
    }
}

function Test-GenesisRunning {
    try {
        $Response = Invoke-RestMethod -Uri "$GenesisUrl/health" -Method GET -TimeoutSec 2
        # API returns "healthy" not "running"
        return $Response.status -eq "healthy" -or $Response.status -eq "running"
    }
    catch {
        return $false
    }
}

function Start-GenesisProcess {
    Write-Host "Starting Genesis bootloader..." -ForegroundColor Yellow
    
    if (-not (Test-Path $GenesisService)) {
        Write-Error "Genesis service not found at: $GenesisService"
        return $false
    }
    
    # Check if already running
    if (Test-GenesisRunning) {
        Write-Host "Genesis is already running on port $GenesisPort" -ForegroundColor Green
        return $true
    }
    
    # Use AitherOS venv Python (not system Python!)
    $venvPython = Join-Path $ProjectRoot "AitherOS/.venv/Scripts/python.exe"
    if (Test-Path $venvPython) {
        $Python = [PSCustomObject]@{ Source = $venvPython }
        Write-Host "   Using venv Python: $venvPython" -ForegroundColor DarkGray
    } else {
        # Fallback to system Python
        $Python = Get-Command python -ErrorAction SilentlyContinue
        if (-not $Python) {
            $Python = Get-Command python3 -ErrorAction SilentlyContinue
        }
        if (-not $Python) {
            Write-Error "Python not found. Please install Python 3.11+"
            return $false
        }
        Write-Warning "Using system Python (venv not found at $venvPython)"
    }
    
    # Start Genesis as a module (avoids import errors)
    $AitherOSRoot = Join-Path $ProjectRoot "AitherOS"
    $env:PYTHONPATH = $AitherOSRoot
    $env:GENESIS_SKIP_AUTOBOOT = "false"  # Allow auto-boot unless disabled
    
    Push-Location $ProjectRoot
    try {
        $GenesisArgs = @("-m", "AitherGenesis.genesis_service", "--host", "0.0.0.0", "--port", "$GenesisPort")
        
        if ($IsWindows) {
            Start-Process -FilePath $Python.Source -ArgumentList $GenesisArgs -WindowStyle Normal -WorkingDirectory $ProjectRoot -PassThru | Out-Null
        } else {
            Start-Process -FilePath $Python.Source -ArgumentList $GenesisArgs -WorkingDirectory $ProjectRoot -PassThru | Out-Null
        }
        
        # Wait for startup
        Write-Host "Waiting for Genesis to start..." -ForegroundColor Yellow
        $attempts = 0
        $maxAttempts = 30
        while (-not (Test-GenesisRunning) -and $attempts -lt $maxAttempts) {
            Start-Sleep -Seconds 1
            $attempts++
            if ($ShowOutput) { Write-Host "." -NoNewline }
        }
        if ($ShowOutput) { Write-Host "" }
        
        if (Test-GenesisRunning) {
            Write-Host "Genesis started successfully!" -ForegroundColor Green
            Write-Host "Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
            return $true
        } else {
            Write-Error "Genesis failed to start within ${maxAttempts}s"
            return $false
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-GenesisRequest {
    param(
        [string]$Method,
        [string]$Endpoint,
        [hashtable]$QueryParams = @{},
        [switch]$AllowFailure
    )

    # Build URI with query parameters
    $Uri = "$GenesisUrl$Endpoint"
    if ($QueryParams.Count -gt 0) {
        $QueryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $Uri = "$Uri`?$QueryString"
    }

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Method $Method -ContentType "application/json" -TimeoutSec 30
        return $Response
    }
    catch {
        if ($AllowFailure) {
            return $null
        }
        Write-Error "Failed to communicate with AitherGenesis at $Uri"
        Write-Error "Is Genesis running? Try: ./0800_Manage-Genesis.ps1 -Action Start"
        Write-Error $_.Exception.Message
        exit 1
    }
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       AitherGenesis Manager           ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

switch ($Action) {
    'Start' {
        # Start Genesis process itself
        $Success = Start-GenesisProcess
        if (-not $Success) {
            Write-Error "Failed to start Genesis"
            exit 1
        }
    }

    'Boot' {
        # First ensure Genesis is running
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis not running, starting it first..." -ForegroundColor Yellow
            $Success = Start-GenesisProcess
            if (-not $Success) {
                Write-Error "Failed to start Genesis"
                exit 1
            }
        }
        
        Write-Host "Booting AitherOS (Profile: $Profile)..." -ForegroundColor Yellow
        $Params = @{ profile = $Profile }
        $Result = Invoke-GenesisRequest -Method POST -Endpoint "/startup" -QueryParams $Params
        
        Write-Host ""
        Write-Host "Status:  $($Result.status)" -ForegroundColor Green
        Write-Host "Message: $($Result.message)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Monitor status with: ./0800_Manage-Genesis.ps1 -Action Status" -ForegroundColor DarkGray
        Write-Host "Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
    }

    'Health' {
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis is NOT running" -ForegroundColor Red
            Write-Host "Start it with: ./0800_Manage-Genesis.ps1 -Action Start" -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "Checking Genesis health..."
        $Result = Invoke-GenesisRequest -Method GET -Endpoint "/health"
        
        Write-Host ""
        Write-Host "Service:       $($Result.service)" -ForegroundColor Green
        Write-Host "Status:        $($Result.status)" -ForegroundColor Green
        Write-Host "Version:       $($Result.version)" -ForegroundColor Cyan
        Write-Host "BMC Available: $($Result.bmc_available)" -ForegroundColor $(if ($Result.bmc_available) { 'Green' } else { 'Yellow' })
        Write-Host "Timestamp:     $($Result.timestamp)" -ForegroundColor Gray
    }

    'Status' {
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis is NOT running" -ForegroundColor Red
            Write-Host "Start it with: ./0800_Manage-Genesis.ps1 -Action Start" -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "Fetching ecosystem status..."
        
        # Get BMC status
        $BmcStatus = Invoke-GenesisRequest -Method GET -Endpoint "/bmc/status"
        
        Write-Host ""
        Write-Host "=== BMC State ===" -ForegroundColor Magenta
        Write-Host "Power State:  $($BmcStatus.power_state)" -ForegroundColor $(if ($BmcStatus.power_state -eq 'on') { 'Green' } else { 'Yellow' })
        Write-Host "Boot Stage:   $($BmcStatus.boot_stage)" -ForegroundColor Cyan
        
        # Show service counts from BMC
        if ($BmcStatus.services) {
            $svc = $BmcStatus.services
            Write-Host ""
            Write-Host "=== Services ===" -ForegroundColor Magenta
            Write-Host "Total:    $($svc.total)" -ForegroundColor Gray
            Write-Host "Enabled:  $($svc.enabled)" -ForegroundColor Gray
            Write-Host "Running:  $($svc.running)" -ForegroundColor Green
            Write-Host "Stopped:  $($svc.stopped)" -ForegroundColor $(if ($svc.stopped -gt 0) { 'Yellow' } else { 'Gray' })
            Write-Host "Failed:   $($svc.failed)" -ForegroundColor $(if ($svc.failed -gt 0) { 'Red' } else { 'Gray' })
            Write-Host "Disabled: $($svc.disabled)" -ForegroundColor Gray
        }
        
        Write-Host ""
        Write-Host "Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
        Write-Host "Use 'Inventory' action for full service list." -ForegroundColor DarkGray
    }

    'Inventory' {
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis is NOT running" -ForegroundColor Red
            exit 1
        }
        
        Write-Host "Fetching service inventory..."
        
        # Get BMC status with details
        $BmcStatus = Invoke-GenesisRequest -Method GET -Endpoint "/bmc/status"
        
        if ($BmcStatus.services_detail) {
            Write-Host ""
            Write-Host "=== Service Inventory ===" -ForegroundColor Magenta
            
            $ServiceList = $BmcStatus.services_detail.PSObject.Properties | ForEach-Object {
                [PSCustomObject]@{
                    Name     = $_.Name
                    Port     = $_.Value.port
                    Status   = $_.Value.status
                    Layer    = $_.Value.layer
                    Critical = if ($_.Value.critical) { "Yes" } else { "" }
                    Enabled  = if ($_.Value.enabled) { "Yes" } else { "No" }
                }
            } | Sort-Object Layer, Name
            
            $ServiceList | Format-Table -AutoSize
        } else {
            Write-Host "No service details available" -ForegroundColor Yellow
        }
    }

    'Stop' {
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis is not running" -ForegroundColor Yellow
            exit 0
        }
        
        Write-Host "Initiating shutdown..."
        $Params = @{ force = $Force.ToString().ToLower() }
        $Result = Invoke-GenesisRequest -Method POST -Endpoint "/shutdown" -QueryParams $Params -AllowFailure
        
        if ($Result) {
            Write-Host ""
            Write-Host "Status:  $($Result.status)" -ForegroundColor Yellow
            Write-Host "Message: $($Result.message)" -ForegroundColor Cyan
        } else {
            Write-Host "Shutdown signal sent" -ForegroundColor Yellow
        }
    }

    'Restart' {
        if (-not (Test-GenesisRunning)) {
            Write-Host "Genesis not running, starting fresh..." -ForegroundColor Yellow
            $Success = Start-GenesisProcess
            if ($Success) {
                # Then boot
                Write-Host "Booting AitherOS..." -ForegroundColor Yellow
                $Params = @{ profile = $Profile }
                $Result = Invoke-GenesisRequest -Method POST -Endpoint "/startup" -QueryParams $Params
                Write-Host "Status: $($Result.status)" -ForegroundColor Green
            }
        } else {
            Write-Host "Initiating power cycle via BMC..."
            $Params = @{ profile = $Profile }
            $Result = Invoke-GenesisRequest -Method POST -Endpoint "/bmc/power/cycle" -QueryParams $Params
            
            Write-Host ""
            Write-Host "Status:  $($Result.status)" -ForegroundColor Yellow
            Write-Host "Message: $($Result.message)" -ForegroundColor Cyan
        }
    }

    'Install' {
        Write-Host "Installing Genesis as Windows service using Servy..." -ForegroundColor Yellow
        
        if ($IsWindows) {
            $serviceName = "AitherGenesis"
            
            # Check if we're running as admin - required for service operations
            $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
                $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                if (-not $pwshPath) { $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
                $scriptPath = $MyInvocation.MyCommand.Path
                if (-not $scriptPath) { $scriptPath = $PSCommandPath }
                
                $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-Action", "Install")
                if ($ShowOutput) { $argList += "-ShowOutput" }
                
                try {
                    $proc = Start-Process -FilePath $pwshPath -ArgumentList $argList -Verb RunAs -PassThru -Wait
                    exit $proc.ExitCode
                } catch {
                    Write-Error "Failed to elevate. Please run from Administrator PowerShell."
                    exit 1
                }
            }
            
            # Check for Servy (preferred service manager)
            $servy = Get-Command servy-cli -ErrorAction SilentlyContinue
            if (-not $servy) {
                $servyPath = "C:\Program Files\Servy\servy-cli.exe"
                if (-not (Test-Path $servyPath)) {
                    Write-Host "Servy not found. Installing..." -ForegroundColor Yellow
                    & "$PSScriptRoot\0226_Install-Servy.ps1" -ShowOutput
                }
                if (Test-Path $servyPath) {
                    $servy = $servyPath
                } else {
                    Write-Error "Servy installation failed. Install it first: ./0226_Install-Servy.ps1"
                    exit 1
                }
            } else {
                $servy = $servy.Source
            }
            
            # Use AitherOS venv uvicorn (handles module imports properly)
            $uvicornExe = Join-Path $ProjectRoot "AitherOS/.venv/Scripts/uvicorn.exe"
            if (-not (Test-Path $uvicornExe)) {
                Write-Error "AitherOS venv uvicorn not found at: $uvicornExe"
                Write-Error "Run 0720_Setup-AitherOSVenv.ps1 first!"
                exit 1
            }
            
            $aitherOSDir = Join-Path $ProjectRoot "AitherOS"
            $logDir = Join-Path $ProjectRoot "AitherOS/Library/Logs"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            
            Write-Host "Installing Windows service: $serviceName" -ForegroundColor Yellow
            
            # Stop and remove existing service (ignore errors - may not exist)
            Write-Host "  [1/4] Removing existing service registration..." -ForegroundColor DarkGray
            & $servy stop --name $serviceName 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            & $servy uninstall --name $serviceName 2>$null | Out-Null
            
            # Kill any process on port 8001
            Write-Host "  [2/4] Freeing port 8001..." -ForegroundColor DarkGray
            try {
                $procs = Get-NetTCPConnection -LocalPort 8001 -ErrorAction SilentlyContinue |
                         Select-Object -ExpandProperty OwningProcess -Unique
                foreach ($pid in $procs) {
                    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                }
            } catch { }
            
            # Build environment and paths from config.psd1 (WindowsService section)
            $AitherNodeDir = Join-Path $aitherOSDir "AitherNode"
            $LibDir = Join-Path $AitherNodeDir "lib"
            $AgentsDir = Join-Path $aitherOSDir "agents"
            $venvScripts = Join-Path $aitherOSDir ".venv/Scripts"
            
            # CUDA paths from config or fallback to env/defaults
            $cudaConfig = $WindowsServiceConfig.CUDA
            if ($cudaConfig) {
                $cudaPath = $cudaConfig.Path
                $cudaBin = $cudaConfig.BinPath
                $cudnnPath = $cudaConfig.CuDNNPath
            } else {
                # Fallback to env vars or defaults
                $cudaPath = $env:CUDA_PATH
                if (-not $cudaPath) { $cudaPath = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9" }
                $cudaBin = Join-Path $cudaPath "bin"
                $cudnnPath = $env:CUDNN_PATH
                if (-not $cudnnPath) { $cudnnPath = "C:\Program Files\NVIDIA\CUDNN\v9.10\bin\12.9" }
            }
            
            Write-Host "  Using CUDA: $cudaPath" -ForegroundColor DarkGray
            Write-Host "  Using cuDNN: $cudnnPath" -ForegroundColor DarkGray
            
            # Build PYTHONPATH with escaped semicolons (\;) for multi-path values
            $pythonPathValue = "$ProjectRoot\;$aitherOSDir\;$AitherNodeDir\;$LibDir\;$AgentsDir"
            
            # Build PATH with CUDA directories - escaped semicolons for multi-path
            $pathValue = "$venvScripts\;$cudaBin\;$cudnnPath\;$env:SystemRoot\System32\;$env:SystemRoot"
            
            # Get additional env vars from config
            $extraEnvVars = ""
            if ($WindowsServiceConfig.EnvironmentVariables) {
                foreach ($key in $WindowsServiceConfig.EnvironmentVariables.Keys) {
                    $val = $WindowsServiceConfig.EnvironmentVariables[$key]
                    if ($val) { $extraEnvVars += ";$key=$val" }
                }
            }
            
            # Build env string: regular semicolons between vars, escaped \; within multi-path values
            $envVars = "PYTHONPATH=$pythonPathValue;AITHERZERO_ROOT=$ProjectRoot;AITHEROS_ROOT=$aitherOSDir;CUDA_PATH=$cudaPath;CUDA_HOME=$cudaPath;PATH=$pathValue;PYTHONIOENCODING=utf-8;PYTHONUTF8=1$extraEnvVars"
            
            # Install service using Servy with uvicorn
            Write-Host "  [3/4] Installing service with Servy..." -ForegroundColor DarkGray
            $uvicornParams = "AitherOS.AitherGenesis.genesis_service:app --host 0.0.0.0 --port 8001"
            
            $servyArgs = @(
                'install',
                "--name=`"$serviceName`"",
                "--path=`"$uvicornExe`"",
                "--params=`"$uvicornParams`"",
                "--startupDir=`"$ProjectRoot`"",
                "--displayName=`"AitherGenesis`"",
                "--description=`"AitherOS Genesis Bootloader - Service Lifecycle Manager`"",
                "--startupType=Automatic",
                "--env=`"$envVars`"",
                "--stdout=`"$(Join-Path $logDir 'genesis.log')`"",
                "--stderr=`"$(Join-Path $logDir 'genesis.err.log')`"",
                "--enableSizeRotation",
                "--rotationSize=10",
                "--quiet"
            )
            
            $argString = $servyArgs -join ' '
            Start-Process -FilePath $servy -ArgumentList $argString -Wait -NoNewWindow
            
            # Start the service
            Write-Host "  [4/4] Starting Genesis service..." -ForegroundColor DarkGray
            & $servy start --name $serviceName | Out-Null
            
            # Wait for API to come online
            Write-Host "Waiting for Genesis API..." -ForegroundColor DarkGray
            $attempts = 0
            $maxAttempts = 30
            while ($attempts -lt $maxAttempts) {
                if (Test-GenesisRunning) {
                    Write-Host " Ready!" -ForegroundColor Green
                    break
                }
                Start-Sleep -Seconds 1
                $attempts++
                Write-Host "." -NoNewline -ForegroundColor DarkGray
            }
            
            if (Test-GenesisRunning) {
                Write-Host ""
                Write-Host "Genesis installed and started successfully!" -ForegroundColor Green
                Write-Host "Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
            } else {
                Write-Host ""
                Write-Warning "Genesis service installed but API not responding yet."
                Write-Host "  Check logs:" -ForegroundColor Yellow
                Write-Host "    Stdout: $logDir\genesis.log" -ForegroundColor Gray
                Write-Host "    Stderr: $logDir\genesis.err.log" -ForegroundColor Gray
                Write-Host ""
                Write-Host "  Service status:" -ForegroundColor Yellow
                & $servy status --name $serviceName
            }
        }
        elseif ($IsLinux) {
            Write-Host "Creating systemd unit..." -ForegroundColor Yellow
            $unitContent = @"
[Unit]
Description=AitherOS Genesis Bootloader
After=network.target

[Service]
Type=simple
User=$env:USER
WorkingDirectory=$GenesisDir
ExecStart=$(Get-Command python).Source $GenesisService
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"@
            $unitPath = "/etc/systemd/system/aither-genesis.service"
            Write-Host "Writing unit file to: $unitPath" -ForegroundColor Yellow
            Write-Host "Run: sudo systemctl daemon-reload && sudo systemctl enable --now aither-genesis" -ForegroundColor Cyan
            Write-Host $unitContent
        }
        elseif ($IsMacOS) {
            Write-Host "Creating launchd plist..." -ForegroundColor Yellow
            $plistContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.aitheros.genesis</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(Get-Command python).Source</string>
        <string>$GenesisService</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$GenesisDir</string>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"@
            $plistPath = "$HOME/Library/LaunchAgents/com.aitheros.genesis.plist"
            Write-Host "Writing plist to: $plistPath" -ForegroundColor Yellow
            Write-Host "Run: launchctl load $plistPath" -ForegroundColor Cyan
            Write-Host $plistContent
        }
    }

    'Reinitialize' {
        # ═══════════════════════════════════════════════════════════════════════
        # IDEMPOTENT REINITIALIZE - Handles ALL states (clean, broken, crashed)
        # ═══════════════════════════════════════════════════════════════════════
        Write-Host "Reinitializing Genesis (idempotent)..." -ForegroundColor Yellow

        if (-not $IsWindows) {
            Write-Error "Reinitialize currently only supports Windows"
            exit 1
        }

        # Check if we're running as admin - required for service operations
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
            $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwshPath) { $pwshPath = "$env:ProgramFiles\PowerShell\7\pwsh.exe" }
            $scriptPath = $MyInvocation.MyCommand.Path
            if (-not $scriptPath) { $scriptPath = $PSCommandPath }

            $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"", "-Action", "Reinitialize")
            if ($ShowOutput) { $argList += "-ShowOutput" }

            try {
                $proc = Start-Process -FilePath $pwshPath -ArgumentList $argList -Verb RunAs -PassThru -Wait
                exit $proc.ExitCode
            } catch {
                Write-Error "Failed to elevate. Please run from Administrator PowerShell."
                exit 1
            }
        }

        # Check for Servy (preferred service manager)
        $servy = Get-Command servy-cli -ErrorAction SilentlyContinue
        if (-not $servy) {
            $servyPath = "C:\Program Files\Servy\servy-cli.exe"
            if (-not (Test-Path $servyPath)) {
                Write-Host "Servy not found. Installing..." -ForegroundColor Yellow
                & "$PSScriptRoot\0226_Install-Servy.ps1" -ShowOutput
                $servy = Get-Command servy-cli -ErrorAction SilentlyContinue
                if (-not $servy) {
                    $servyPath = "C:\Program Files\Servy\servy-cli.exe"
                    if (Test-Path $servyPath) {
                        $servy = $servyPath
                    } else {
                        Write-Error "Servy installation failed. Install it first: ./0226_Install-Servy.ps1"
                        exit 1
                    }
                } else {
                    $servy = $servy.Source
                }
            } else {
                $servy = $servyPath
            }
        } else {
            $servy = $servy.Source
        }

        # ═══════════════════════════════════════════════════════════════════════
        # SAFE REINITIALIZE
        # Reinitialize MUST NOT wipe the entire ecosystem. It only reinstalls
        # the Genesis bootloader service (AitherGenesis) and frees port 8001.
        # ═══════════════════════════════════════════════════════════════════════
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║        SAFE REINITIALIZE - Genesis Service Only              ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""

        $serviceName = "AitherGenesis"

        # 1. Stop existing service (ignore errors - may not exist or be stopped)
        Write-Host "  [1/7] Stopping existing service..." -ForegroundColor DarkGray
        & $servy stop --name $serviceName 2>$null | Out-Null
        Start-Sleep -Milliseconds 500

        # 2. Kill any process on port 8001
        Write-Host "  [2/7] Killing processes on port 8001..." -ForegroundColor DarkGray
        try {
            $procs = Get-NetTCPConnection -LocalPort 8001 -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty OwningProcess -Unique
            foreach ($pid in $procs) {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            }
        } catch { }

        # 3. Remove existing service registration (ignore errors)
        Write-Host "  [3/7] Removing existing service registration..." -ForegroundColor DarkGray
        & $servy uninstall --name $serviceName 2>$null | Out-Null

        # 4. Kill orphaned Python processes with 'AitherGenesis' or 'genesis_service' in cmdline
        Write-Host "  [4/7] Killing orphaned Genesis processes..." -ForegroundColor DarkGray
        Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*genesis_service*' -or $_.CommandLine -like '*AitherGenesis*' } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }

        # Check venv Python - prefer AitherOS venv
        $venvPython = Join-Path $ProjectRoot "AitherOS/.venv/Scripts/python.exe"
        if (-not (Test-Path $venvPython)) {
            # Fallback to root venv (legacy)
            $venvPython = Join-Path $ProjectRoot ".venv/Scripts/python.exe"
        }
        if (-not (Test-Path $venvPython)) {
            Write-Error "Python venv not found. Run 0720_Setup-AitherOSVenv.ps1 first!"
            exit 1
        }
        $python = $venvPython

        # Create logs directory if needed
        $logsDir = Join-Path $ProjectRoot "AitherOS/Library/Logs"
        if (-not (Test-Path $logsDir)) {
            New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
        }

        # 5. Fresh install with correct paths using Servy
        Write-Host "  [5/7] Installing Genesis service with correct paths..." -ForegroundColor DarkGray

        # Use uvicorn invocation with PROJECT ROOT as working directory
        $uvicornExe = Join-Path $ProjectRoot "AitherOS/.venv/Scripts/uvicorn.exe"
        if (-not (Test-Path $uvicornExe)) {
            Write-Error "AitherOS venv uvicorn not found at: $uvicornExe"
            Write-Error "Run 0720_Setup-AitherOSVenv.ps1 first!"
            exit 1
        }
        
        $uvicornParams = "AitherOS.AitherGenesis.genesis_service:app --host 0.0.0.0 --port 8001"

        $AitherOSDir = Join-Path $ProjectRoot "AitherOS"
        $AitherNodeDir = Join-Path $AitherOSDir "AitherNode"
        $LibDir = Join-Path $AitherNodeDir "lib"
        $AgentsDir = Join-Path $AitherOSDir "agents"

        # Build PYTHONPATH and environment variables string for Servy
        # Escape backslashes and semicolons within values using \;
        $pythonPathValue = "$ProjectRoot\;$AitherOSDir\;$AitherNodeDir\;$LibDir\;$AgentsDir"
        $envVars = "PYTHONPATH=$pythonPathValue;PYTHONIOENCODING=utf-8;AITHERZERO_ROOT=$ProjectRoot;AITHEROS_ROOT=$AitherOSDir"

        # Use --param=value format (equals sign required for values starting with --)
        $servyArgs = @(
            'install',
            "--name=`"$serviceName`"",
            "--path=`"$uvicornExe`"",
            "--params=`"$uvicornParams`"",
            "--startupDir=`"$ProjectRoot`"",
            "--displayName=`"AitherGenesis`"",
            "--description=`"AitherOS Bootloader - Service Lifecycle Manager`"",
            "--startupType=Automatic",
            "--env=`"$envVars`"",
            "--stdout=`"$(Join-Path $logsDir 'genesis.log')`"",
            "--stderr=`"$(Join-Path $logsDir 'genesis.err.log')`"",
            "--enableSizeRotation",
            "--rotationSize=10",
            "--quiet"
        )
        
        $argString = $servyArgs -join ' '
        Start-Process -FilePath $servy -ArgumentList $argString -Wait -NoNewWindow

        # 6. Start service
        Write-Host "  [6/7] Starting Genesis service..." -ForegroundColor DarkGray
        & $servy start --name $serviceName | Out-Null

        # 7. Wait for Genesis API to respond (and show actionable diagnostics)
        Write-Host "  [7/7] Waiting for Genesis API..." -ForegroundColor DarkGray
        $attempts = 0
        $maxAttempts = 60  # 60 seconds for initial API response
        while ($attempts -lt $maxAttempts) {
            if (Test-GenesisRunning) {
                Write-Host " Ready!" -ForegroundColor Green
                break
            }
            Start-Sleep -Seconds 1
            $attempts++
            Write-Host "." -NoNewline -ForegroundColor DarkGray
        }

        if (-not (Test-GenesisRunning)) {
            Write-Host ""
            Write-Error "Genesis API failed to respond after reinstall."
            Write-Host "  Logs:" -ForegroundColor Yellow
            Write-Host "    Stdout: $($logsDir)\\genesis.log" -ForegroundColor Gray
            Write-Host "    Stderr: $($logsDir)\\genesis.err.log" -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Servy status:" -ForegroundColor Yellow
            & $servy status --name $serviceName 2>$null
            exit 1
        }

        # Open Genesis dashboard automatically when ready
        try {
            Start-Process "http://localhost:$GenesisPort/dashboard" | Out-Null
        } catch { }

        # 8. Wait for auto-boot to complete (services to come online)
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║         Genesis Auto-Boot in Progress - Please Wait          ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        Write-Host ""

        $bootTimeout = 300  # 5 minutes for full boot
        $bootStart = Get-Date
        $lastOnline = 0
        $stableCount = 0
        $lastProgressTime = Get-Date

        while (((Get-Date) - $bootStart).TotalSeconds -lt $bootTimeout) {
            try {
                $status = Invoke-RestMethod -Uri "http://localhost:$GenesisPort/status" -TimeoutSec 5 -ErrorAction SilentlyContinue
                $online = $status.services_online
                $total = $status.services_total
                $pct = if ($total -gt 0) { [math]::Round(($online / $total) * 100) } else { 0 }

                # Show progress every service change or every 5 seconds
                if ($online -ne $lastOnline -or ((Get-Date) - $lastProgressTime).TotalSeconds -ge 5) {
                    $bar = "█" * [math]::Floor($pct / 5) + "░" * (20 - [math]::Floor($pct / 5))
                    Write-Host "`r  [$bar] $pct% - $online/$total services online     " -NoNewline -ForegroundColor Cyan
                    $lastProgressTime = Get-Date
                }

                # Check if boot is complete (stable for 10 seconds)
                if ($online -eq $lastOnline -and $online -gt 0) {
                    $stableCount++
                    if ($stableCount -ge 10 -and $online -ge ($total * 0.8)) {
                        # 80% or more services online and stable
                        break
                    }
                } else {
                    $stableCount = 0
                }
                $lastOnline = $online
            } catch {
                Write-Host "`r  Waiting for status...                                    " -NoNewline -ForegroundColor DarkGray
            }
            Start-Sleep -Seconds 1
        }

        Write-Host ""
        Write-Host ""

        # Final status check
        try {
            $finalStatus = Invoke-RestMethod -Uri "http://localhost:$GenesisPort/status" -TimeoutSec 5
            $online = $finalStatus.services_online
            $total = $finalStatus.services_total

            Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
            Write-Host "║              Genesis Bootstrap Complete!                     ║" -ForegroundColor Green
            Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Services Online: $online / $total" -ForegroundColor $(if ($online -ge $total * 0.8) { "Green" } else { "Yellow" })
            Write-Host ""
            Write-Host "  Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
            Write-Host "  API Docs:  http://localhost:$GenesisPort/docs" -ForegroundColor Cyan
            Write-Host ""
        } catch {
            Write-Host "  Genesis is running but couldn't get final status." -ForegroundColor Yellow
            Write-Host "  Dashboard: http://localhost:$GenesisPort/dashboard" -ForegroundColor Cyan
        }

        exit 0
    }
}
