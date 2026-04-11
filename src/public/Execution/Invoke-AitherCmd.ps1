<#
.SYNOPSIS
    Main CLI for AitherOS interaction.
    
.DESCRIPTION
    Provides a unified command-line interface alias 'aither' to interact with 
    AitherOS services, logs, and APIs.
    
.EXAMPLE
    aither status moltbook
    aither logs genesis
    aither call moltbook /search "query"
    aither list
    
.FUNCTIONALITY
    Core AitherOS CLI
#>
function Invoke-AitherCmd {
    [CmdletBinding()]
    [Alias('aither')]
    param(
        [Parameter(Position=0, Mandatory=$false)]
        [string]$Command = "help",

        [Parameter(Position=1, Mandatory=$false)]
        [string]$Target,

        [Parameter(Position=2, Mandatory=$false)]
        [string]$Arg1,

        [Parameter(Position=3, Mandatory=$false)]
        [string]$Arg2,
        
        [Parameter(ValueFromRemainingArguments=$true)]
        $RemainingArgs
    )

    # --- Configuration & Cache ---
    $CACHE_FILE = "$env:TEMP\aither_services_cache.json"
    $ProjectRoot = if ($env:AITHERZERO_ROOT) { Split-Path $env:AITHERZERO_ROOT -Parent }
                    elseif (Get-Command Get-AitherProjectRoot -ErrorAction SilentlyContinue) { Get-AitherProjectRoot }
                    else { Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent }
    $PYTHON_PATH_WIN = Join-Path $ProjectRoot "AitherOS\.venv\Scripts\python.exe"
    $PYTHON_PATH_NIX = Join-Path $ProjectRoot "AitherOS/.venv/bin/python"
    
    $PythonExe = if (Test-Path $PYTHON_PATH_WIN) { $PYTHON_PATH_WIN } else { $PYTHON_PATH_NIX }
    if (-not (Test-Path $PythonExe)) {
        # Fallback to system python if venv not found
        $PythonExe = "python"
    }
    $HelperScript = "$ProjectRoot\AitherZero\library\helpers\get_services_config.py"

    # --- Helper Functions ---
    
    function Get-AitherConfig {
        if (Test-Path $CACHE_FILE) {
            # simple cache check - if file is older than 1 hour, refresh
            $lastWrite = (Get-Item $CACHE_FILE).LastWriteTime
            if ($lastWrite -lt (Get-Date).AddHours(-1)) {
                Remove-Item $CACHE_FILE -ErrorAction SilentlyContinue
            } else {
                return (Get-Content $CACHE_FILE -Raw | ConvertFrom-Json)
            }
        }
        
        Write-Host " [AitherCLI] Refreshing service configuration..." -ForegroundColor DarkGray
        $output = & $PythonExe $HelperScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to load config: $output"
            return $null
        }
        $output | Out-File -FilePath $CACHE_FILE -Encoding utf8
        return ($output | ConvertFrom-Json)
    }

    function Get-ServicePort {
        param($Config, $ServiceName)
        # Normalize name (case insensitive)
        foreach ($key in $Config.services.PSObject.Properties.Name) {
            if ($key.ToLower() -eq $ServiceName.ToLower() -or "aither$($key.ToLower())" -eq $ServiceName.ToLower()) {
                return $Config.services.$key.port
            }
            # Check aliases
            $aliases = $Config.services.$key.aliases
            if ($aliases) {
                 foreach ($alias in $aliases) {
                    if ($alias.ToLower() -eq $ServiceName.ToLower()) {
                        return $Config.services.$key.port
                    }
                 }
            }
        }
        return $null
    }
    
    function Get-RealServiceName {
        param($Config, $ServiceName)
         foreach ($key in $Config.services.PSObject.Properties.Name) {
            if ($key.ToLower() -eq $ServiceName.ToLower() -or "aither$($key.ToLower())" -eq $ServiceName.ToLower()) {
                return $key
            }
             # Check aliases
            $aliases = $Config.services.$key.aliases
            if ($aliases) {
                 foreach ($alias in $aliases) {
                    if ($alias.ToLower() -eq $ServiceName.ToLower()) {
                        return $key
                    }
                 }
            }
        }
        return $ServiceName # Fallback
    }

    # --- Execution Logic ---

    $Config = Get-AitherConfig
    if (-not $Config) { return }

    switch -Regex ($Command.ToLower()) {
        '^help$' {
            Write-Host "AitherOS CLI (aither)" -ForegroundColor Cyan
            Write-Host "Usage: aither <command> [target] [args]"
            Write-Host ""
            Write-Host "Commands:"
            Write-Host "  list / services        List all configured services and ports"
            Write-Host "  status <svc>           Check health of a service"
            Write-Host "  logs <svc>             Tail logs for a service"
            Write-Host "  ports                  Dump all ports"
            Write-Host "  start <svc>            Start a service (Docker)"
            Write-Host "  stop <svc>             Stop a service (Docker)"
            Write-Host "  restart <svc>          Restart a service (Genesis API preferred)"
            Write-Host "  build <svc>            Build & restart a service (docker compose --build)"
            Write-Host "  rebuild <svc>          Full rebuild (no cache) & restart"
            Write-Host "  call <svc> <ep> [body] Call a service endpoint (GET or POST)"
            Write-Host "  clean-cache            Clear the CLI config cache"
        }

        '^clean-cache$' {
            Remove-Item $CACHE_FILE -ErrorAction SilentlyContinue
            Write-Host "Cache cleared." -ForegroundColor Green
        }

        '^(list|services)$' {
            $services = @()
            foreach ($prop in $Config.services.PSObject.Properties) {
                $s = $prop.Value
                $services += [PSCustomObject]@{
                    Service = $prop.Name
                    Port = $s.port
                    Group = $s.group
                    Description = $s.description
                }
            }
            $services | Format-Table -AutoSize
        }

        '^ports$' {
             $ports = @()
             foreach ($prop in $Config.services.PSObject.Properties) {
                $s = $prop.Value
                $ports += [PSCustomObject]@{
                    Service = $prop.Name
                    Port = $s.port
                }
            }
            $ports | Sort-Object Port | Format-Table -AutoSize
        }

        '^status$' {
            if (-not $Target) { Write-Error "Usage: aither status <service>"; return }
            $port = Get-ServicePort $Config $Target
            if (-not $port) { Write-Error "Service '$Target' not found."; return }
            
            $url = "http://localhost:$port/health"
            Write-Host "Checking $Target on $url ..." -ForegroundColor DarkGray
            try {
                $res = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 3
                $res
            } catch {
                Write-Warning "Service down or unreachable ($_)"
            }
        }

        '^call$' {
            if (-not $Target) { Write-Error "Usage: aither call <service> <endpoint> [json_body]"; return }
            $port = Get-ServicePort $Config $Target
            if (-not $port) { Write-Error "Service '$Target' not found."; return }
            
            # Arg1 is endpoint
            if (-not $Arg1) { $Arg1 = "/" }
            if (-not $Arg1.StartsWith("/")) { $Arg1 = "/$Arg1" }
            
            $url = "http://localhost:$port$Arg1"
            $method = if ($Arg2) { "Post" } else { "Get" }
            
            Write-Host "$method $url" -ForegroundColor DarkGray
            
            try {
                if ($method -eq "Post") {
                    $body = $Arg2
                    # If arg2 looks like a file, read it? No, keep it simple for now, expect JSON string
                    Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
                } else {
                    Invoke-RestMethod -Uri $url -Method Get
                }
            } catch {
                Write-Error $_
            }
        }

        '^restart$' {
             if (-not $Target) { Write-Error "Usage: aither restart <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             
             # Try Genesis first
             $genesisPort = Get-ServicePort $Config "Genesis"
             $url = "http://localhost:$genesisPort/services/$realName/restart"
             
             Write-Host "Requesting Genesis to restart $realName..." -ForegroundColor Cyan
             try {
                Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 5
                Write-Host "Restart signal sent." -ForegroundColor Green
             } catch {
                Write-Warning "Genesis unreachable. Fallback to Docker restart..."
                # Convert ServiceName to container-name
                # Usually AitherMoltbook -> aither-moltbook
                # or just look at format
                $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
                Write-Host "Docker restart $containerName..."
                docker restart $containerName
             }
        }

        '^stop$' {
             if (-not $Target) { Write-Error "Usage: aither stop <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
             docker stop $containerName
             Write-Host "Stopped $containerName" -ForegroundColor Yellow
        }

        '^start$' {
             if (-not $Target) { Write-Error "Usage: aither start <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
             docker start $containerName
             Write-Host "Started $containerName" -ForegroundColor Green
        }

        '^build$' {
             if (-not $Target) { Write-Error "Usage: aither build <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
             Write-Host "Building & restarting $containerName..." -ForegroundColor Cyan
             $cmdCtx = Get-AitherLiveContext
             $composeFile = Join-Path $ProjectRoot $cmdCtx.ComposeFile
             docker compose -f $composeFile up -d --build $containerName
             if ($LASTEXITCODE -eq 0) {
                 Write-Host "Build complete." -ForegroundColor Green
                 docker ps --filter "name=$containerName" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
             } else {
                 Write-Error "Build failed for $containerName"
             }
        }

        '^rebuild$' {
             if (-not $Target) { Write-Error "Usage: aither rebuild <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
             Write-Host "Full rebuild (no cache) for $containerName..." -ForegroundColor Yellow
             if (-not $cmdCtx) { $cmdCtx = Get-AitherLiveContext }
             $composeFile = Join-Path $ProjectRoot $cmdCtx.ComposeFile
             docker compose -f $composeFile build --no-cache $containerName
             if ($LASTEXITCODE -eq 0) {
                 docker compose -f $composeFile up -d $containerName
                 Write-Host "Rebuild complete." -ForegroundColor Green
                 docker ps --filter "name=$containerName" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
             } else {
                 Write-Error "Rebuild failed for $containerName"
             }
        }

        '^logs$' {
             if (-not $Target) { Write-Error "Usage: aither logs <service>"; return }
             $realName = Get-RealServiceName $Config $Target
             $containerName = "aither-" + $realName.ToLower().Replace("aither", "")
             
             # If Arg1 is provided, use as tail lines, else default to -f logic?
             # CLI tool usually blocks.
             docker logs -f $containerName
        }

        default {
            Write-Warning "Unknown command '$Command'. Try 'aither help'."
        }
    }
}

# Alias — exported by build.ps1
Set-Alias -Name aither -Value Invoke-AitherCmd -Scope Script
