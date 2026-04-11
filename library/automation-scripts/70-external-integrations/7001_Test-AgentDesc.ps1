<#
.SYNOPSIS
    Test AgentDesc integration and browse available tasks
    
.DESCRIPTION
    Tests the AgentDesc skill integration and shows available tasks.
    
.PARAMETER CheckStatus
    Check your agent's status on AgentDesc
    
.PARAMETER ListTasks
    List available tasks
    
.PARAMETER Category
    Filter tasks by category (coding, research, writing, etc.)
    
.PARAMETER MinBudget
    Minimum task budget in USD
    
.EXAMPLE
    .\7001_Test-AgentDesc.ps1 -CheckStatus
    
.EXAMPLE
    .\7001_Test-AgentDesc.ps1 -ListTasks -Category coding -MinBudget 50
#>

[CmdletBinding()]
param(
    [switch]$CheckStatus,
    [switch]$ListTasks,
    [string]$Category = "",
    [decimal]$MinBudget = 0
)

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "    AgentDesc Integration Test" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Check if API key is configured
$apiKey = $env:AGENTDESC_API_KEY
if (-not $apiKey) {
    $envFile = Join-Path $projectRoot ".env"
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        if ($envContent -match 'AGENTDESC_API_KEY=(.+)') {
            $apiKey = $matches[1].Trim()
        }
    }
}

if (-not $apiKey) {
    Write-Host "✗ AGENTDESC_API_KEY not configured" -ForegroundColor Red
    Write-Host ""
    Write-Host "Run setup first:" -ForegroundColor Yellow
    Write-Host "  .\7000_Setup-AgentDesc.ps1 -Register -StartService" -ForegroundColor Gray
    exit 1
}

Write-Host "✓ API Key configured" -ForegroundColor Green
Write-Host ""

# Check if service is running
Write-Host "Checking AitherSkills service..." -ForegroundColor Cyan
try {
    $health = Invoke-RestMethod -Uri "http://localhost:8780/health" -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  ✓ Service is running" -ForegroundColor Green
    Write-Host "  Skills loaded: $($health.skills_loaded)" -ForegroundColor Gray
} catch {
    Write-Host "  ✗ Service not responding" -ForegroundColor Red
    Write-Host "  Start it: docker compose -f docker-compose.aitheros.yml up -d aither-skills" -ForegroundColor Gray
    exit 1
}

Write-Host ""

# Check agent status
if ($CheckStatus -or (-not $ListTasks)) {
    Write-Host "═══ Agent Status ═══" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $headers = @{
            "Authorization" = "Bearer $apiKey"
        }
        
        $status = Invoke-RestMethod -Uri "https://agentdesc.com/api/agents/status" `
            -Headers $headers `
            -TimeoutSec 10 `
            -ErrorAction Stop
        
        Write-Host "  Agent ID: $($status.agent.id)" -ForegroundColor White
        Write-Host "  Name: $($status.agent.name)" -ForegroundColor White
        Write-Host "  Verified: $(if ($status.agent.verified) { '✓ Yes' } else { '✗ No - Please verify at claim URL' })" -ForegroundColor $(if ($status.agent.verified) { 'Green' } else { 'Yellow' })
        Write-Host ""
        Write-Host "  Tasks claimed: $($status.stats.tasks_claimed)" -ForegroundColor Gray
        Write-Host "  Tasks completed: $($status.stats.tasks_completed)" -ForegroundColor Gray
        Write-Host "  Total earned: `$$($status.stats.total_earned)" -ForegroundColor Green
        Write-Host "  Success rate: $($status.stats.success_rate)%" -ForegroundColor Gray
        
    } catch {
        Write-Host "  ✗ Failed to get status: $($_.Exception.Message)" -ForegroundColor Red
        
        if ($_.Exception.Message -like "*401*" -or $_.Exception.Message -like "*Unauthorized*") {
            Write-Host "  API key may be invalid. Please re-run setup." -ForegroundColor Yellow
        }
    }
}

# List available tasks
if ($ListTasks -or (-not $CheckStatus)) {
    Write-Host ""
    Write-Host "═══ Available Tasks ═══" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        $headers = @{
            "Authorization" = "Bearer $apiKey"
        }
        
        $uri = "https://agentdesc.com/api/tasks?status=open"
        if ($Category) {
            $uri += "&category=$Category"
        }
        
        $tasks = Invoke-RestMethod -Uri $uri `
            -Headers $headers `
            -TimeoutSec 10 `
            -ErrorAction Stop
        
        # Filter by budget
        if ($MinBudget -gt 0) {
            $tasks.tasks = $tasks.tasks | Where-Object { $_.budget -ge $MinBudget }
        }
        
        if ($tasks.tasks.Count -eq 0) {
            Write-Host "  No tasks available matching your criteria." -ForegroundColor Yellow
        } else {
            Write-Host "  Found $($tasks.tasks.Count) tasks:" -ForegroundColor Gray
            Write-Host ""
            
            foreach ($task in $tasks.tasks | Select-Object -First 10) {
                Write-Host "  ┌─ $($task.title)" -ForegroundColor White
                Write-Host "  │  Budget: `$$($task.budget)  Category: $($task.category)" -ForegroundColor Gray
                Write-Host "  │  ID: $($task.id)" -ForegroundColor DarkGray
                
                if ($task.description.Length -gt 100) {
                    Write-Host "  │  $($task.description.Substring(0, 100))..." -ForegroundColor Gray
                } else {
                    Write-Host "  │  $($task.description)" -ForegroundColor Gray
                }
                
                Write-Host "  │  Posted: $($task.posted_at)" -ForegroundColor DarkGray
                Write-Host "  └─" -ForegroundColor DarkGray
                Write-Host ""
            }
            
            if ($tasks.tasks.Count -gt 10) {
                Write-Host "  ... and $($tasks.tasks.Count - 10) more tasks" -ForegroundColor Gray
                Write-Host ""
            }
            
            # Show summary
            Write-Host "Task Summary:" -ForegroundColor Cyan
            $totalBudget = ($tasks.tasks | Measure-Object -Property budget -Sum).Sum
            $avgBudget = ($tasks.tasks | Measure-Object -Property budget -Average).Average
            
            Write-Host "  Total budget available: `$$totalBudget" -ForegroundColor Green
            Write-Host "  Average per task: `$$([math]::Round($avgBudget, 2))" -ForegroundColor Gray
            
            # Category breakdown
            $categories = $tasks.tasks | Group-Object -Property category | Sort-Object Count -Descending
            Write-Host "  Categories:" -ForegroundColor Gray
            foreach ($cat in $categories | Select-Object -First 5) {
                Write-Host "    - $($cat.Name): $($cat.Count) tasks" -ForegroundColor DarkGray
            }
        }
        
    } catch {
        Write-Host "  ✗ Failed to list tasks: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Summary and next steps
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  • Enable automation to auto-claim tasks" -ForegroundColor Gray
Write-Host "  • View full integration guide: docs\AGENTDESC-INTEGRATION.md" -ForegroundColor Gray
Write-Host "  • Check service logs: docker logs aither-skills" -ForegroundColor Gray
Write-Host ""
