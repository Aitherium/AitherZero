<#
.SYNOPSIS
    Migrates AitherOS component brand names.

.DESCRIPTION
    Renames AitherOS components to their new brand names:
    - AitherWatch → AitherWatch (The All-Seeing Watchdog)
    - AitherTag → AitherTag (Data Classification & Tagging)
    - AitherForce → AitherForce (CPU Resource Management)
    
    Performs:
    1. File renames (*.py, *.ps1)
    2. Content updates (imports, class names, logger names, endpoints)
    3. Config file updates
    4. Documentation updates

.PARAMETER DryRun
    Show what would be changed without making changes.

.PARAMETER ShowOutput
    Display detailed progress.

.PARAMETER TargetComponent
    Migrate only a specific component: Eyes, Classifier, CPU, or All.

.EXAMPLE
    ./0920_Migrate-BrandNames.ps1 -DryRun -ShowOutput
    ./0920_Migrate-BrandNames.ps1 -TargetComponent Eyes -ShowOutput
    ./0920_Migrate-BrandNames.ps1 -ShowOutput

.NOTES
    Script: 0920_Migrate-BrandNames.ps1
    Category: Maintenance (0900-0999)
    Author: AitherZero
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$ShowOutput,
    [ValidateSet("Eyes", "Classifier", "CPU", "All")]
    [string]$TargetComponent = "All"
)

. "$PSScriptRoot/_init.ps1"

# =============================================================================
# BRAND MIGRATION DEFINITIONS
# =============================================================================

$MigrationMap = @{
    Eyes = @{
        OldName       = "AitherWatch"
        NewName       = "AitherWatch"
        OldId         = "AitherWatch"
        NewId         = "aitherwatch"
        OldFile       = "AitherWatch.py"
        NewFile       = "AitherWatch.py"
        OldConfig     = "AitherWatch_config.json"
        NewConfig     = "aitherwatch_config.json"
        Description   = "The All-Seeing - health monitoring & watchdog"
        Port          = 8082
    }
    Classifier = @{
        OldName       = "AitherTag"
        NewName       = "AitherTag"
        OldId         = "AitherTag"
        NewId         = "aithertag"
        OldFile       = "AitherTag.py"
        NewFile       = "AitherTag.py"
        OldConfig     = $null
        NewConfig     = $null
        Description   = "The Eye - automated data classification & tagging"
        Port          = 8092
        OldScript     = "0763_Start-AitherTag.ps1"
        NewScript     = "0763_Start-AitherTag.ps1"
    }
    CPU = @{
        OldName       = "AitherForce"
        NewName       = "AitherForce"
        OldId         = "AitherForce"
        NewId         = "aitherforce"
        OldFile       = "AitherForce.py"
        NewFile       = "AitherForce.py"
        OldConfig     = $null
        NewConfig     = $null
        Description   = "The Core - CPU resource management for Intel i9"
        Port          = 8102
    }
}

# Files to update (relative to repo root)
$TargetFiles = @(
    # Python files
    "AitherOS/AitherNode/*.py"
    "AitherOS/AitherNode/config/*.py"
    "AitherOS/agents/**/*.py"
    # PowerShell files
    "AitherZero/library/automation-scripts/*.ps1"
    "AitherZero/config/*.psd1"
    "*.ps1"
    # Documentation
    "*.md"
    "docs/*.md"
    "AitherOS/*.md"
    # TypeScript/React
    "AitherOS/AitherNode/AitherVeil/src/**/*.tsx"
    "AitherOS/AitherNode/AitherVeil/src/**/*.ts"
)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

