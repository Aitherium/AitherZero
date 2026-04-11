#!/usr/bin/env pwsh
# Restart Veil with workflow access
# Run this after Docker Desktop is running

Write-Host "=== Restarting Veil with Workflow Access ===" -ForegroundColor Yellow

cd $PSScriptRoot\..\docker

Write-Host "`n[1] Stopping Veil..." -ForegroundColor Cyan
docker compose stop veil 2>&1 | Out-Null

Write-Host "[2] Removing old Veil container..." -ForegroundColor Cyan
docker compose rm -f veil 2>&1 | Out-Null

Write-Host "[3] Starting Veil with new configuration..." -ForegroundColor Cyan
docker compose up -d --force-recreate veil

Start-Sleep -Seconds 10

Write-Host "`n[4] Verifying workflow access..." -ForegroundColor Cyan
$workflows = docker exec aitheros-veil ls /app/AitherOS/AitherNode/workflows/ 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✅ Workflows accessible:" -ForegroundColor Green
    $workflows | Select-Object -First 10 | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
} else {
    Write-Host "`n❌ Workflows not accessible. Check Docker logs:" -ForegroundColor Red
    docker logs aitheros-veil --tail 20
}

Write-Host "`n[5] Checking Veil health..." -ForegroundColor Cyan
$health = docker exec aitheros-veil wget --no-verbose --tries=1 --spider http://localhost:3000 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ Veil is healthy!" -ForegroundColor Green
} else {
    Write-Host "⚠️ Veil may still be starting. Check logs:" -ForegroundColor Yellow
    Write-Host "   docker logs aitheros-veil --tail 30" -ForegroundColor Gray
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Access Canvas at: http://localhost:3000" -ForegroundColor Cyan
