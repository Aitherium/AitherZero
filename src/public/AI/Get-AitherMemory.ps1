#Requires -Version 7.0

<#
.SYNOPSIS
    Queries the AitherOS MemoryGraph for agent memories and episodic recall.

.DESCRIPTION
    Connects to the AitherOS memory subsystem to query the MemoryGraph store,
    enabling persistent context across CLI sessions. Supports semantic search,
    agent-specific recall, and episodic memory queries.

.PARAMETER Query
    Natural language query to search memories semantically.

.PARAMETER Agent
    Filter memories by agent identity (e.g., 'demiurge', 'athena', 'aither').

.PARAMETER Type
    Memory type filter: episodic, semantic, procedural, or all. Defaults to all.

.PARAMETER Limit
    Maximum number of results to return. Defaults to 10.

.PARAMETER Since
    Only return memories created after this date.

.PARAMETER GenesisUrl
    URL of the Genesis service. Defaults to http://localhost:8001.

.EXAMPLE
    Get-AitherMemory -Query "authentication refactor"
    # Semantic search across all memories

.EXAMPLE
    Get-AitherMemory -Agent demiurge -Type episodic -Limit 5
    # Last 5 episodic memories from demiurge

.EXAMPLE
    Get-AitherMemory -Query "deployment issues" -Since (Get-Date).AddDays(-7)
    # Search memories from the past week

.NOTES
    Category: AI
    Dependencies: AitherOS Genesis (port 8001), Memory subsystem
    Platform: Windows, Linux, macOS
#>
function Get-AitherMemory {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Query,

        [Parameter()]
        [string]$Agent,

        [Parameter()]
        [ValidateSet('episodic', 'semantic', 'procedural', 'all')]
        [string]$Type = 'all',

        [Parameter()]
        [int]$Limit = 10,

        [Parameter()]
        [DateTime]$Since,

        [Parameter()]
        [string]$GenesisUrl
    )

    if (-not $GenesisUrl) {
        $ctx = Get-AitherLiveContext
        $GenesisUrl = if ($ctx.OrchestratorURL) { $ctx.OrchestratorURL } else { "http://localhost:8001" }
    }

    # Build request body
    $body = @{
        limit = $Limit
    }
    if ($Query) { $body.query = $Query }
    if ($Agent) { $body.agent = $Agent }
    if ($Type -ne 'all') { $body.memory_type = $Type }
    if ($Since) { $body.since = $Since.ToUniversalTime().ToString("o") }

    try {
        $result = Invoke-RestMethod -Uri "$GenesisUrl/api/memory/query" `
            -Method POST -Body ($body | ConvertTo-Json -Compress) `
            -ContentType 'application/json' -TimeoutSec 15 -ErrorAction Stop

        if (-not $result -or ($result.memories.Count -eq 0 -and $result.results.Count -eq 0)) {
            Write-Host "  No memories found." -ForegroundColor DarkGray
            return @()
        }

        $memories = if ($result.memories) { $result.memories } else { $result.results }

        # Display formatted results
        Write-Host "`n  Memory Query Results ($($memories.Count) found)" -ForegroundColor Cyan
        Write-Host "  $('─' * 60)" -ForegroundColor DarkGray

        foreach ($mem in $memories) {
            $agentName = if ($mem.agent) { $mem.agent } else { 'system' }
            $memType = if ($mem.type) { $mem.type } elseif ($mem.memory_type) { $mem.memory_type } else { 'unknown' }
            $ts = if ($mem.timestamp) { $mem.timestamp } elseif ($mem.created_at) { $mem.created_at } else { '' }
            $content = if ($mem.content) { $mem.content } elseif ($mem.text) { $mem.text } else { '' }
            $score = if ($mem.score) { " (relevance: $([math]::Round($mem.score, 2)))" } else { '' }

            Write-Host "  [$agentName] " -NoNewline -ForegroundColor Magenta
            Write-Host "$memType" -NoNewline -ForegroundColor DarkYellow
            Write-Host "$score" -ForegroundColor DarkGray
            if ($ts) { Write-Host "    $ts" -ForegroundColor DarkGray }
            # Truncate long content
            $display = if ($content.Length -gt 200) { $content.Substring(0, 200) + "..." } else { $content }
            Write-Host "    $display" -ForegroundColor White
            Write-Host ""
        }

        return $memories
    }
    catch {
        Write-Warning "Memory query failed: $_"
        Write-Warning "Is Genesis running at $GenesisUrl with memory subsystem enabled?"
        return @()
    }
}
