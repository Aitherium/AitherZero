<#
.SYNOPSIS
    Aither Protocol Handler (aither://)

.DESCRIPTION
    Handles aither:// URLs invoked from notifications, browser, or other sources.
    
    Supported commands:
    - aither://restart/{service}  - Restart a Docker service
    - aither://stop/{service}     - Stop a Docker service  
    - aither://start/{service}    - Start a Docker service
    - aither://logs/{service}     - Open service logs in terminal
    - aither://open/{page}        - Open dashboard page
    - aither://run/{routine}      - Trigger a scheduler routine
    - aither://chat/{message}     - Open chat with message
    - aither://analyze/{path}     - Analyze a file
    - aither://status             - Show service status notification

.PARAMETER Uri
    The aither:// URI to handle

.EXAMPLE
    .\Invoke-AitherProtocol.ps1 "aither://restart/moltbook"
    
.EXAMPLE
    .\Invoke-AitherProtocol.ps1 "aither://logs/pulse"

.NOTES
    This script is registered as the aither:// protocol handler.
    Called automatically when aither:// links are clicked.
#>

param(
    [Parameter(Position = 0)]
    [string]$Uri
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$DASHBOARD_URL = "http://localhost:3000"
$SCHEDULER_URL = "http://localhost:8109"
$GENESIS_URL = "http://localhost:8001"

# ============================================================================
# PARSE URI
# ============================================================================

if (-not $Uri -or $Uri -notmatch '^aither://') {
    Write-Warning "Invalid or missing aither:// URI: $Uri"
    exit 1
}

# Parse: aither://command/arg1/arg2?param=value
$parsedUri = [System.Uri]$Uri
$command = $parsedUri.Host
$pathParts = $parsedUri.AbsolutePath.Trim('/').Split('/')
$queryParams = [System.Web.HttpUtility]::ParseQueryString($parsedUri.Query)

# First path segment is the primary argument
$primaryArg = if ($pathParts.Count -gt 0) { $pathParts[0] } else { $null }
$secondaryArgs = if ($pathParts.Count -gt 1) { $pathParts[1..($pathParts.Count - 1)] } else { @() }

Write-Verbose "Aither Protocol Handler"
Write-Verbose "  Command: $command"
Write-Verbose "  Primary Arg: $primaryArg"
Write-Verbose "  Secondary Args: $($secondaryArgs -join ', ')"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Send-Notification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Severity = 'Info'
    )
    
    $notifyScript = Join-Path $PSScriptRoot "Send-AitherNotification.ps1"
    if (Test-Path $notifyScript) {
        & $notifyScript -Title $Title -Message $Message -Severity $Severity
    }
    else {
        # Fallback to basic notification
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, $Title)
    }
}

function Get-ServiceContainerName {
    param([string]$ServiceId)
    
    # Map service ID to container name
    $containerName = "aither-$($ServiceId.ToLower())"
    return $containerName
}

# ============================================================================
# COMMAND HANDLERS
# ============================================================================

