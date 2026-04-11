#Requires -Version 7.0
<#
.SYNOPSIS
    Update legacy Python venv path references throughout the codebase.

.DESCRIPTION
    Migrates from the legacy NarrativeAgent/.venv path to the proper AitherOS/.venv.
    This script updates:
    - .vscode/tasks.json
    - start_aither.ps1
    - bootstrap.ps1 -Mode New -Playbook genesis-bootstrap
    - Automation scripts
    - Service registry JSON files
    - copilot-instructions.md

.PARAMETER DryRun
    Show what would be changed without making changes.

.PARAMETER Force
    Update files even if they don't contain the legacy path.

.EXAMPLE
    .\0018_Update-PythonPaths.ps1 -DryRun
    # Preview changes

.EXAMPLE
    .\0018_Update-PythonPaths.ps1
    # Apply changes

.NOTES
    Author: Aitherium
    Category: 0000-0099 Environment Setup
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$Force
)

# Load common utilities
. $PSScriptRoot/../_init.ps1

# ============================================================================
# CONFIGURATION
# ============================================================================

$LEGACY_PATH = "agents/NarrativeAgent/.venv"
$NEW_PATH = ".venv"

# Files to update (relative to repo root)
$FILES_TO_UPDATE = @(
    ".vscode/tasks.json",
    "start_aither.ps1",
    "bootstrap.ps1 -Mode New -Playbook genesis-bootstrap",
    "AitherZero/library/automation-scripts/0825_Deploy-GpuNode.ps1",
    ".github/copilot-instructions.md"
)

# JSON files that need special handling
$JSON_FILES = @(
    "AitherOS/Library/Data/service_registry.json"
)

# Patterns to replace
$REPLACEMENTS = @(
    @{
        Old = 'agents/NarrativeAgent/.venv'
        New = '.venv'
    },
    @{
        Old = 'agents\\NarrativeAgent\\.venv'
        New = '.venv'
    },
    @{
        Old = 'AitherOS/agents/NarrativeAgent/.venv'
        New = 'AitherOS/.venv'
    },
    @{
        Old = 'AitherOS\\agents\\NarrativeAgent\\.venv'
        New = 'AitherOS\\.venv'
    }
)

# ============================================================================
# FUNCTIONS
# ============================================================================

function Update-FileContent {
    param(
        [string]$FilePath,
        [switch]$DryRun
    )
    
    if (-not (Test-Path $FilePath)) {
        Write-AitherLog "File not found: $FilePath" -Level Warn
        return @{ Updated = $false; Changes = 0 }
    }
    
    $content = Get-Content $FilePath -Raw
    $originalContent = $content
    $changeCount = 0
    
    foreach ($replacement in $REPLACEMENTS) {
        $matches = [regex]::Matches($content, [regex]::Escape($replacement.Old))
        if ($matches.Count -gt 0) {
            $changeCount += $matches.Count
            $content = $content -replace [regex]::Escape($replacement.Old), $replacement.New
        }
    }
    
    if ($changeCount -gt 0) {
        $relativePath = $FilePath.Replace($REPO_ROOT, "").TrimStart("\", "/")
        
        if ($DryRun) {
            Write-Host "  📝 Would update: $relativePath ($changeCount changes)" -ForegroundColor Yellow
        }
        else {
            Set-Content $FilePath -Value $content -NoNewline
            Write-Host "  ✅ Updated: $relativePath ($changeCount changes)" -ForegroundColor Green
        }
        
        return @{ Updated = $true; Changes = $changeCount }
    }
    
    return @{ Updated = $false; Changes = 0 }
}

function Update-JsonFile {
    param(
        [string]$FilePath,
        [switch]$DryRun
    )
    
    if (-not (Test-Path $FilePath)) {
        return @{ Updated = $false; Changes = 0 }
    }
    
    # For JSON files, we do string replacement to preserve formatting
    return Update-FileContent -FilePath $FilePath -DryRun:$DryRun
}

# ============================================================================
# MAIN
# ============================================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║           🔄 UPDATE PYTHON VENV PATH REFERENCES                  ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

if ($DryRun) {
    Write-Host "🔍 DRY RUN - No changes will be made" -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "Migrating from: AitherOS/$LEGACY_PATH" -ForegroundColor DarkGray
Write-Host "            to: AitherOS/$NEW_PATH" -ForegroundColor DarkGray
Write-Host ""

$totalChanges = 0
$filesUpdated = 0

# Process regular files
Write-Host "📂 Updating script files..." -ForegroundColor Cyan
foreach ($file in $FILES_TO_UPDATE) {
    $fullPath = Join-Path $REPO_ROOT $file
    $result = Update-FileContent -FilePath $fullPath -DryRun:$DryRun
    if ($result.Updated) {
        $filesUpdated++
        $totalChanges += $result.Changes
    }
}

# Process JSON files
Write-Host ""
Write-Host "📂 Updating JSON files..." -ForegroundColor Cyan
foreach ($file in $JSON_FILES) {
    $fullPath = Join-Path $REPO_ROOT $file
    $result = Update-JsonFile -FilePath $fullPath -DryRun:$DryRun
    if ($result.Updated) {
        $filesUpdated++
        $totalChanges += $result.Changes
    }
}

# Search for any other files that might need updating
Write-Host ""
Write-Host "📂 Scanning for additional files with legacy paths..." -ForegroundColor Cyan

$additionalFiles = Get-ChildItem -Path $REPO_ROOT -Include "*.ps1", "*.json", "*.md", "*.yaml", "*.yml" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { 
        $_.FullName -notmatch "\\\.venv\\" -and 
        $_.FullName -notmatch "\\node_modules\\" -and
        $_.FullName -notmatch "\\site\\" -and
        $_.FullName -notmatch "\\logs\\" -and
        $_.FullName -notmatch "\\reports\\" -and
        $_.FullName -notmatch "\\\.git\\" 
    } |
    ForEach-Object {
        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match "NarrativeAgent[/\\]\.venv") {
            $_.FullName
        }
    }

$knownFiles = $FILES_TO_UPDATE + $JSON_FILES | ForEach-Object { Join-Path $REPO_ROOT $_ }

foreach ($file in $additionalFiles) {
    if ($file -notin $knownFiles) {
        $result = Update-FileContent -FilePath $file -DryRun:$DryRun
        if ($result.Updated) {
            $filesUpdated++
            $totalChanges += $result.Changes
        }
    }
}

# Summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "🔍 DRY RUN COMPLETE" -ForegroundColor Yellow
    Write-Host "   Would update $filesUpdated files with $totalChanges changes" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   Run without -DryRun to apply changes" -ForegroundColor DarkGray
}
else {
    Write-Host "✅ UPDATE COMPLETE" -ForegroundColor Green
    Write-Host "   Updated $filesUpdated files with $totalChanges changes" -ForegroundColor Green
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run 0016_Initialize-PythonEnvironment.ps1 to create the new venv" -ForegroundColor DarkGray
Write-Host "  2. Restart any running services" -ForegroundColor DarkGray
Write-Host "  3. Reload VS Code to pick up tasks.json changes" -ForegroundColor DarkGray
Write-Host ""

return @{
    FilesUpdated = $filesUpdated
    TotalChanges = $totalChanges
    DryRun = $DryRun
}
