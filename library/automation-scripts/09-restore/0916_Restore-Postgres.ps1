#Requires -Version 7.0
<#
.SYNOPSIS
    Restores PostgreSQL from a pg_dumpall SQL backup.

.DESCRIPTION
    Starts ONLY the Postgres container (via docker compose), waits for it to
    become healthy, then pipes the SQL dump through psql to restore all databases.

    The dump is a pg_dumpall output with --clean --if-exists, so it drops and
    recreates databases/roles/tables automatically.

    After restore, stops the standalone Postgres container (the full bootstrap
    will start it properly with dependencies).

.PARAMETER DumpPath
    Path to the SQL dump file (e.g., data/backups/postgres/latest.sql).

.PARAMETER ComposeFile
    Path to docker-compose.aitheros.yml. Defaults to project root.

.PARAMETER TargetDir
    Project root directory. Defaults to detected project root.

.PARAMETER KeepRunning
    Don't stop Postgres after restore (useful if starting services immediately after).

.EXAMPLE
    .\0916_Restore-Postgres.ps1 -DumpPath D:\backup\postgres\latest.sql
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DumpPath,

    [string]$ComposeFile,
    [string]$TargetDir,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'

# ── Init ────────────────────────────────────────────────────────────────────
$initScript = Join-Path $PSScriptRoot "../_init.ps1"
if (Test-Path $initScript) { . $initScript }

if (-not $TargetDir) {
    $TargetDir = if ($projectRoot) { $projectRoot } else { $PWD.Path }
}

if (-not $ComposeFile) {
    $ComposeFile = Join-Path $TargetDir "docker-compose.aitheros.yml"
}

if (-not (Test-Path $DumpPath)) {
    Write-Error "SQL dump not found: $DumpPath"
    exit 1
}

if (-not (Test-Path $ComposeFile)) {
    Write-Error "Docker Compose file not found: $ComposeFile"
    exit 1
}

$dumpSize = [math]::Round((Get-Item $DumpPath).Length / 1MB, 1)
Write-Host "Restoring Postgres from: $(Split-Path $DumpPath -Leaf) (${dumpSize} MB)" -ForegroundColor Cyan

# ── Load .env for Postgres password ───────────────────────────────────────
$envFile = Join-Path $TargetDir ".env"
$pgPassword = "aither_secret"  # fallback default

if (Test-Path $envFile) {
    $envLines = Get-Content $envFile
    foreach ($line in $envLines) {
        if ($line -match '^\s*POSTGRES_PASSWORD\s*=\s*(.+)$') {
            $pgPassword = $Matches[1].Trim('"', "'", ' ')
            break
        }
    }
}

# ── Start Postgres container only ─────────────────────────────────────────
Write-Host "[1/4] Starting Postgres container..." -ForegroundColor Cyan

# Ensure data directory exists
$pgDataDir = Join-Path $TargetDir "data/postgres"
if (-not (Test-Path $pgDataDir)) {
    New-Item -Path $pgDataDir -ItemType Directory -Force | Out-Null
}

Push-Location $TargetDir
try {
    # Start only Postgres (and its deps like docker-socket-proxy)
    docker compose -f $ComposeFile up -d aitheros-postgres 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
} finally {
    Pop-Location
}

# ── Wait for Postgres healthy ─────────────────────────────────────────────
Write-Host "[2/4] Waiting for Postgres to be ready..." -ForegroundColor Cyan

$maxRetries = 30
$retryInterval = 3
$ready = $false

for ($i = 1; $i -le $maxRetries; $i++) {
    $health = docker inspect --format='{{.State.Health.Status}}' aitheros-postgres 2>&1
    if ($health -eq 'healthy') {
        $ready = $true
        Write-Host "  Postgres is healthy (attempt $i/$maxRetries)." -ForegroundColor Green
        break
    }
    # Also try a direct connection test
    $connTest = docker exec aitheros-postgres pg_isready -U aither 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ready = $true
        Write-Host "  Postgres is ready (attempt $i/$maxRetries)." -ForegroundColor Green
        break
    }
    Write-Host "  Waiting... ($i/$maxRetries, status: $health)" -ForegroundColor Gray
    Start-Sleep -Seconds $retryInterval
}

if (-not $ready) {
    Write-Error "Postgres did not become healthy after $($maxRetries * $retryInterval) seconds."
    exit 2
}

# ── Restore from dump ────────────────────────────────────────────────────
Write-Host "[3/4] Restoring from SQL dump..." -ForegroundColor Cyan

# Copy dump into container then run psql
$containerDumpPath = "/tmp/restore_dump.sql"

docker cp $DumpPath "aitheros-postgres:$containerDumpPath"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to copy dump file into Postgres container."
    exit 3
}

# Run restore via psql. pg_dumpall output includes DROP/CREATE, so this is safe.
# Use -v ON_ERROR_STOP=0 so it continues past expected errors (dropping non-existent objects)
$restoreOutput = docker exec -e PGPASSWORD=$pgPassword aitheros-postgres `
    psql -U aither -d postgres -f $containerDumpPath --echo-errors 2>&1

$exitCode = $LASTEXITCODE

# Clean up dump from container
docker exec aitheros-postgres rm -f $containerDumpPath 2>&1 | Out-Null

# Check for critical errors (ignore expected "does not exist" drops)
$criticalErrors = $restoreOutput | Where-Object {
    $_ -match 'ERROR' -and $_ -notmatch 'does not exist' -and $_ -notmatch 'already exists'
}

if ($criticalErrors.Count -gt 0) {
    Write-Warning "Restore completed with $($criticalErrors.Count) errors:"
    $criticalErrors | Select-Object -First 5 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  SQL restore completed successfully." -ForegroundColor Green
}

# ── Verify restore ───────────────────────────────────────────────────────
Write-Host "[4/4] Verifying restore..." -ForegroundColor Cyan

$dbList = docker exec -e PGPASSWORD=$pgPassword aitheros-postgres `
    psql -U aither -d postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>&1

$databases = ($dbList | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
Write-Host "  Databases found: $($databases -join ', ')" -ForegroundColor Green

# ── Optionally stop Postgres ─────────────────────────────────────────────
if (-not $KeepRunning) {
    Write-Host "Stopping standalone Postgres container (will restart during full boot)." -ForegroundColor Gray
    Push-Location $TargetDir
    docker compose -f $ComposeFile stop aitheros-postgres 2>&1 | Out-Null
    Pop-Location
}

return [PSCustomObject]@{
    Databases = $databases
    Errors    = $criticalErrors.Count
    Ok        = ($criticalErrors.Count -eq 0)
}
