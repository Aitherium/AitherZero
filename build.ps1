#Requires -Version 7.0
param(
    [string]$SourcePath = "$PSScriptRoot/src",
    [string]$OutputPath = "$PSScriptRoot/bin",
    [string]$MetadataPath = "$PSScriptRoot/metadata.json"
)

$ErrorActionPreference = 'Stop'

Write-Host "Starting build process..." -ForegroundColor Cyan

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Read metadata
if (-not (Test-Path $MetadataPath)) {
    throw "Metadata file not found at $MetadataPath"
}
$metadata = Get-Content $MetadataPath -Raw | ConvertFrom-Json

# Initialize PSM1 content
$psm1Content = [System.Text.StringBuilder]::new()

# 1. Add Header
$psm1Content.AppendLine("#Requires -Version $($metadata.PowerShellVersion)") | Out-Null
$psm1Content.AppendLine("<#") | Out-Null
$psm1Content.AppendLine(".SYNOPSIS") | Out-Null
$psm1Content.AppendLine("    $($metadata.Description)") | Out-Null
$psm1Content.AppendLine(".NOTES") | Out-Null
$psm1Content.AppendLine("    Version: $($metadata.ModuleVersion)") | Out-Null
$psm1Content.AppendLine("    Author: $($metadata.Author)") | Out-Null
$psm1Content.AppendLine("    Copyright: $($metadata.Copyright)") | Out-Null
$psm1Content.AppendLine("#>") | Out-Null
$psm1Content.AppendLine("") | Out-Null

# 2. Add Startup Script
$startupPath = Join-Path $SourcePath "Startup.ps1"
if (Test-Path $startupPath) {
    Write-Host "Adding Startup.ps1..." -ForegroundColor Green
    $psm1Content.AppendLine("# region Startup") | Out-Null
    $psm1Content.AppendLine((Get-Content $startupPath -Raw)) | Out-Null
    $psm1Content.AppendLine("# endregion Startup") | Out-Null
    $psm1Content.AppendLine("") | Out-Null
}

# 3. Add Private Functions
$privateFiles = Get-ChildItem -Path (Join-Path $SourcePath "private") -Filter "*.ps1" -Recurse
foreach ($file in $privateFiles) {
    Write-Host "Adding Private function: $($file.Name)" -ForegroundColor Gray
    $psm1Content.AppendLine("# region Private: $($file.Name)") | Out-Null
    $psm1Content.AppendLine((Get-Content $file.FullName -Raw)) | Out-Null
    $psm1Content.AppendLine("# endregion Private: $($file.Name)") | Out-Null
    $psm1Content.AppendLine("") | Out-Null
}

# 4. Add Public Functions and collect names for export
$publicFiles = Get-ChildItem -Path (Join-Path $SourcePath "public") -Filter "*.ps1" -Recurse
$functionsToExport = @()

foreach ($file in $publicFiles) {
    Write-Host "Adding Public function: $($file.Name)" -ForegroundColor Green
    $psm1Content.AppendLine("# region Public: $($file.Name)") | Out-Null
    $psm1Content.AppendLine((Get-Content $file.FullName -Raw)) | Out-Null
    $psm1Content.AppendLine("# endregion Public: $($file.Name)") | Out-Null
    $psm1Content.AppendLine("") | Out-Null

    $functionsToExport += $file.BaseName
}

# 5. Export Module Members
$psm1Content.AppendLine("Export-ModuleMember -Function @(") | Out-Null
$exportList = $functionsToExport | ForEach-Object { "    '$_'" }
$psm1Content.AppendLine(($exportList -join ",`n")) | Out-Null
$psm1Content.AppendLine(") -Alias @('aither')") | Out-Null
$psm1Content.AppendLine("") | Out-Null