function Write-MigrationLog {
    param([string]$Message, [string]$Type = "Info")
    
    if (-not $ShowOutput) { return }
    
    $prefix = switch ($Type) {
        "Info"    { "   " }
        "Action"  { " → " }
        "Success" { " ✓ " }
        "Warning" { " ⚠ " }
        "Error"   { " ✗ " }
        "Header"  { "═══" }
        default   { "   " }
    }
    
    $color = switch ($Type) {
        "Info"    { "Gray" }
        "Action"  { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Header"  { "Magenta" }
        default   { "White" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Get-FilesToProcess {
    param([string]$RepoRoot)
    
    $allFiles = @()
    
    foreach ($pattern in $TargetFiles) {
        $fullPattern = Join-Path $RepoRoot $pattern
        $files = Get-ChildItem -Path $fullPattern -File -ErrorAction SilentlyContinue -Recurse
        $allFiles += $files
    }
    
    return $allFiles | Select-Object -Unique
}

function Update-FileContent {
    param(
        [string]$FilePath,
        [hashtable]$Migration,
        [switch]$DryRun
    )
    
    if (-not (Test-Path $FilePath)) { return $false }
    
    $content = Get-Content -Path $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    
    $originalContent = $content
    
    # Replace all variations
    $replacements = @(
        @{ Old = $Migration.OldName; New = $Migration.NewName }          # AitherWatch → AitherWatch
        @{ Old = $Migration.OldId; New = $Migration.NewId }              # AitherWatch → aitherwatch
        @{ Old = $Migration.OldName.ToUpper(); New = $Migration.NewName.ToUpper() }  # AitherWatch → AITHERWATCH
    )
    
    foreach ($r in $replacements) {
        $content = $content -replace [regex]::Escape($r.Old), $r.New
    }
    
    # Check if changes were made
    if ($content -ne $originalContent) {
        if (-not $DryRun) {
            Set-Content -Path $FilePath -Value $content -NoNewline
        }
        return $true
    }
    
    return $false
}

function Rename-ComponentFile {
    param(
        [string]$RepoRoot,
        [hashtable]$Migration,
        [switch]$DryRun
    )
    
    $oldPath = Join-Path $RepoRoot "AitherOS/AitherNode" $Migration.OldFile
    $newPath = Join-Path $RepoRoot "AitherOS/AitherNode" $Migration.NewFile
    
    if (Test-Path $oldPath) {
        if (-not $DryRun) {
            # First update content, then rename
            Update-FileContent -FilePath $oldPath -Migration $Migration
            Rename-Item -Path $oldPath -NewName $Migration.NewFile -Force
        }
        Write-MigrationLog "Renamed: $($Migration.OldFile) → $($Migration.NewFile)" -Type "Success"
        return $true
    }
    else {
        Write-MigrationLog "File not found: $($Migration.OldFile)" -Type "Warning"
        return $false
    }
}

function Rename-AutomationScript {
    param(
        [string]$RepoRoot,
        [hashtable]$Migration,
        [switch]$DryRun
    )
    
    if (-not $Migration.OldScript) { return $false }
    
    $scriptsDir = Join-Path $RepoRoot "AitherZero/library/automation-scripts"
    $oldPath = Join-Path $scriptsDir $Migration.OldScript
    $newPath = Join-Path $scriptsDir $Migration.NewScript
    
    if (Test-Path $oldPath) {
        if (-not $DryRun) {
            Update-FileContent -FilePath $oldPath -Migration $Migration
            Rename-Item -Path $oldPath -NewName $Migration.NewScript -Force
        }
        Write-MigrationLog "Renamed: $($Migration.OldScript) → $($Migration.NewScript)" -Type "Success"
        return $true
    }
    
    return $false
}

# =============================================================================
# MAIN MIGRATION
# =============================================================================

# $projectRoot is set by _init.ps1
$RepoRoot = $projectRoot
if (-not $RepoRoot) {
    $RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
}
$startTime = Get-Date

if ($ShowOutput) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  AITHEROS BRAND MIGRATION" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "  MODE: DRY RUN (no changes will be made)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  MODE: LIVE (changes will be applied)" -ForegroundColor Cyan
    }
    Write-Host ""
}

# Determine which migrations to run
$migrations = if ($TargetComponent -eq "All") {
    $MigrationMap.GetEnumerator()
}
else {
    @{ Key = $TargetComponent; Value = $MigrationMap[$TargetComponent] }.GetEnumerator()
}

$totalChanges = 0
$filesChanged = 0
$filesRenamed = 0

# Get all files to process
$files = Get-FilesToProcess -RepoRoot $RepoRoot
Write-MigrationLog "Found $($files.Count) files to scan" -Type "Info"

foreach ($entry in $migrations) {
    $componentName = $entry.Key
    $migration = $entry.Value
    
    Write-MigrationLog "" -Type "Header"
    Write-MigrationLog "Migrating: $($migration.OldName) → $($migration.NewName)" -Type "Header"
    Write-MigrationLog "$($migration.Description)" -Type "Info"
    Write-MigrationLog "" -Type "Info"
    
    # 1. Rename main Python file
    $renamed = Rename-ComponentFile -RepoRoot $RepoRoot -Migration $migration -DryRun:$DryRun
    if ($renamed) { $filesRenamed++ }
    
    # 2. Rename automation script if exists
    $scriptRenamed = Rename-AutomationScript -RepoRoot $RepoRoot -Migration $migration -DryRun:$DryRun
    if ($scriptRenamed) { $filesRenamed++ }
    
    # 3. Update content in all files
    foreach ($file in $files) {
        $changed = Update-FileContent -FilePath $file.FullName -Migration $migration -DryRun:$DryRun
        if ($changed) {
            $filesChanged++
            $relativePath = $file.FullName.Replace($RepoRoot, "").TrimStart("\")
            Write-MigrationLog "Updated: $relativePath" -Type "Action"
        }
    }
}

# =============================================================================
# SUMMARY
# =============================================================================

$duration = (Get-Date) - $startTime

if ($ShowOutput) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host "  MIGRATION COMPLETE" -ForegroundColor White
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Files Renamed:  $filesRenamed" -ForegroundColor Cyan
    Write-Host "  Files Updated:  $filesChanged" -ForegroundColor Cyan
    Write-Host "  Duration:       $($duration.TotalSeconds.ToString('F1'))s" -ForegroundColor Gray
    Write-Host ""
    
    if ($DryRun) {
        Write-Host "  Run without -DryRun to apply changes." -ForegroundColor Yellow
    }
    else {
        Write-Host "  ✓ Brand migration complete!" -ForegroundColor Green
        Write-Host ""
        Write-Host "  NEXT STEPS:" -ForegroundColor White
        Write-Host "  1. Review changes: git diff" -ForegroundColor Gray
        Write-Host "  2. Run tests: Invoke-AitherPlaybook -Name test-quick" -ForegroundColor Gray
        Write-Host "  3. Commit: git add -A && git commit -m 'refactor: migrate brand names'" -ForegroundColor Gray
    }
    Write-Host ""
}

# Return summary object
return [PSCustomObject]@{
    DryRun       = $DryRun
    FilesRenamed = $filesRenamed
    FilesUpdated = $filesChanged
    Duration     = $duration
    Success      = $true
}
