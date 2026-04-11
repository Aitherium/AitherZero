#Requires -Version 7.0

<#
.SYNOPSIS
    Scans local drives for large files and potential cleanup candidates.
.DESCRIPTION
    Performs a parallel scan of specified paths or all fixed drives to identify:
    1. Large files (configurable threshold)
    2. Known cache directories (Pip, NPM, HuggingFace, Torch)
    3. Temporary files
    4. Recycle Bin usage
    Generates a JSON report of candidates for cleanup.
.NOTES
    Stage: Maintenance
    Order: 9010
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Path,

    [Parameter()]
    [int]$MinSizeMB = 500,

    [Parameter()]
    [string]$ReportPath = "$PSScriptRoot/../../logs/disk-usage-report.json",

    [Parameter()]
    [switch]$ScanCachesOnly,

    [Parameter()]
    [switch]$PassThru,

    [Parameter()]
    [switch]$ShowReport
)

. "$PSScriptRoot/../_init.ps1"
function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '9010_Scan-DiskUsage'
    } else {
        Write-Host "[$Level] $Message"
    }
}

# --- Configuration ---
$Config = Get-AitherConfigs
$DefaultDrive = $Config.Infrastructure.Defaults.DefaultDrive
if (-not $DefaultDrive) { $DefaultDrive = "C" }

$SystemExclusions = @(
    "$($DefaultDrive):\Windows",
    "$($DefaultDrive):\Program Files",
    "$($DefaultDrive):\Program Files (x86)",
    "$($DefaultDrive):\ProgramData\Microsoft",
    "/proc",
    "/sys",
    "/dev"
)

