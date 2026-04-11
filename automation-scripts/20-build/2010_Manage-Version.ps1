#Requires -Version 7.0
<#
.SYNOPSIS
    Manages AitherOS versioning: bump, show, validate, and prepare releases.

.DESCRIPTION
    Centralized version management for AitherOS/AitherZero. Updates VERSION file,
    AitherZero.psd1 manifest, and package.json in a single atomic operation.
    Supports semver bumping (major/minor/patch), explicit version setting,
    prerelease suffixes, and release preparation with git tagging.

.PARAMETER Action
    What to do:
      show       - Display current version info
      bump       - Increment version (use -BumpType)
      set        - Set explicit version (use -Version)
      tag        - Create a git tag for current version
      prepare    - Full release prep: bump + commit + tag
      history    - Show release tag history
      validate   - Validate a version string

.PARAMETER BumpType
    Which semver component to bump: major, minor, patch. Default: patch

.PARAMETER Version
    Explicit version to set (for Action=set or Action=validate).
    Format: MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-prerelease.N

.PARAMETER Prerelease
    Prerelease suffix to append (e.g., beta.1, rc.1, alpha.3).
    Used with bump or set actions.

.PARAMETER Message
    Custom git commit/tag message. Default: auto-generated.

.PARAMETER NoPush
    Don't push commits/tags to remote. Default: pushes automatically.

.PARAMETER DryRun
    Show what would happen without making changes.

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action show
    # Shows current version from all tracked files

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action bump -BumpType minor
    # 2.0.0 → 2.1.0

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action bump -BumpType patch -Prerelease beta.1
    # 2.1.0 → 2.1.1-beta.1

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action set -Version 3.0.0
    # Sets all version files to 3.0.0

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action prepare -BumpType minor
    # Bumps minor, commits, tags, pushes — ready for release workflow

.EXAMPLE
    .\2010_Manage-Version.ps1 -Action history
    # Lists all release tags with dates

.NOTES
    Category: build
    Dependencies: git
    Platform: Windows, Linux, macOS
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet("show", "bump", "set", "tag", "prepare", "history", "validate")]
    [string]$Action,

    [ValidateSet("major", "minor", "patch")]
    [string]$BumpType = "patch",

    [string]$Version,

    [string]$Prerelease,

    [string]$Message,

    [switch]$NoPush,

    [switch]$DryRun
)

# ─── Init ────────────────────────────────────────────────────────────────────
. "$PSScriptRoot/../_init.ps1"

if (-not $projectRoot) {
    Write-Error "Cannot locate project root. Run from within the AitherZero repository."
    exit 1
}

# ─── File Paths ──────────────────────────────────────────────────────────────
$versionFile   = Join-Path $projectRoot "VERSION"
$manifestFile  = Join-Path $projectRoot "AitherZero/AitherZero.psd1"
$packageFile   = Join-Path $projectRoot "package.json"

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Get-CurrentVersion {
    <#
    .SYNOPSIS
        Reads the current version from the VERSION file.
    #>
    if (Test-Path $versionFile) {
        return (Get-Content $versionFile -Raw).Trim()
    }
    return "0.0.0"
}

function Test-SemVer {
    <#
    .SYNOPSIS
        Validates a string is valid semantic versioning.
    #>
    param([string]$Ver)
    return $Ver -match '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+(\.[0-9]+)?)?$'
}

function Split-SemVer {
    <#
    .SYNOPSIS
        Splits a semver string into components.
    #>
    param([string]$Ver)

    $parts = ($Ver -split '-')[0] -split '\.'
    $pre = if ($Ver -match '-(.+)$') { $Matches[1] } else { $null }

    return @{
        Major      = [int]$parts[0]
        Minor      = [int]$parts[1]
        Patch      = [int]$parts[2]
        Prerelease = $pre
        Full       = $Ver
    }
}

