# Basic Build Script
param([string]$OutputPath = './bin')

$ProjectName = 'AitherZero.Agents.CLI'
Write-Host "Building $ProjectName..."

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Copy to bin (simulation of build)
Copy-Item -Path "./$ProjectName.psm1" -Destination "$OutputPath/$ProjectName.psm1" -Force
Copy-Item -Path "./$ProjectName.psd1" -Destination "$OutputPath/$ProjectName.psd1" -Force

Write-Host "Build complete."