$CacheLocations = @{
    "PipCache"         = "$env:LOCALAPPDATA\pip\cache"
    "NPMCache"         = "$env:APPDATA\npm-cache"
    "HuggingFaceCache" = "$env:USERPROFILE\.cache\huggingface"
    "TorchCache"       = "$env:LOCALAPPDATA\torch"
    "Temp"             = $env:TEMP
    "RecycleBin"       = "$($DefaultDrive):\`$Recycle.Bin"
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

# --- Main Execution ---

$Results = @{
    Timestamp = Get-Date
    Drives = @()
    LargeFiles = @()
    Caches = @()
    TotalPotentialFreeSpaceMB = 0
}

# 0. Scan Drives
Write-ScriptLog "Scanning drive information..."
$drives = Get-PSDrive -PSProvider FileSystem
foreach ($d in $drives) {
    $Results.Drives += [PSCustomObject]@{
        Name = $d.Name
        FreeGB = [math]::Round($d.Free / 1GB, 2)
        UsedGB = [math]::Round($d.Used / 1GB, 2)
        TotalGB = [math]::Round(($d.Used + $d.Free) / 1GB, 2)
        IsDefault = ($d.Name -eq $DefaultDrive)
    }
    Write-ScriptLog "Drive $($d.Name): $($Results.Drives[-1].FreeGB) GB Free / $($Results.Drives[-1].TotalGB) GB Total"
}

# 1. Scan Caches
Write-ScriptLog "Scanning known cache locations..."
foreach ($key in $CacheLocations.Keys) {
    $loc = $CacheLocations[$key]
    if (Test-Path $loc) {
        Write-ScriptLog "Analyzing $key at $loc..."
        try {
            $stats = Get-ChildItem -Path $loc -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            if ($stats.Count -gt 0) {
                $sizeMB = [math]::Round($stats.Sum / 1MB, 2)
                $Results.Caches += [PSCustomObject]@{
                    Type = $key
                    Path = $loc
                    SizeMB = $sizeMB
                    FileCount = $stats.Count
                }
                $Results.TotalPotentialFreeSpaceMB += $sizeMB
                Write-ScriptLog "Found ${key}: ${sizeMB} MB"
            }
        } catch {
            Write-ScriptLog "Error scanning ${loc}: $_" "Warning"
        }
    }
}

if (-not $ScanCachesOnly) {
    # 2. Determine Paths to Scan
    if (-not $Path) {
        if ($IsWindows) {
            $Path = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Description -eq 'Fixed' }).Root
        } else {
            $Path = @("/") # Root for Linux, but be careful with recursion
            # For safety in this environment, let's default to User Home if no path specified on Linux
            if ($IsLinux) { $Path = @($env:HOME) }
        }
    }

    # 3. Parallel Scan for Large Files
    Write-ScriptLog "Scanning for files larger than ${MinSizeMB}MB in: $($Path -join ', ')..."

    $scanBlock = {
        param($searchPath, $minBytes, $exclusions)

        # Helper to check exclusions
        function Test-IsExcluded {
            param($path, $excludeList)
            foreach ($ex in $excludeList) {
                if ($path.StartsWith($ex)) { return $true }
            }
            return $false
        }

        $files = @()

        # Use .NET enumeration for speed if possible, fallback to GCI
        try {
            $options = [System.IO.EnumerationOptions]::new()
            $options.RecurseSubdirectories = $true
            $options.IgnoreInaccessible = $true
            $options.AttributesToSkip = [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Device

            # This might be too heavy for root C:, so we rely on GCI for better PowerShell integration or just simple recursion
            # Let's stick to GCI with -Parallel for the top level folders to balance control and speed
        } catch {}
    }

    # Simplified Parallel Approach: Get top-level folders and process them in parallel
    $TopLevelFolders = @()
    foreach ($p in $Path) {
        if (Test-Path $p) {
            $TopLevelFolders += Get-ChildItem -Path $p -Directory -ErrorAction SilentlyContinue | Where-Object {
                $pFull = $_.FullName
                $isExcluded = $false
                foreach ($ex in $SystemExclusions) { if ($pFull -like "$ex*") { $isExcluded = $true; break } }
                -not $isExcluded
            }
            # Add files in root
            $rootFiles = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt ($MinSizeMB * 1MB) }
            foreach ($f in $rootFiles) {
                $Results.LargeFiles += [PSCustomObject]@{
                    Path = $f.FullName
                    SizeMB = [math]::Round($f.Length / 1MB, 2)
                }
            }
        }
    }

    $LargeFilesFound = $TopLevelFolders | ForEach-Object -Parallel {
        $minBytes = $using:MinSizeMB * 1MB
        $files = Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt $minBytes }

        $found = @()
        foreach ($f in $files) {
            $found += [PSCustomObject]@{
                Path = $f.FullName
                SizeMB = [math]::Round($f.Length / 1MB, 2)
            }
        }
        return $found
    } -ThrottleLimit 8

    $Results.LargeFiles += $LargeFilesFound
}

# 4. Report Generation
$Results.TotalPotentialFreeSpaceMB = [math]::Round($Results.TotalPotentialFreeSpaceMB, 2)
$json = $Results | ConvertTo-Json -Depth 3
$json | Out-File -FilePath $ReportPath -Encoding utf8

Write-ScriptLog "Scan complete. Report saved to: $ReportPath"

if ($ShowReport) {
    Write-Host "`n=== Disk Usage Report ===" -ForegroundColor Cyan

    Write-Host "`n[Drives]" -ForegroundColor Green
    $Results.Drives | Format-Table Name, FreeGB, UsedGB, TotalGB, IsDefault -AutoSize | Out-Host

    Write-Host "`n[Caches & Temp]" -ForegroundColor Green
    if ($Results.Caches.Count -gt 0) {
        $Results.Caches | Format-Table Type, SizeMB, Path -AutoSize | Out-Host
        $totalCache = ($Results.Caches | Measure-Object -Property SizeMB -Sum).Sum
        Write-Host "Total Reclaimable: $([math]::Round($totalCache, 2)) MB" -ForegroundColor Yellow
    } else {
        Write-Host "No cache usage detected." -ForegroundColor Gray
    }

    if ($Results.LargeFiles.Count -gt 0) {
        Write-Host "`n[Top 10 Large Files]" -ForegroundColor Green
        $Results.LargeFiles | Sort-Object SizeMB -Descending | Select-Object -First 10 | Format-Table SizeMB, Path -AutoSize | Out-Host
    }
    Write-Host ""
}

if ($PassThru) {
    return $Results
}
