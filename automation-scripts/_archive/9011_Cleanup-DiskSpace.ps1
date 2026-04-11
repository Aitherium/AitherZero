#Requires -Version 7.0

<#
.SYNOPSIS
    Cleans up disk space by removing caches, temp files, or specific targets.
.DESCRIPTION
    Executes cleanup operations for:
    1. Known caches (Pip, NPM, HuggingFace, Torch)
    2. System Temp folders
    3. Recycle Bin
    4. Custom paths provided via parameter
    Supports DryRun mode to preview changes.
.NOTES
    Stage: Maintenance
    Order: 9011
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$Target,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$Force
)

. "$PSScriptRoot/_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '9011_Cleanup-DiskSpace'
    } else {
        Write-Host "[$Level] $Message"
    }
}

function Remove-DirectoryContent {
    param($Path, $Description)

    # Handle wildcard suffix for "contents only"
    $cleanContentsOnly = $Path.EndsWith("*")
    $realPath = if ($cleanContentsOnly) { $Path.TrimEnd("*").TrimEnd("\").TrimEnd("/") } else { $Path }

    if (-not (Test-Path $realPath)) {
        Write-ScriptLog "Path not found (skipping): $realPath" "Warning"
        return
    }

    Write-ScriptLog "Cleaning $Description at $realPath ($($cleanContentsOnly ? 'Contents Only' : 'Full Delete'))..."

    if ($DryRun) {
        $items = Get-ChildItem -Path $realPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        Write-ScriptLog "[DRY RUN] Would delete $($items.Count) items, approx $([math]::Round($items.Sum / 1MB, 2)) MB."
    } else {
        if ($Force -or $PSCmdlet.ShouldProcess($realPath, "Delete $Description")) {
            try {
                # Try native commands for speed/reliability where possible
                if ($Description -eq "PipCache" -and (Get-Command pip -ErrorAction SilentlyContinue)) {
                    pip cache purge | Out-Null
                } elseif ($Description -eq "NPMCache" -and (Get-Command npm -ErrorAction SilentlyContinue)) {
                    npm cache clean --force | Out-Null
                } else {
                    if ($cleanContentsOnly) {
                        Remove-Item -Path "$realPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item -Path $realPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-ScriptLog "Successfully cleaned $Description."
            } catch {
                Write-ScriptLog "Error cleaning ${Description}: $_" "Error"
            }
        }
    }
}

# --- Configuration ---
$CacheLocations = @{
    "PipCache"         = "$env:LOCALAPPDATA\pip\cache"
    "NPMCache"         = "$env:APPDATA\npm-cache"
    "HuggingFaceCache" = "$env:USERPROFILE\.cache\huggingface"
    "TorchCache"       = "$env:LOCALAPPDATA\torch"
    "Temp"             = $env:TEMP
    "RecycleBin"       = "C:\`$Recycle.Bin"
}

# Linux adjustments
if ($IsLinux) {
    $CacheLocations["PipCache"] = "$env:HOME/.cache/pip"
    $CacheLocations["NPMCache"] = "$env:HOME/.npm"
    $CacheLocations["HuggingFaceCache"] = "$env:HOME/.cache/huggingface"
    $CacheLocations["TorchCache"] = "$env:HOME/.cache/torch"
    $CacheLocations["Temp"] = "/tmp"
    $CacheLocations.Remove("RecycleBin")
}

# --- Execution ---

$TargetsToProcess = @()

if ("All" -in $Target) {
    $TargetsToProcess += $CacheLocations.Keys
} else {
    $TargetsToProcess += $Target
}

foreach ($t in $TargetsToProcess) {
    if ($t -eq "All") { continue }

    if ($CacheLocations.ContainsKey($t)) {
        Remove-DirectoryContent -Path $CacheLocations[$t] -Description $t
    } else {
        # Treat as custom path
        Remove-DirectoryContent -Path $t -Description "Custom Path"
    }
}

Write-ScriptLog "Cleanup operation completed."
