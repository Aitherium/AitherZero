#Requires -Version 7.0

<#
.SYNOPSIS
    Packages a curated public-safe release bundle from the monorepo.

.DESCRIPTION
    Reads a bundle manifest from public-release/, copies the curated files into a
    staging directory, writes bundle metadata, optionally zips the result, and
    can trigger the public aither sync workflow.

    Exit Codes:
    0 - Success
    1 - Failure
    2 - Execution error

.PARAMETER BundleName
    Name of the bundle manifest without the .manifest.json suffix.

.PARAMETER Version
    Optional version label for the output folder and zip name.

.PARAMETER OutputPath
    Output directory for generated bundles.

.PARAMETER Tag
    Optional git tag to pass to sync-alpha.yml when TriggerAitherSync is used.

.PARAMETER Branch
    Branch/ref to use when triggering the GitHub workflow.

.PARAMETER DryRun
    Show what would be packaged without writing files.

.PARAMETER SkipZip
    Skip zip creation after assembling the bundle.

.PARAMETER TriggerAitherSync
    Trigger sync-alpha.yml after packaging completes.

.NOTES
    Stage: Development
    Order: 0707
    Dependencies: 0706
    Tags: git, release, public, packaging, roboflow
    AllowParallel: false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$BundleName = 'roboflow-local-demo',

    [Parameter()]
    [string]$Version,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [string]$Tag,

    [Parameter()]
    [string]$Branch = 'develop',

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$SkipZip,

    [Parameter()]
    [switch]$TriggerAitherSync,

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
$ManifestPath = Join-Path $ProjectRoot "public-release/$BundleName.manifest.json"

if (-not (Test-Path $ManifestPath)) {
    throw "Bundle manifest not found: $ManifestPath"
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $ProjectRoot 'artifacts/public-release'
}

$manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$label = if ($Version) { $Version } else { (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') }
$safeLabel = (($label -replace '[^A-Za-z0-9._-]', '-') -replace '^-+', '').Trim()
if (-not $safeLabel) {
    throw 'Version label resolved to an empty value.'
}

$bundleRoot = Join-Path $OutputPath "$BundleName-$safeLabel"
$zipPath = "$bundleRoot.zip"
$entries = @($manifest.entries)

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    if (Test-Path $bundleRoot) {
        Remove-Item -Path $bundleRoot -Recurse -Force
    }
}

Write-Host "Packaging bundle '$BundleName'" -ForegroundColor Cyan
Write-Host "  Manifest: $ManifestPath" -ForegroundColor DarkGray
Write-Host "  Output:   $bundleRoot" -ForegroundColor DarkGray

foreach ($entry in $entries) {
    $sourcePath = Join-Path $ProjectRoot $entry.source
    if (-not (Test-Path $sourcePath)) {
        throw "Manifest source missing: $sourcePath"
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] $($entry.source) -> $($entry.target)" -ForegroundColor Yellow
        continue
    }

    $destinationPath = Join-Path $bundleRoot $entry.target
    $destinationDir = Split-Path $destinationPath -Parent
    if (-not (Test-Path $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    Copy-Item -Path $sourcePath -Destination $destinationPath -Force
}

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $bundleRoot -Force | Out-Null
    Copy-Item -Path $ManifestPath -Destination (Join-Path $bundleRoot 'manifest.json') -Force

    $bundleInfo = [ordered]@{
        bundleName   = $BundleName
        version      = $label
        gitTag       = $Tag
        branch       = $Branch
        generatedAt  = (Get-Date).ToUniversalTime().ToString('o')
        commit       = (git -C $ProjectRoot rev-parse --short HEAD 2>$null)
        manifestPath = (Resolve-Path $ManifestPath).Path
        entries      = $entries.Count
    }
    $bundleInfo | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bundleRoot 'bundle-info.json')

    if ((Test-Path $zipPath) -and -not $SkipZip) {
        Remove-Item $zipPath -Force
    }

    if (-not $SkipZip) {
        Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $zipPath -Force
        Write-Host "  Zip:      $zipPath" -ForegroundColor Green
    }
}

if ($TriggerAitherSync) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required to trigger sync-alpha.yml.'
    }

    $workflowArgs = @('workflow', 'run', 'sync-alpha.yml', '--ref', $Branch)
    if ($Tag) {
        $workflowArgs += @('-f', "tag=$Tag")
    }

    if ($DryRun) {
        Write-Host "  [DRY RUN] gh $($workflowArgs -join ' ')" -ForegroundColor Yellow
    } else {
        gh @workflowArgs | Out-Null
        Write-Host '  Triggered sync-alpha.yml' -ForegroundColor Green
    }
}

if ($PassThru) {
    [pscustomobject]@{
        BundleName = $BundleName
        OutputPath = $bundleRoot
        ZipPath    = if ($SkipZip) { $null } else { $zipPath }
        Manifest   = $ManifestPath
        EntryCount = $entries.Count
        DryRun     = [bool]$DryRun
    }
}