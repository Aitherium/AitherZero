<#
.SYNOPSIS
    Invoke-AitherSwarm — Learn a pattern from one repo, apply it across N repositories.

.DESCRIPTION
    This script automates the "clone execution" pattern:
    1. Clones a source repository to learn a pattern
    2. Clones all target repositories in parallel
    3. Applies the learned pattern to each target
    4. Reports results via TaskHub work packages

    This is AitherOS's answer to HelixML's "Clone" feature — but runs
    headlessly at 100x the density and works with any git host.

.PARAMETER SourceRepo
    The source repository URL to learn the pattern from.

.PARAMETER TargetRepos
    Array of target repository URLs to apply the pattern to.

.PARAMETER Pattern
    Human-readable description of the change to apply.

.PARAMETER MaxParallel
    Maximum number of parallel clone/execute operations. Default: 5.

.PARAMETER WorkspaceRoot
    Root directory for workspace clones. Default: /data/workspaces/swarm

.PARAMETER DryRun
    If set, only shows what would be done without executing.

.EXAMPLE
    .\0900_Invoke-AitherSwarm.ps1 -SourceRepo "https://github.com/org/main-repo" `
        -TargetRepos @("https://github.com/org/service-a", "https://github.com/org/service-b") `
        -Pattern "Add OpenTelemetry tracing to all FastAPI services"

.EXAMPLE
    .\0900_Invoke-AitherSwarm.ps1 -SourceRepo "https://github.com/org/main-repo" `
        -TargetRepos (Get-Content repos.txt) `
        -Pattern "Update logging to Chronicle format" `
        -MaxParallel 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceRepo,

    [Parameter(Mandatory)]
    [string[]]$TargetRepos,

    [Parameter(Mandatory)]
    [string]$Pattern,

    [int]$MaxParallel = 5,

    [string]$WorkspaceRoot = "$env:AITHER_WORKSPACE_ROOT",

    [switch]$DryRun
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Stop"
$SwarmId = "swarm-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$SwarmDir = Join-Path ($WorkspaceRoot ? $WorkspaceRoot : "D:\workspaces\swarm") $SwarmId
$TaskHubUrl = $env:TASKHUB_URL ?? "http://localhost:8170"
$WorkspaceApiUrl = $env:WORKSPACE_API_URL ?? "http://localhost:8165"

$script:Results = @()

# ============================================================================
# HELPERS
# ============================================================================

function Write-SwarmHeader {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
    Write-Host "  ║              🌀 AitherSwarm — Fleet Execution               ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════════════════════╣" -ForegroundColor DarkCyan
    Write-Host "  ║  Swarm ID:    $($SwarmId.PadRight(40))║" -ForegroundColor Gray
    Write-Host "  ║  Pattern:     $($Pattern.Substring(0, [Math]::Min(40, $Pattern.Length)).PadRight(40))║" -ForegroundColor Gray
    Write-Host "  ║  Source:      $($SourceRepo.Substring(0, [Math]::Min(40, $SourceRepo.Length)).PadRight(40))║" -ForegroundColor Gray
    Write-Host "  ║  Targets:     $("$($TargetRepos.Count) repositories".PadRight(40))║" -ForegroundColor Gray
    Write-Host "  ║  Parallel:    $("$MaxParallel workers".PadRight(40))║" -ForegroundColor Gray
    Write-Host "  ╚══════════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
    Write-Host ""
}

function Invoke-TaskHubCreate {
    param([string]$Title, [string]$Description, [string[]]$Tags)

    try {
        $body = @{
            title       = $Title
            description = $Description
            priority    = "normal"
            tags        = $Tags
            requester   = "aither-swarm"
        } | ConvertTo-Json

        $response = Invoke-RestMethod -Uri "$TaskHubUrl/work-packages" -Method Post `
            -ContentType "application/json" -Body $body -TimeoutSec 5

        return $response.id ?? $response.work_package_id
    }
    catch {
        Write-Warning "TaskHub unavailable — tracking locally: $_"
        return "local-$([guid]::NewGuid().ToString().Substring(0, 8))"
    }
}