function Step-SemVer {
    <#
    .SYNOPSIS
        Bumps a semver by the specified component.
    #>
    param(
        [string]$Ver,
        [string]$Bump,
        [string]$Pre
    )

    $sv = Split-SemVer -Ver $Ver

    switch ($Bump) {
        "major" {
            $sv.Major++
            $sv.Minor = 0
            $sv.Patch = 0
        }
        "minor" {
            $sv.Minor++
            $sv.Patch = 0
        }
        "patch" {
            $sv.Patch++
        }
    }

    $newVer = "$($sv.Major).$($sv.Minor).$($sv.Patch)"

    if ($Pre) {
        $newVer += "-$Pre"
    }

    return $newVer
}

function Set-AllVersions {
    <#
    .SYNOPSIS
        Updates version in all tracked files atomically.
    #>
    param([string]$NewVersion)

    $cleanVersion = ($NewVersion -split '-')[0]
    $changes = @()

    # 1. VERSION file
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would set VERSION → $NewVersion" -ForegroundColor DarkGray
    } else {
        Set-Content $versionFile -Value $NewVersion -NoNewline
    }
    $changes += "VERSION → $NewVersion"

    # 2. AitherZero.psd1
    if (Test-Path $manifestFile) {
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would set AitherZero.psd1 ModuleVersion → $cleanVersion" -ForegroundColor DarkGray
        } else {
            $content = Get-Content $manifestFile -Raw
            $content = $content -replace "ModuleVersion\s*=\s*'[^']+'", "ModuleVersion = '$cleanVersion'"
            Set-Content $manifestFile -Value $content
        }
        $changes += "AitherZero.psd1 → $cleanVersion"
    }

    # 3. package.json
    if (Test-Path $packageFile) {
        try {
            $pkg = Get-Content $packageFile -Raw | ConvertFrom-Json
            if ($pkg.version) {
                if ($DryRun) {
                    Write-Host "  [DRY RUN] Would set package.json version → $NewVersion" -ForegroundColor DarkGray
                } else {
                    $pkg.version = $NewVersion
                    $pkg | ConvertTo-Json -Depth 10 | Set-Content $packageFile
                }
                $changes += "package.json → $NewVersion"
            }
        } catch {
            Write-Verbose "Skipping package.json: $_"
        }
    }

    return $changes
}

function Show-VersionTable {
    <#
    .SYNOPSIS
        Displays version info from all tracked files.
    #>
    $info = @()

    # VERSION file
    if (Test-Path $versionFile) {
        $info += [PSCustomObject]@{
            File    = "VERSION"
            Version = (Get-Content $versionFile -Raw).Trim()
            Status  = "✅"
        }
    } else {
        $info += [PSCustomObject]@{
            File    = "VERSION"
            Version = "MISSING"
            Status  = "❌"
        }
    }

    # AitherZero.psd1
    if (Test-Path $manifestFile) {
        $content = Get-Content $manifestFile -Raw
        if ($content -match "ModuleVersion\s*=\s*'([^']+)'") {
            $info += [PSCustomObject]@{
                File    = "AitherZero.psd1"
                Version = $Matches[1]
                Status  = "✅"
            }
        }
    }

    # package.json
    if (Test-Path $packageFile) {
        try {
            $pkg = Get-Content $packageFile -Raw | ConvertFrom-Json
            if ($pkg.version) {
                $info += [PSCustomObject]@{
                    File    = "package.json"
                    Version = $pkg.version
                    Status  = "✅"
                }
            }
        } catch {
            # Skip
        }
    }

    # Git tag
    try {
        $latestTag = git -C $projectRoot describe --tags --abbrev=0 2>$null
        if ($latestTag) {
            $info += [PSCustomObject]@{
                File    = "git tag (latest)"
                Version = $latestTag
                Status  = "🏷️"
            }
        }
    } catch {
        # Skip
    }

    return $info
}

# ─── Actions ─────────────────────────────────────────────────────────────────