# 5b. Post-init: Load deferred plugins discovered during Startup
$psm1Content.AppendLine("# region Post-Init: Deferred Plugin Loading") | Out-Null
$psm1Content.AppendLine("if (`$script:_PendingPluginPaths) {") | Out-Null
$psm1Content.AppendLine("    foreach (`$pendingPath in `$script:_PendingPluginPaths) {") | Out-Null
$psm1Content.AppendLine("        try {") | Out-Null
$psm1Content.AppendLine("            Register-AitherPlugin -Path `$pendingPath -ErrorAction SilentlyContinue") | Out-Null
$psm1Content.AppendLine("        } catch {") | Out-Null
$psm1Content.AppendLine("            Write-Verbose `"Auto-load plugin from '`$pendingPath' failed: `$_`"") | Out-Null
$psm1Content.AppendLine("        }") | Out-Null
$psm1Content.AppendLine("    }") | Out-Null
$psm1Content.AppendLine("    Remove-Variable -Name '_PendingPluginPaths' -Scope Script -ErrorAction SilentlyContinue") | Out-Null
$psm1Content.AppendLine("}") | Out-Null
$psm1Content.AppendLine("# endregion Post-Init") | Out-Null
$psm1Content.AppendLine("") | Out-Null

# Write PSM1
$psm1Path = Join-Path $OutputPath "AitherZero.psm1"
Set-Content -Path $psm1Path -Value $psm1Content.ToString()
Write-Host "Created $psm1Path" -ForegroundColor Cyan

# Copy to root for development convenience
$rootPsm1Path = Join-Path $PSScriptRoot "AitherZero.psm1"
Copy-Item -Path $psm1Path -Destination $rootPsm1Path -Force
Write-Host "Updated root module: $rootPsm1Path" -ForegroundColor Cyan

# 6. Generate PSD1
$psd1Path = Join-Path $OutputPath "AitherZero.psd1"
$manifest = @{
    RootModule = "AitherZero.psm1"
    ModuleVersion = $metadata.ModuleVersion
    GUID = $metadata.GUID
    Author = $metadata.Author
    CompanyName = $metadata.CompanyName
    Copyright = $metadata.Copyright
    Description = $metadata.Description
    PowerShellVersion = $metadata.PowerShellVersion
    CompatiblePSEditions = $metadata.CompatiblePSEditions
    FunctionsToExport = $functionsToExport
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
}

# Helper to format array for PSD1
function Format-Psd1Array {
    param($Array, $Indent = 8)
    if ($null -eq $Array -or $Array.Count -eq 0) { return "@()" }
    $spaces = " " * $Indent
    $items = $Array | ForEach-Object { "$spaces'$_'" }
    return "@(`n" + ($items -join "`n") + "`n$($spaces.Substring(0, $spaces.Length - 4)))"
}

# Create PSD1 content manually to ensure proper formatting
$psd1Content = @"
@{
    RootModule           = '$($manifest.RootModule)'
    ModuleVersion        = '$($manifest.ModuleVersion)'
    GUID                 = '$($manifest.GUID)'
    Author               = '$($manifest.Author)'
    CompanyName          = '$($manifest.CompanyName)'
    Copyright            = '$($manifest.Copyright)'
    Description          = '$($manifest.Description)'
    PowerShellVersion    = '$($manifest.PowerShellVersion)'
    CompatiblePSEditions = $(Format-Psd1Array $manifest.CompatiblePSEditions)
    FunctionsToExport    = $(Format-Psd1Array $manifest.FunctionsToExport)
    CmdletsToExport      = @()
    VariablesToExport    = '*'
    AliasesToExport      = @()
}
"@

Set-Content -Path $psd1Path -Value $psd1Content
Write-Host "Created $psd1Path" -ForegroundColor Cyan

# Copy to root for development convenience
$rootPsd1Path = Join-Path $PSScriptRoot "AitherZero.psd1"
Set-Content -Path $rootPsd1Path -Value $psd1Content
Write-Host "Updated root manifest: $rootPsd1Path" -ForegroundColor Cyan

Write-Host "Build complete!" -ForegroundColor Green