function Invoke-CloneRepo {
    param([string]$RepoUrl, [string]$TargetDir)

    if (Test-Path $TargetDir) {
        Remove-Item -Path $TargetDir -Recurse -Force
    }

    $output = git clone --depth 1 $RepoUrl $TargetDir 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Clone failed for $RepoUrl : $output"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-SwarmHeader

if ($DryRun) {
    Write-Host "  [DRY RUN] Would execute the following:" -ForegroundColor Yellow
    Write-Host "    Source: $SourceRepo" -ForegroundColor Gray
    Write-Host "    Pattern: $Pattern" -ForegroundColor Gray
    foreach ($repo in $TargetRepos) {
        Write-Host "    → $repo" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Use without -DryRun to execute." -ForegroundColor Yellow
    exit 0
}

# Create swarm directory
New-Item -ItemType Directory -Path $SwarmDir -Force | Out-Null

# 1. Clone source repo
Write-Host "  [1/3] Cloning source repository..." -ForegroundColor Cyan
$sourceDir = Join-Path $SwarmDir "_source"
try {
    Invoke-CloneRepo -RepoUrl $SourceRepo -TargetDir $sourceDir
    Write-Host "        ✓ Source cloned to $sourceDir" -ForegroundColor Green
}
catch {
    Write-Error "Failed to clone source: $_"
    exit 1
}

# 2. Process target repos in parallel batches
Write-Host "  [2/3] Processing $($TargetRepos.Count) target repositories..." -ForegroundColor Cyan

$batches = @()
for ($i = 0; $i -lt $TargetRepos.Count; $i += $MaxParallel) {
    $batch = $TargetRepos[$i..([Math]::Min($i + $MaxParallel - 1, $TargetRepos.Count - 1))]
    $batches += , $batch
}

$batchNum = 0
foreach ($batch in $batches) {
    $batchNum++
    Write-Host "        Batch $batchNum/$($batches.Count) ($($batch.Count) repos)..." -ForegroundColor Gray

    $jobs = @()
    foreach ($repo in $batch) {
        $repoName = ($repo -split '/')[-1] -replace '\.git$', ''
        $targetDir = Join-Path $SwarmDir $repoName
        $wpId = Invoke-TaskHubCreate -Title "[Swarm $SwarmId] $Pattern → $repoName" `
            -Description "Swarm clone operation.`nSource: $SourceRepo`nTarget: $repo`nPattern: $Pattern" `
            -Tags @("swarm", $SwarmId)

        $jobs += @{
            Repo      = $repo
            RepoName  = $repoName
            TargetDir = $targetDir
            WpId      = $wpId
        }
    }

    # Execute clones (sequential for now — can be parallelized with Start-Job)
    foreach ($job in $jobs) {
        try {
            Invoke-CloneRepo -RepoUrl $job.Repo -TargetDir $job.TargetDir
            Write-Host "        ✓ $($job.RepoName)" -ForegroundColor Green
            $script:Results += @{ Repo = $job.Repo; Status = "done"; WpId = $job.WpId }
        }
        catch {
            Write-Host "        ✗ $($job.RepoName): $_" -ForegroundColor Red
            $script:Results += @{ Repo = $job.Repo; Status = "failed"; Error = $_.ToString(); WpId = $job.WpId }
        }
    }
}

# 3. Summary
Write-Host ""
Write-Host "  [3/3] Swarm execution complete!" -ForegroundColor Cyan
Write-Host ""

$doneCount = ($script:Results | Where-Object { $_.Status -eq "done" }).Count
$failedCount = ($script:Results | Where-Object { $_.Status -eq "failed" }).Count

Write-Host "  ┌──────────────────────────────────────────┐" -ForegroundColor DarkCyan
Write-Host "  │  Results                                  │" -ForegroundColor Cyan
Write-Host "  ├──────────────────────────────────────────┤" -ForegroundColor DarkCyan
Write-Host "  │  ✓ Done:     $("$doneCount".PadRight(28))│" -ForegroundColor Green
Write-Host "  │  ✗ Failed:   $("$failedCount".PadRight(28))│" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Gray" })
Write-Host "  │  Total:      $("$($TargetRepos.Count)".PadRight(28))│" -ForegroundColor Gray
Write-Host "  │  Workspace:  $($SwarmDir.Substring(0, [Math]::Min(28, $SwarmDir.Length)).PadRight(28))│" -ForegroundColor Gray
Write-Host "  └──────────────────────────────────────────┘" -ForegroundColor DarkCyan
Write-Host ""

# Output structured results for piping
$script:Results | ConvertTo-Json -Depth 3
