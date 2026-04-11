#Requires -Version 7.0
<#
.SYNOPSIS
    Post-installation provisioning — RBAC seeding and knowledge ingestion.

.DESCRIPTION
    Runs after AitherOS services are up. Waits for Genesis to be healthy,
    then seeds RBAC users/roles from the partner profile and ingests
    any knowledge documents into the RAG pipeline.

.NOTES
    Category: deploy
    Dependencies: Genesis running at localhost:8001
    Platform: Windows, Linux, macOS
    Script: 3034
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

Write-Host ""
Write-Host "[Post-Install] Waiting for Genesis to be healthy..." -ForegroundColor Yellow

$genesisUrl = "http://localhost:8001"
$maxWait = 120  # seconds
$waited = 0
$healthy = $false

while ($waited -lt $maxWait) {
    try {
        $response = Invoke-RestMethod -Uri "$genesisUrl/health" -TimeoutSec 5 -ErrorAction Stop
        if ($response) {
            $healthy = $true
            break
        }
    }
    catch {
        # Not ready yet
    }
    Start-Sleep -Seconds 5
    $waited += 5
    Write-Host "  Waiting... ($waited/${maxWait}s)" -ForegroundColor DarkGray
}

if (-not $healthy) {
    Write-Host "[Post-Install] Genesis not reachable after ${maxWait}s — deferring RBAC/knowledge" -ForegroundColor DarkYellow
    Write-Host "  Run manually after services start:" -ForegroundColor DarkGray
    Write-Host "    curl -X POST http://localhost:8001/partner/profile/apply" -ForegroundColor DarkGray
    Write-Host "    curl -X POST http://localhost:8001/partner/knowledge/ingest" -ForegroundColor DarkGray
    return
}

Write-Host "[Post-Install] Genesis is healthy" -ForegroundColor Green

# RBAC seeding
if ($env:AITHER_PARTNER_PROFILE -and (Test-Path "$env:AITHER_PARTNER_PROFILE/profile.yaml")) {
    Write-Host "[Post-Install] Seeding RBAC from partner profile..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod -Uri "$genesisUrl/partner/profile/apply" -Method POST `
            -ContentType "application/json" -Body '{}' -TimeoutSec 30 -ErrorAction Stop
        Write-Host "  OK: RBAC seeded" -ForegroundColor Green
    }
    catch {
        Write-Host "  WARN: RBAC seeding failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # Knowledge ingestion
    Write-Host "[Post-Install] Ingesting knowledge documents..." -ForegroundColor Yellow
    try {
        $result = Invoke-RestMethod -Uri "$genesisUrl/partner/knowledge/ingest" -Method POST `
            -ContentType "application/json" -Body '{}' -TimeoutSec 60 -ErrorAction Stop
        if ($result.ingested) {
            Write-Host "  OK: $($result.file_count) documents ingested" -ForegroundColor Green
        }
        else {
            Write-Host "  No knowledge documents to ingest" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  WARN: Knowledge ingestion failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}
else {
    Write-Host "[Post-Install] No partner profile — skipping RBAC/knowledge" -ForegroundColor DarkGray
}

Write-Host "[Post-Install] Done" -ForegroundColor Green
