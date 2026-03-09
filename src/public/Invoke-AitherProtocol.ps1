function Invoke-AitherProtocol {
    <#
    .SYNOPSIS
        Protocol handler for aither:// URLs

    .DESCRIPTION
        Handles deep links from browser/notifications/shortcuts:
        - aither://dashboard
        - aither://service/{name}/restart
        - aither://logs/{service}
        - aither://agent/{name}/ask?q={query}
        - aither://tools/{category}/{action}

    .PARAMETER Uri
        The aither:// URI to handle

    .EXAMPLE
        Invoke-AitherProtocol "aither://service/moltbook/restart"

    .EXAMPLE
        Invoke-AitherProtocol "aither://dashboard"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Uri
    )

    process {
        # Helper for toast notifications (BurntToast)
        function Send-ProtocolNotification {
            param($Title, $Message, $Type = 'Info')
            if (-not (Get-Module BurntToast -ErrorAction SilentlyContinue)) {
                if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
                    Import-Module BurntToast -ErrorAction SilentlyContinue
                }
            }
            if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
                $emoji = @{ Info = 'ℹ️'; Success = '✅'; Warning = '⚠️'; Error = '❌' }[$Type]
                $iconPath = Join-Path $script:ProjectRoot 'assets/icons/aitheros-logo.png'
                $params = @{ Text = @("$emoji $Title", $Message) }
                if (Test-Path $iconPath) { $params.AppLogo = $iconPath }
                New-BurntToastNotification @params
            }
            else {
                # Fallback to Write-Host
                $prefix = @{ Info = '[i]'; Success = '[OK]'; Warning = '[!]'; Error = '[X]' }[$Type]
                Write-Host "$prefix $Title - $Message" -ForegroundColor $(
                    @{ Info = 'Cyan'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }[$Type]
                )
            }
        }

        try {
            # Clean URI
            $Uri = $Uri.Trim('"', "'", ' ')

    # Resolve project context for URLs
    $ctx = Get-AitherLiveContext
    $dashboardBase = "http://localhost:3000"
    $orchestratorBase = $ctx.OrchestratorURL
    $prefix = $ctx.ContainerPrefix

    # Parse URI
    Add-Type -AssemblyName System.Web
    $parsed = [System.Uri]::new($Uri)
    $action = $parsed.Host
    $pathParts = $parsed.AbsolutePath.Trim('/') -split '/'
    $query = [System.Web.HttpUtility]::ParseQueryString($parsed.Query)

    Write-Host "Handling: $Uri" -ForegroundColor Cyan
    Write-Host "  Action: $action, Path: $($pathParts -join '/'), Query: $($parsed.Query)" -ForegroundColor Gray

    switch ($action) {
        'dashboard' {
            Start-Process $dashboardBase
            Send-ProtocolNotification "Dashboard" "Opening dashboard..."
        }

        'service' {
            $serviceName = $pathParts[0]
            $operation = if ($pathParts.Count -gt 1) { $pathParts[1] } else { 'status' }

            switch ($operation) {
                'restart' {
                    Send-ProtocolNotification "Restarting" "$serviceName is restarting..." "Info"
                    try {
                        if ($orchestratorBase) {
                            $result = Invoke-RestMethod -Uri "$orchestratorBase/api/services/$serviceName/restart" -Method POST -TimeoutSec 30
                            Send-ProtocolNotification "Restarted" "$serviceName restart initiated" "Success"
                        } else { throw "No orchestrator configured" }
                    }
                    catch {
                        $containerName = "$prefix-$($serviceName.ToLower() -replace $prefix, '')"
                        docker restart $containerName 2>&1 | Out-Null
                        Send-ProtocolNotification "Restarted" "$serviceName restarted via Docker" "Success"
                    }
                }
                'stop' {
                    docker stop "$prefix-$($serviceName.ToLower() -replace $prefix, '')" 2>&1 | Out-Null
                    Send-ProtocolNotification "Stopped" "$serviceName stopped" "Warning"
                }
                'start' {
                    docker start "$prefix-$($serviceName.ToLower() -replace $prefix, '')" 2>&1 | Out-Null
                    Send-ProtocolNotification "Started" "$serviceName started" "Success"
                }
                'logs' {
                    Start-Process "$dashboardBase/logs?service=$serviceName"
                }
                'status' {
                    try {
                        if (-not $orchestratorBase) { throw "No orchestrator configured" }
                        $health = Invoke-RestMethod -Uri "$orchestratorBase/services/$serviceName/health" -TimeoutSec 5
                        Send-ProtocolNotification "$serviceName Status" "Status: $($health.status)" "Success"
                    }
                    catch {
                        Send-ProtocolNotification "$serviceName Status" "Unable to reach service" "Error"
                    }
                }
            }
        }

        'logs' {
            $serviceName = $pathParts[0]
            if ($serviceName) {
                Start-Process "$dashboardBase/logs?service=$serviceName"
            } else {
                Start-Process "$dashboardBase/logs"
            }
        }

        'agent' {
            $agentName = $pathParts[0]
            $agentAction = if ($pathParts.Count -gt 1) { $pathParts[1] } else { 'chat' }
            $queryText = $query['q']

            switch ($agentAction) {
                'ask' {
                    if ($queryText) {
                        Start-Process "$dashboardBase/chat?agent=$agentName&q=$([uri]::EscapeDataString($queryText))"
                    }
                }
                'chat' {
                    Start-Process "$dashboardBase/chat?agent=$agentName"
                }
                default {
                    Start-Process "$dashboardBase/chat?agent=$agentName"
                }
            }
        }
        
        'vision' {
            $visionAction = $pathParts[0]
            $filePath = $query['file']
            
            switch ($visionAction) {
                'analyze' {
                    Send-ProtocolNotification "AitherVision" "Analyzing image..." "Info"
                    # TODO: Call vision service
                }
                'ocr' {
                    Send-ProtocolNotification "AitherVision" "Extracting text..." "Info"
                    # TODO: Call OCR service
                }
            }
        }
        
        'rag' {
            $ragAction = $pathParts[0]
            $filePath = $query['file']
            
            switch ($ragAction) {
                'index' {
                    Send-ProtocolNotification "RAG Index" "Indexing document..." "Info"
                    # TODO: Call RAG indexing
                }
                'search' {
                    $searchQuery = $query['q']
                    Start-Process "$dashboardBase/search?q=$([uri]::EscapeDataString($searchQuery))"
                }
            }
        }
        
        'tools' {
            $category = $pathParts[0]
            $tool = if ($pathParts.Count -gt 1) { $pathParts[1] } else { '' }
            
            switch ($category) {
                'json' {
                    switch ($tool) {
                        'validate' {
                            $clipboard = Get-Clipboard
                            try {
                                $null = $clipboard | ConvertFrom-Json
                                Send-ProtocolNotification "JSON Valid" "The JSON is valid ✓" "Success"
                            }
                            catch {
                                Send-ProtocolNotification "JSON Invalid" $_.Exception.Message "Error"
                            }
                        }
                        'format' {
                            $clipboard = Get-Clipboard
                            try {
                                $formatted = $clipboard | ConvertFrom-Json | ConvertTo-Json -Depth 10
                                Set-Clipboard $formatted
                                Send-ProtocolNotification "JSON Formatted" "Pretty JSON copied to clipboard" "Success"
                            }
                            catch {
                                Send-ProtocolNotification "Format Failed" $_.Exception.Message "Error"
                            }
                        }
                    }
                }
                'code' {
                    switch ($tool) {
                        'lint' {
                            Send-ProtocolNotification "Code Lint" "Linting code..." "Info"
                        }
                    }
                }
            }
        }
        
        'settings' {
            Start-Process "$dashboardBase/settings"
        }
        
        'health' {
            try {
                if (-not $orchestratorBase) { throw "No orchestrator configured" }
                $health = Invoke-RestMethod -Uri "$orchestratorBase/health-check" -TimeoutSec 10
                $healthy = ($health.services | Where-Object { $_.status -eq 'healthy' }).Count
                $total = $health.services.Count
                $status = if ($healthy -eq $total) { 'Success' } else { 'Warning' }
                Send-ProtocolNotification "System Health" "$healthy of $total services healthy" $status
            }
            catch {
                Send-ProtocolNotification "Health Check" "Could not reach orchestrator" "Error"
            }
        }
        
        'deploy' {
            Send-ProtocolNotification "Deploying" "Starting services..." "Info"
            $genesisScript = Join-Path $script:ProjectRoot "start_genesis.ps1"
            if ($IsWindows) {
                Start-Process pwsh -ArgumentList "-NoExit", "-File", $genesisScript
            } else {
                # Linux/Mac
                Start-Process pwsh -ArgumentList "-File", $genesisScript
            }
        }

        'inspect' {
            # Deep investigation: opens logs + dashboard + status in one click
            $serviceName = $pathParts[0]
            if ($serviceName) {
                $containerName = "$prefix-$($serviceName.ToLower() -replace $prefix, '')"

                # Open dashboard log page
                Start-Process "$dashboardBase/logs?service=$serviceName"
                
                # Open a terminal with live docker logs
                $wt = Get-Command wt -ErrorAction SilentlyContinue
                if ($wt) {
                    Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$serviceName inspect", "docker", "logs", "-f", "--tail", "200", $containerName
                }
                else {
                    Start-Process pwsh -ArgumentList "-NoExit", "-Command", "docker logs -f --tail 200 $containerName"
                }
                
                # Show quick status notification
                try {
                    $inspect = docker inspect --format '{{.State.Status}} (exit {{.State.ExitCode}})' $containerName 2>&1
                    Send-ProtocolNotification "🔍 $serviceName" "Container: $inspect" "Info"
                }
                catch {
                    Send-ProtocolNotification "🔍 $serviceName" "Container not found" "Warning"
                }
            }
            else {
                Start-Process "$dashboardBase/monitoring"
            }
        }
        
        'container' {
            # Direct Docker container operations
            $containerName = $pathParts[0]
            $containerAction = if ($pathParts.Count -gt 1) { $pathParts[1] } else { 'logs' }
            
            if (-not $containerName) {
                Send-ProtocolNotification "Container" "No container specified" "Warning"
            }
            else {
                switch ($containerAction) {
                    'logs' {
                        $wt = Get-Command wt -ErrorAction SilentlyContinue
                        if ($wt) {
                            Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$containerName logs", "docker", "logs", "-f", "--tail", "200", $containerName
                        }
                        else {
                            Start-Process pwsh -ArgumentList "-NoExit", "-Command", "docker logs -f --tail 200 $containerName"
                        }
                    }
                    'exec' {
                        $wt = Get-Command wt -ErrorAction SilentlyContinue
                        if ($wt) {
                            Start-Process wt -ArgumentList "-w", "aither", "nt", "--title", "$containerName shell", "docker", "exec", "-it", $containerName, "/bin/sh"
                        }
                        else {
                            Start-Process pwsh -ArgumentList "-NoExit", "-Command", "docker exec -it $containerName /bin/sh"
                        }
                    }
                    'restart' {
                        docker restart $containerName 2>&1 | Out-Null
                        Send-ProtocolNotification "Container Restarted" "$containerName restarted" "Success"
                    }
                    'status' {
                        try {
                            $state = docker inspect --format '{{json .State}}' $containerName 2>&1 | ConvertFrom-Json
                            $msg = "Status: $($state.Status), Running: $($state.Running), ExitCode: $($state.ExitCode)"
                            $sev = if ($state.Running) { 'Success' } else { 'Error' }
                            Send-ProtocolNotification "$containerName Status" $msg $sev
                        }
                        catch {
                            Send-ProtocolNotification "$containerName" "Could not inspect container" "Error"
                        }
                    }
                }
            }
        }
        
        default {
            Send-ProtocolNotification "Unknown Action" "aither://$action not recognized" "Warning"
        }
    }
}
catch {
    Send-ProtocolNotification "Protocol Error" $_.Exception.Message "Error"
    Write-Error $_
}
    } # end process
} # end function