switch ($command) {
    'restart' {
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No service specified for restart" -Severity Error
            exit 1
        }
        
        $containerName = Get-ServiceContainerName $primaryArg
        Write-Host "🔄 Restarting service: $primaryArg ($containerName)"
        
        try {
            $result = docker restart $containerName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Send-Notification -Title "Service Restarted" -Message "$primaryArg is restarting..." -Severity Info
            }
            else {
                Send-Notification -Title "Restart Failed" -Message "Could not restart $primaryArg`n$result" -Severity Error
            }
        }
        catch {
            Send-Notification -Title "Restart Error" -Message $_.Exception.Message -Severity Error
        }
    }
    
    'stop' {
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No service specified" -Severity Error
            exit 1
        }
        
        $containerName = Get-ServiceContainerName $primaryArg
        Write-Host "⏹️ Stopping service: $primaryArg"
        
        docker stop $containerName
        Send-Notification -Title "Service Stopped" -Message "$primaryArg has been stopped" -Severity Warning
    }
    
    'start' {
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No service specified" -Severity Error
            exit 1
        }
        
        $containerName = Get-ServiceContainerName $primaryArg
        Write-Host "▶️ Starting service: $primaryArg"
        
        docker start $containerName
        Send-Notification -Title "Service Started" -Message "$primaryArg is starting..." -Severity Info
    }
    
    'logs' {
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No service specified" -Severity Error
            exit 1
        }
        
        $containerName = Get-ServiceContainerName $primaryArg
        $lines = if ($queryParams['lines']) { $queryParams['lines'] } else { 100 }
        
        # Open in Windows Terminal if available
        $wt = Get-Command wt -ErrorAction SilentlyContinue
        if ($wt) {
            Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$primaryArg logs", "docker", "logs", "-f", "--tail", $lines, $containerName
        }
        else {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "docker logs -f --tail $lines $containerName"
        }
    }
    
    'open' {
        $page = if ($primaryArg) { $primaryArg } else { "" }
        $url = "$DASHBOARD_URL/$page"
        
        Write-Host "🌐 Opening: $url"
        Start-Process $url
    }
    
    'run' {
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No routine specified" -Severity Error
            exit 1
        }
        
        $routineName = $primaryArg
        Write-Host "▶️ Triggering routine: $routineName"
        
        try {
            $response = Invoke-RestMethod -Uri "$SCHEDULER_URL/routines/$routineName/trigger" -Method POST -TimeoutSec 10
            Send-Notification -Title "Routine Triggered" -Message "Started: $routineName" -Severity Info
        }
        catch {
            Send-Notification -Title "Routine Failed" -Message "Could not trigger $routineName`n$($_.Exception.Message)" -Severity Error
        }
    }
    
    'chat' {
        $message = if ($primaryArg) { [System.Uri]::UnescapeDataString($primaryArg) } else { "" }
        $chatUrl = "$DASHBOARD_URL/chat"
        if ($message) {
            $chatUrl += "?message=$([System.Uri]::EscapeDataString($message))"
        }
        
        Write-Host "💬 Opening chat: $chatUrl"
        Start-Process $chatUrl
    }
    
    'analyze' {
        $filePath = if ($primaryArg) { [System.Uri]::UnescapeDataString($primaryArg) } else { "" }
        
        if (-not $filePath -or -not (Test-Path $filePath)) {
            Send-Notification -Title "Error" -Message "File not found: $filePath" -Severity Error
            exit 1
        }
        
        # TODO: Call AitherVision/AitherMind to analyze
        $analyzeUrl = "$DASHBOARD_URL/analyze?file=$([System.Uri]::EscapeDataString($filePath))"
        Start-Process $analyzeUrl
    }
    
    'status' {
        Write-Host "📊 Checking service status..."
        
        try {
            # Get service status from Genesis
            $response = Invoke-RestMethod -Uri "$GENESIS_URL/services" -TimeoutSec 5
            $services = $response.services
            
            if ($services) {
                $online = ($services.PSObject.Properties | Where-Object { $_.Value.status -eq 'online' }).Count
                $total = $services.PSObject.Properties.Count
                
                $severity = if ($online -eq $total) { 'Info' } elseif ($online -gt $total / 2) { 'Warning' } else { 'Error' }
                Send-Notification -Title "AitherOS Status" -Message "$online / $total services online" -Severity $severity
            }
            else {
                Send-Notification -Title "AitherOS Status" -Message "Could not get service status" -Severity Warning
            }
        }
        catch {
            Send-Notification -Title "AitherOS Status" -Message "Genesis unavailable: $($_.Exception.Message)" -Severity Error
        }
    }
    
    'inspect' {
        # Deep investigation: opens logs + dashboard + container status at once
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No service specified for inspect" -Severity Error
            exit 1
        }
        
        $containerName = Get-ServiceContainerName $primaryArg
        Write-Host "🔍 Inspecting service: $primaryArg ($containerName)"
        
        # Open dashboard log page
        Start-Process "$DASHBOARD_URL/logs?service=$primaryArg"
        
        # Open a terminal with live docker logs
        $wt = Get-Command wt -ErrorAction SilentlyContinue
        if ($wt) {
            Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$primaryArg inspect", "docker", "logs", "-f", "--tail", "200", $containerName
        }
        else {
            Start-Process powershell -ArgumentList "-NoExit", "-Command", "docker logs -f --tail 200 $containerName"
        }
        
        # Show quick status notification
        try {
            $state = docker inspect --format '{{json .State}}' $containerName 2>&1 | ConvertFrom-Json
            $msg = "Status: $($state.Status) | Exit: $($state.ExitCode) | PID: $($state.Pid)"
            $sev = if ($state.Running) { 'Info' } else { 'Error' }
            Send-Notification -Title "🔍 $primaryArg" -Message $msg -Severity $sev
        }
        catch {
            Send-Notification -Title "🔍 $primaryArg" -Message "Container not found or not inspectable" -Severity Warning
        }
    }
    
    'container' {
        # Direct Docker container operations by name
        if (-not $primaryArg) {
            Send-Notification -Title "Error" -Message "No container name specified" -Severity Error
            exit 1
        }
        
        $action = if ($secondaryArgs.Count -gt 0) { $secondaryArgs[0] } else { 'logs' }
        
        switch ($action) {
            'logs' {
                $lines = if ($queryParams['lines']) { $queryParams['lines'] } else { 200 }
                $wt = Get-Command wt -ErrorAction SilentlyContinue
                if ($wt) {
                    Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$primaryArg logs", "docker", "logs", "-f", "--tail", $lines, $primaryArg
                }
                else {
                    Start-Process powershell -ArgumentList "-NoExit", "-Command", "docker logs -f --tail $lines $primaryArg"
                }
            }
            'exec' {
                $wt = Get-Command wt -ErrorAction SilentlyContinue
                if ($wt) {
                    Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$primaryArg shell", "docker", "exec", "-it", $primaryArg, "/bin/sh"
                }
                else {
                    Start-Process powershell -ArgumentList "-NoExit", "-Command", "docker exec -it $primaryArg /bin/sh"
                }
            }
            'restart' {
                docker restart $primaryArg 2>&1 | Out-Null
                Send-Notification -Title "Container Restarted" -Message "$primaryArg was restarted" -Severity Info
            }
            'status' {
                try {
                    $state = docker inspect --format '{{json .State}}' $primaryArg 2>&1 | ConvertFrom-Json
                    $msg = "Status: $($state.Status) | Running: $($state.Running) | Exit: $($state.ExitCode)"
                    $sev = if ($state.Running) { 'Info' } else { 'Error' }
                    Send-Notification -Title "$primaryArg" -Message $msg -Severity $sev
                }
                catch {
                    Send-Notification -Title "$primaryArg" -Message "Could not inspect container" -Severity Error
                }
            }
        }
    }
    
    default {
        Write-Warning "Unknown aither:// command: $command"
        Send-Notification -Title "Unknown Command" -Message "aither://$command is not recognized" -Severity Warning
        
        # Open dashboard as fallback
        Start-Process $DASHBOARD_URL
    }
}

Write-Host "✅ Protocol handler completed for: $Uri"
