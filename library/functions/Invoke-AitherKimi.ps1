<#
.SYNOPSIS
    AitherZero CLI commands for Kimi K2.5 elastic GPU cluster management
.DESCRIPTION
    Provides PowerShell commands to manage the Kimi K2.5 1 trillion parameter
    model cluster - wake, hibernate, scale, status, and run inference.
.EXAMPLE
    Invoke-AitherKimi -Action Status
    Invoke-AitherKimi -Action Wake -TargetNodes 2
    Invoke-AitherKimi -Action Hibernate
    Invoke-AitherKimi -Action Scale -TargetNodes 4
    Invoke-AitherKimi -Action Inference -Prompt "Explain quantum computing"
.NOTES
    Version: 1.0.0
    Author: Aitherium
#>

function Invoke-AitherKimi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('Status', 'Wake', 'Hibernate', 'Scale', 'Inference', 'Cost', 'Budget')]
        [string]$Action,

        [Parameter()]
        [int]$TargetNodes = 2,

        [Parameter()]
        [string]$Prompt,

        [Parameter()]
        [double]$Temperature = 0.7,

        [Parameter()]
        [int]$MaxTokens = 2048,

        [Parameter()]
        [ValidateSet('Unlimited', 'Conservative', 'Strict')]
        [string]$BudgetMode,

        [Parameter()]
        [double]$DailyLimit,

        [Parameter()]
        [double]$MonthlyLimit,

        [Parameter()]
        [switch]$Json,

        [Parameter()]
        [switch]$Watch
    )

    begin {
        $ComputeUrl = $env:AITHER_COMPUTE_URL ?? 'http://localhost:8168'
        $ClusterId = $env:KIMI_CLUSTER_ID ?? 'kimi-default'
        $BudgetFile = Join-Path $env:AITHERZERO_ROOT 'AitherOS/config/kimi-budget.json'
        
        function Write-KimiStatus {
            param($Status)
            
            $stateColors = @{
                'hibernated' = 'DarkGray'
                'provisioning' = 'Yellow'
                'warming' = 'Cyan'
                'active' = 'Green'
                'draining' = 'Magenta'
                'error' = 'Red'
            }
            
            $color = $stateColors[$Status.state] ?? 'White'
            
            Write-Host ""
            Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor $color
            Write-Host "║         KIMI K2.5 CLUSTER STATUS                             ║" -ForegroundColor $color
            Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor $color
            Write-Host ""
            
            Write-Host "  State:        " -NoNewline
            Write-Host $Status.state.ToUpper() -ForegroundColor $color
            
            Write-Host "  Active Nodes: " -NoNewline
            Write-Host "$($Status.active_nodes)/$($Status.total_nodes)" -ForegroundColor Cyan
            
            Write-Host "  GPU Util:     " -NoNewline
            $utilColor = if ($Status.avg_gpu_utilization -gt 80) { 'Red' } elseif ($Status.avg_gpu_utilization -gt 50) { 'Yellow' } else { 'Green' }
            Write-Host "$($Status.avg_gpu_utilization)%" -ForegroundColor $utilColor
            
            Write-Host "  Queue Depth:  " -NoNewline
            Write-Host $Status.queue_depth -ForegroundColor White
            
            Write-Host "  Cost/Hour:    " -NoNewline
            Write-Host "`$$($Status.cost_per_hour)" -ForegroundColor Yellow
            
            if ($Status.nodes -and $Status.nodes.Count -gt 0) {
                Write-Host ""
                Write-Host "  ┌─ Nodes ─────────────────────────────────────────────────┐" -ForegroundColor DarkGray
                foreach ($node in $Status.nodes) {
                    $nodeColor = if ($node.status -eq 'active') { 'Green' } elseif ($node.status -eq 'provisioning') { 'Yellow' } else { 'DarkGray' }
                    Write-Host "  │ " -NoNewline -ForegroundColor DarkGray
                    Write-Host "$($node.id.Substring(0,8))... " -NoNewline -ForegroundColor $nodeColor
                    Write-Host "$($node.provider) " -NoNewline -ForegroundColor White
                    Write-Host "$($node.gpu_type) " -NoNewline -ForegroundColor Cyan
                    Write-Host "[$($node.status)]" -ForegroundColor $nodeColor
                }
                Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
            }
            
            Write-Host ""
        }

        function Get-BudgetConfig {
            if (Test-Path $BudgetFile) {
                return Get-Content $BudgetFile | ConvertFrom-Json
            }
            return @{
                mode = 'Unlimited'
                daily_limit = 0
                monthly_limit = 0
                daily_spent = 0
                monthly_spent = 0
                last_reset_day = (Get-Date).Day
                last_reset_month = (Get-Date).Month
                alerts = @()
            }
        }

        function Save-BudgetConfig {
            param($Config)
            $Config | ConvertTo-Json -Depth 10 | Set-Content $BudgetFile
        }
    }

    process {
        try {
            switch ($Action) {
                'Status' {
                    $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/status" -Method Get -ErrorAction Stop
                    
                    if ($Json) {
                        $response | ConvertTo-Json -Depth 10
                    } elseif ($Watch) {
                        while ($true) {
                            Clear-Host
                            Write-KimiStatus $response
                            Write-Host "  [Watching - Press Ctrl+C to stop]" -ForegroundColor DarkGray
                            Start-Sleep -Seconds 5
                            $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/status" -Method Get -ErrorAction SilentlyContinue
                        }
                    } else {
                        Write-KimiStatus $response
                    }
                }

                'Wake' {
                    # Check budget before waking
                    $budget = Get-BudgetConfig
                    if ($budget.mode -eq 'Strict' -and $budget.daily_spent -ge $budget.daily_limit) {
                        Write-Host "❌ Daily budget limit reached (`$$($budget.daily_limit)). Cannot wake cluster." -ForegroundColor Red
                        return
                    }

                    Write-Host "🚀 Waking Kimi K2.5 cluster with $TargetNodes nodes..." -ForegroundColor Cyan
                    
                    $body = @{ target_nodes = $TargetNodes } | ConvertTo-Json
                    $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/wake" `
                        -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
                    
                    Write-Host "✅ Cluster wake initiated" -ForegroundColor Green
                    Write-Host "   Provisioning $TargetNodes node(s)..." -ForegroundColor DarkGray
                    Write-Host "   Model: Kimi K2.5 (1T params, 32B active)" -ForegroundColor DarkGray
                    Write-Host "   Estimated ready time: 3-5 minutes" -ForegroundColor DarkGray
                    
                    if ($Json) { $response | ConvertTo-Json -Depth 5 }
                }

                'Hibernate' {
                    Write-Host "💤 Hibernating Kimi K2.5 cluster..." -ForegroundColor Magenta
                    
                    $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/hibernate" `
                        -Method Post -ErrorAction Stop
                    
                    Write-Host "✅ Cluster hibernation initiated" -ForegroundColor Green
                    Write-Host "   Draining active requests..." -ForegroundColor DarkGray
                    Write-Host "   Nodes will be terminated after drain completes" -ForegroundColor DarkGray
                    Write-Host "   Hibernated cost: ~`$0.05/hr (storage only)" -ForegroundColor DarkGray
                    
                    if ($Json) { $response | ConvertTo-Json -Depth 5 }
                }

                'Scale' {
                    Write-Host "📊 Scaling Kimi K2.5 cluster to $TargetNodes nodes..." -ForegroundColor Yellow
                    
                    $body = @{ target_nodes = $TargetNodes } | ConvertTo-Json
                    $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/scale" `
                        -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
                    
                    Write-Host "✅ Scale operation initiated" -ForegroundColor Green
                    
                    if ($Json) { $response | ConvertTo-Json -Depth 5 }
                }

                'Inference' {
                    if (-not $Prompt) {
                        Write-Host "❌ -Prompt is required for inference" -ForegroundColor Red
                        return
                    }

                    # Check cluster status first
                    $status = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/status" -Method Get -ErrorAction SilentlyContinue
                    if ($status.state -eq 'hibernated') {
                        Write-Host "⚠️  Cluster is hibernated. Waking automatically..." -ForegroundColor Yellow
                        $wakeBody = @{ target_nodes = 2 } | ConvertTo-Json
                        Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/wake" `
                            -Method Post -Body $wakeBody -ContentType 'application/json' | Out-Null
                        
                        Write-Host "   Waiting for cluster to be ready..." -ForegroundColor DarkGray
                        do {
                            Start-Sleep -Seconds 10
                            $status = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/status" -Method Get -ErrorAction SilentlyContinue
                            Write-Host "   State: $($status.state)" -ForegroundColor DarkGray
                        } while ($status.state -notin @('active', 'error'))
                    }

                    Write-Host "🧠 Running inference..." -ForegroundColor Cyan
                    Write-Host "   Prompt: $($Prompt.Substring(0, [Math]::Min(50, $Prompt.Length)))..." -ForegroundColor DarkGray
                    
                    $body = @{
                        messages = @(
                            @{ role = 'user'; content = $Prompt }
                        )
                        temperature = $Temperature
                        max_tokens = $MaxTokens
                    } | ConvertTo-Json -Depth 5
                    
                    $response = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/inference" `
                        -Method Post -Body $body -ContentType 'application/json' -ErrorAction Stop
                    
                    Write-Host ""
                    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
                    Write-Host $response.choices[0].message.content -ForegroundColor White
                    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
                    Write-Host ""
                    Write-Host "   Tokens: $($response.usage.prompt_tokens) prompt + $($response.usage.completion_tokens) completion = $($response.usage.total_tokens) total" -ForegroundColor DarkGray
                    
                    # Update budget tracking
                    $budget = Get-BudgetConfig
                    $estimatedCost = ($response.usage.total_tokens / 1000000) * 0.60  # ~$0.60/1M tokens estimate
                    $budget.daily_spent += $estimatedCost
                    $budget.monthly_spent += $estimatedCost
                    Save-BudgetConfig $budget
                }

                'Cost' {
                    $status = Invoke-RestMethod -Uri "$ComputeUrl/api/v1/kimi/clusters/$ClusterId/status" -Method Get -ErrorAction SilentlyContinue
                    $budget = Get-BudgetConfig
                    
                    Write-Host ""
                    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
                    Write-Host "║         KIMI K2.5 COST SUMMARY                               ║" -ForegroundColor Yellow
                    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
                    Write-Host ""
                    
                    Write-Host "  Current Rate:   " -NoNewline
                    Write-Host "`$$($status.cost_per_hour ?? 0)/hour" -ForegroundColor Cyan
                    
                    Write-Host "  Daily Spent:    " -NoNewline
                    $dailyColor = if ($budget.daily_limit -gt 0 -and $budget.daily_spent -ge $budget.daily_limit * 0.8) { 'Red' } else { 'Green' }
                    Write-Host ("`${0:N2}" -f $budget.daily_spent) -ForegroundColor $dailyColor
                    
                    Write-Host "  Monthly Spent:  " -NoNewline
                    $monthlyColor = if ($budget.monthly_limit -gt 0 -and $budget.monthly_spent -ge $budget.monthly_limit * 0.8) { 'Red' } else { 'Green' }
                    Write-Host ("`${0:N2}" -f $budget.monthly_spent) -ForegroundColor $monthlyColor
                    
                    Write-Host ""
                    Write-Host "  ┌─ Estimates ───────────────────────────────────────────────┐" -ForegroundColor DarkGray
                    Write-Host "  │ HIBERNATED:     ~`$0.05/hr   (`$1.20/day)                  │" -ForegroundColor DarkGray
                    Write-Host "  │ WARM_STANDBY:   ~`$2-4/hr    (`$48-96/day)                 │" -ForegroundColor DarkGray
                    Write-Host "  │ ACTIVE (2 GPU): ~`$8-16/hr   (`$192-384/day)               │" -ForegroundColor DarkGray
                    Write-Host "  │ BURST (4+ GPU): ~`$16-32/hr  (`$384-768/day)               │" -ForegroundColor DarkGray
                    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkGray
                    Write-Host ""
                }

                'Budget' {
                    $budget = Get-BudgetConfig
                    
                    if ($BudgetMode) {
                        $budget.mode = $BudgetMode
                        Write-Host "✅ Budget mode set to: $BudgetMode" -ForegroundColor Green
                    }
                    
                    if ($DailyLimit -gt 0) {
                        $budget.daily_limit = $DailyLimit
                        Write-Host "✅ Daily limit set to: `$$DailyLimit" -ForegroundColor Green
                    }
                    
                    if ($MonthlyLimit -gt 0) {
                        $budget.monthly_limit = $MonthlyLimit
                        Write-Host "✅ Monthly limit set to: `$$MonthlyLimit" -ForegroundColor Green
                    }
                    
                    Save-BudgetConfig $budget
                    
                    # Display current budget
                    Write-Host ""
                    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
                    Write-Host "║         KIMI K2.5 BUDGET CONFIGURATION                       ║" -ForegroundColor Magenta
                    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
                    Write-Host ""
                    
                    $modeColor = switch ($budget.mode) {
                        'Unlimited' { 'Green' }
                        'Conservative' { 'Yellow' }
                        'Strict' { 'Red' }
                        default { 'White' }
                    }
                    
                    Write-Host "  Mode:           " -NoNewline
                    Write-Host $budget.mode -ForegroundColor $modeColor
                    
                    Write-Host "  Daily Limit:    " -NoNewline
                    if ($budget.daily_limit -gt 0) {
                        Write-Host "`$$($budget.daily_limit)" -ForegroundColor Cyan
                    } else {
                        Write-Host "Unlimited" -ForegroundColor Green
                    }
                    
                    Write-Host "  Monthly Limit:  " -NoNewline
                    if ($budget.monthly_limit -gt 0) {
                        Write-Host "`$$($budget.monthly_limit)" -ForegroundColor Cyan
                    } else {
                        Write-Host "Unlimited" -ForegroundColor Green
                    }
                    
                    Write-Host ""
                    Write-Host "  Budget Modes:" -ForegroundColor DarkGray
                    Write-Host "    Unlimited    - No restrictions" -ForegroundColor DarkGray
                    Write-Host "    Conservative - Warn at 80% of limit" -ForegroundColor DarkGray
                    Write-Host "    Strict       - Block operations at limit" -ForegroundColor DarkGray
                    Write-Host ""
                }
            }
        }
        catch {
            if ($_.Exception.Message -match 'Unable to connect') {
                Write-Host "⚠️  Cannot connect to AitherCompute at $ComputeUrl" -ForegroundColor Yellow
                Write-Host "   Is the compute service running?" -ForegroundColor DarkGray
                Write-Host "   Start with: python -m lib.compute" -ForegroundColor DarkGray
            }
            else {
                Write-Host "❌ Error: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# Aliases for convenience
Set-Alias -Name kimi -Value Invoke-AitherKimi -Scope Global

# Export the function
Export-ModuleMember -Function Invoke-AitherKimi -Alias kimi