switch ($Action) {

    "show" {
        Write-Host "`n📦 AitherOS Version Info" -ForegroundColor Cyan
        Write-Host "─────────────────────────" -ForegroundColor DarkGray
        $table = Show-VersionTable
        $table | Format-Table -AutoSize
    }

    "validate" {
        if (-not $Version) {
            Write-Error "Use -Version to specify the version string to validate."
            exit 1
        }
        if (Test-SemVer $Version) {
            $sv = Split-SemVer -Ver $Version
            Write-Host "✅ '$Version' is valid semver" -ForegroundColor Green
            Write-Host "   Major: $($sv.Major)  Minor: $($sv.Minor)  Patch: $($sv.Patch)" -ForegroundColor Gray
            if ($sv.Prerelease) {
                Write-Host "   Prerelease: $($sv.Prerelease)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "❌ '$Version' is NOT valid semver" -ForegroundColor Red
            Write-Host "   Expected: MAJOR.MINOR.PATCH[-prerelease.N]" -ForegroundColor Gray
            exit 1
        }
    }

    "bump" {
        $current = Get-CurrentVersion
        if (-not (Test-SemVer $current)) {
            Write-Error "Current version '$current' is not valid semver. Use -Action set to fix it."
            exit 1
        }

        $newVersion = Step-SemVer -Ver $current -Bump $BumpType -Pre $Prerelease

        Write-Host "`n📦 Version Bump" -ForegroundColor Cyan
        Write-Host "  $current → $newVersion ($BumpType)" -ForegroundColor Yellow

        $changes = Set-AllVersions -NewVersion $newVersion

        if (-not $DryRun) {
            Write-Host "`n✅ Updated:" -ForegroundColor Green
            $changes | ForEach-Object { Write-Host "  • $_" -ForegroundColor Gray }
        }
    }

    "set" {
        if (-not $Version) {
            Write-Error "Use -Version to specify the version to set."
            exit 1
        }

        # Strip leading v
        $Version = $Version.TrimStart('v')

        if ($Prerelease) {
            $Version = "$Version-$Prerelease"
        }

        if (-not (Test-SemVer $Version)) {
            Write-Error "'$Version' is not valid semver. Expected: MAJOR.MINOR.PATCH[-prerelease.N]"
            exit 1
        }

        $current = Get-CurrentVersion
        Write-Host "`n📦 Set Version" -ForegroundColor Cyan
        Write-Host "  $current → $Version" -ForegroundColor Yellow

        $changes = Set-AllVersions -NewVersion $Version

        if (-not $DryRun) {
            Write-Host "`n✅ Updated:" -ForegroundColor Green
            $changes | ForEach-Object { Write-Host "  • $_" -ForegroundColor Gray }
        }
    }

    "tag" {
        $current = Get-CurrentVersion
        $tag = "v$current"

        Write-Host "`n🏷️  Create Git Tag" -ForegroundColor Cyan
        Write-Host "  Tag: $tag" -ForegroundColor Yellow

        # Check if tag exists
        $existing = git -C $projectRoot tag -l $tag 2>$null
        if ($existing) {
            Write-Error "Tag '$tag' already exists! Bump the version first or delete the existing tag."
            exit 1
        }

        $tagMessage = if ($Message) { $Message } else { "Release $current" }

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would create tag: $tag" -ForegroundColor DarkGray
        } else {
            git -C $projectRoot tag -a $tag -m $tagMessage
            Write-Host "  ✅ Tag created: $tag" -ForegroundColor Green

            if (-not $NoPush) {
                git -C $projectRoot push origin $tag
                Write-Host "  ✅ Tag pushed to origin" -ForegroundColor Green
            } else {
                Write-Host "  ⚠️  Tag NOT pushed (use git push origin $tag)" -ForegroundColor Yellow
            }
        }
    }

    "prepare" {
        $current = Get-CurrentVersion
        if (-not (Test-SemVer $current)) {
            Write-Error "Current version '$current' is not valid semver. Use -Action set to fix it."
            exit 1
        }

        $newVersion = if ($Version) {
            $Version.TrimStart('v')
        } else {
            Step-SemVer -Ver $current -Bump $BumpType -Pre $Prerelease
        }

        if (-not (Test-SemVer $newVersion)) {
            Write-Error "'$newVersion' is not valid semver."
            exit 1
        }

        $tag = "v$newVersion"
        $commitMsg = if ($Message) { $Message } else { "chore(release): bump version to $newVersion" }

        Write-Host "`n🚀 Prepare Release" -ForegroundColor Cyan
        Write-Host "─────────────────────────" -ForegroundColor DarkGray
        Write-Host "  Current:  $current" -ForegroundColor Gray
        Write-Host "  New:      $newVersion" -ForegroundColor Yellow
        Write-Host "  Tag:      $tag" -ForegroundColor Yellow
        Write-Host "  Type:     $BumpType" -ForegroundColor Gray
        if ($Prerelease) {
            Write-Host "  Pre:      $Prerelease" -ForegroundColor DarkYellow
        }
        Write-Host ""

        # Check if tag exists
        $existing = git -C $projectRoot tag -l $tag 2>$null
        if ($existing) {
            Write-Error "Tag '$tag' already exists! Choose a different version."
            exit 1
        }

        if ($DryRun) {
            Write-Host "  [DRY RUN] Would bump: $current → $newVersion" -ForegroundColor DarkGray
            Write-Host "  [DRY RUN] Would commit: $commitMsg" -ForegroundColor DarkGray
            Write-Host "  [DRY RUN] Would tag: $tag" -ForegroundColor DarkGray
            if (-not $NoPush) {
                Write-Host "  [DRY RUN] Would push commit + tag" -ForegroundColor DarkGray
            }
            Write-Host "`n  Then run the Release Manager workflow:" -ForegroundColor Gray
            Write-Host "    gh workflow run release-manager.yml -f version=$newVersion" -ForegroundColor White
            return
        }

        # 1. Bump versions
        Write-Host "  📝 Updating version files..." -ForegroundColor Gray
        $changes = Set-AllVersions -NewVersion $newVersion
        $changes | ForEach-Object { Write-Host "     • $_" -ForegroundColor DarkGray }

        # 2. Commit
        Write-Host "  📦 Committing..." -ForegroundColor Gray
        git -C $projectRoot add VERSION AitherZero/AitherZero.psd1 package.json 2>$null
        $hasDiff = git -C $projectRoot diff --cached --quiet 2>$null; $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) {
            git -C $projectRoot commit -m $commitMsg
        }

        # 3. Tag
        Write-Host "  🏷️  Tagging: $tag..." -ForegroundColor Gray
        git -C $projectRoot tag -a $tag -m "Release $newVersion"

        # 4. Push
        if (-not $NoPush) {
            Write-Host "  ⬆️  Pushing..." -ForegroundColor Gray
            git -C $projectRoot push origin HEAD
            git -C $projectRoot push origin $tag
        }

        Write-Host "`n✅ Release $newVersion prepared!" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Next steps:" -ForegroundColor Cyan
        Write-Host "    1. Go to Actions → 'Release Manager' → Run workflow" -ForegroundColor White
        Write-Host "    2. Enter version: $newVersion" -ForegroundColor White
        Write-Host "    Or via CLI:" -ForegroundColor Gray
        Write-Host "      gh workflow run release-manager.yml -f version=$newVersion -f release_type=stable" -ForegroundColor White
    }

    "history" {
        Write-Host "`n📜 Release History" -ForegroundColor Cyan
        Write-Host "─────────────────────────" -ForegroundColor DarkGray

        try {
            $tags = git -C $projectRoot tag -l "v*" --sort=-v:refname 2>$null
            if ($tags) {
                $tags | ForEach-Object {
                    $tagDate = git -C $projectRoot log -1 --format="%ci" $_ 2>$null
                    $shortDate = if ($tagDate) { ($tagDate -split ' ')[0] } else { "unknown" }
                    $tagMsg = git -C $projectRoot tag -l --format="%(contents:subject)" $_ 2>$null

                    $line = "  $shortDate  $_"
                    if ($tagMsg) { $line += "  — $tagMsg" }
                    Write-Host $line -ForegroundColor Gray
                }
            } else {
                Write-Host "  No release tags found" -ForegroundColor Yellow
            }
        } catch {
            Write-Warning "Could not read git tags: $_"
        }

        Write-Host ""
    }
}
