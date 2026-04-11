#Requires -Version 7.0

<#
.SYNOPSIS
    Syncs observability data (logs/metrics) to Git for GitHub Pages publishing.

.DESCRIPTION
    Replicates logs from logs/aither/ to docs/data/logs/ and pushes to Git.
    This enables AitherVeil (running on GitHub Pages) to consume static logs.

.PARAMETER Remote
    The git remote to push to (default: origin)

.PARAMETER Branch
    The branch to push to (default: main)

.PARAMETER IntervalSeconds
    If set, runs in a loop with sleep interval.

.EXAMPLE
    ./0650_Sync-Observability.ps1 -IntervalSeconds 300
#>

[CmdletBinding()]
param(
    [string]$Remote = "origin",
    [string]$Branch = "",  # Default to current branch
    [int]$IntervalSeconds = 0
)

# Resolve Paths
$script:RootPath = Resolve-Path "$PSScriptRoot/../../../.."
$script:LogSource = Join-Path $script:RootPath "logs/aither"
$script:LogDest = Join-Path $script:RootPath "docs/data/logs"

Write-Host "Initializing Observability Sync..." -ForegroundColor Cyan
Write-Host "Source: $script:LogSource" -ForegroundColor Gray
Write-Host "Dest:   $script:LogDest" -ForegroundColor Gray

function Sync-Logs {
    Write-Host "Syncing logs..." -ForegroundColor Cyan
    
    if (-not (Test-Path $script:LogDest)) {
        New-Item -ItemType Directory -Path $script:LogDest -Force | Out-Null
    }
    
    # Copy JSONL logs (limiting size to last 1000 lines to avoid repo bloat)
    $jsonl = Join-Path $script:LogSource "aither.jsonl"
    
    if (Test-Path $jsonl) {
        # Raw JSONL copy
        $destFileJsonl = Join-Path $script:LogDest "aither.jsonl"
        try {
            $lines = Get-Content $jsonl -Tail 1000
            $lines | Set-Content $destFileJsonl -Encoding UTF8
            Write-Host "  -> Synced aither.jsonl (last 1000 lines)" -ForegroundColor Green
            
            # Convert to JSON Array for easier static consumption by Dashboard
            # (Wraps lines in [ ... ] and separates with commas)
            $jsonArray = "[" + ($lines -join ",") + "]"
            $destFileJson = Join-Path $script:LogDest "logs.json"
            Set-Content $destFileJson -Value $jsonArray -Encoding UTF8
            Write-Host "  -> Converted to logs.json (valid JSON array)" -ForegroundColor Green
            
        } catch {
            Write-Warning "Failed to sync log file: $_"
        }
    } else {
        Write-Warning "Source log file not found: $jsonl"
    }

    # Sync Metrics if available
    $metricsFiles = Get-ChildItem -Path $script:LogSource -Filter "*metrics*.json" -ErrorAction SilentlyContinue
    foreach ($mFile in $metricsFiles) {
        Copy-Item $mFile.FullName -Destination $script:LogDest -Force
        Write-Host "  -> Synced metrics: $($mFile.Name)" -ForegroundColor Green
    }

    # Generate rudimentary stats.json for dashboard
    $stats = @{
        updated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        status = "healthy"
        sync_agent = "0650_Sync-Observability"
    }
    $stats | ConvertTo-Json | Set-Content (Join-Path $script:LogDest "stats.json")
    
    # Git Commit & Push
    Push-Location $script:RootPath
    try {
        # Check if there are changes
        $status = git status --porcelain docs/data/logs/
        if ($status) {
            Write-Host "Committing changes..." -ForegroundColor Yellow
            git add docs/data/logs/
            git commit -m "chore(obs): sync logs $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            
            # Determine branch to push
            $currentBranch = git branch --show-current
            $targetBranch = if ($Branch) { $Branch } else { $currentBranch }
            
            Write-Host "Pushing to $Remote/$targetBranch..." -ForegroundColor Yellow
            git push $Remote $targetBranch
            Write-Host "Observability data synced successfully!" -ForegroundColor Green
        } else {
            Write-Host "No log changes to sync." -ForegroundColor DarkGray
        }
    } catch {
        Write-Error "Git operation failed: $_"
    } finally {
        Pop-Location
    }
}

# Run Loop or Single Shot
if ($IntervalSeconds -gt 0) {
    Write-Host "Running in loop mode (Interval: ${IntervalSeconds}s)" -ForegroundColor Magenta
    while ($true) {
        Sync-Logs
        Write-Host "Sleeping for $IntervalSeconds seconds..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $IntervalSeconds
    }
} else {
    Sync-Logs
}
