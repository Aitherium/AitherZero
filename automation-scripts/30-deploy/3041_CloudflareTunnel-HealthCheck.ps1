#Requires -Version 7.0
<#
.SYNOPSIS
    Periodic health check for Cloudflare Tunnel routes with auto-heal.

.DESCRIPTION
    Designed to run on a schedule (cron/Task Scheduler/AitherScheduler).
    Checks every route in tunnel-routes.yaml, detects drift from live config,
    and optionally auto-syncs if routes go missing.

    Flow:
    1. Read tunnel-routes.yaml (source of truth)
    2. Fetch live config from CF API
    3. Compare — detect missing/extra/changed routes
    4. Health-check each route endpoint
    5. If drift detected + AutoSync: push tunnel-routes.yaml to CF
    6. If unhealthy containers: optionally restart them
    7. Report results to Pulse + Flux

.PARAMETER AutoSync
    If drift is detected (routes missing from live), automatically re-push
    the tunnel-routes.yaml config. Default: true.

.PARAMETER AutoRestart
    If a route's backing container is unhealthy, restart it. Default: false.

.PARAMETER ReportOnly
    Just output the report, don't take any corrective action.

.PARAMETER Quiet
    Suppress output (for cron). Results are still sent to Pulse/Flux.

.EXAMPLE
    # Scheduled health check with auto-sync
    .\3041_CloudflareTunnel-HealthCheck.ps1

.EXAMPLE
    # Manual check, report only
    .\3041_CloudflareTunnel-HealthCheck.ps1 -ReportOnly
#>
[CmdletBinding()]
param(
    [switch]$AutoSync = $true,
    [switch]$AutoRestart,
    [switch]$ReportOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot  = (Resolve-Path "$PSScriptRoot/../../../../").Path
$ConfigPath   = Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml"
$SyncScript   = Join-Path $PSScriptRoot "3040_Sync-CloudflareTunnel.ps1"
$SslScript    = Join-Path $PSScriptRoot "3042_Enforce-CloudflareSSL.ps1"
$BackupDir    = Join-Path $ProjectRoot "AitherOS/config/tunnel-backups"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    if (-not $Quiet) {
        $color = switch ($Level) {
            "ERROR"   { "Red" }
            "WARN"    { "Yellow" }
            "OK"      { "Green" }
            default   { "Gray" }
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $color
    }
}

# ── 1. Parse local config ─────────────────────────────────────────────
Write-Log "Reading tunnel-routes.yaml..."
if (-not (Test-Path $ConfigPath)) {
    Write-Log "Config file not found: $ConfigPath" -Level ERROR
    exit 1
}

$yamlContent = Get-Content $ConfigPath -Raw
$localRoutes = @{}
$routeBlocks = [regex]::Matches($yamlContent, '(?m)^\s+-\s+hostname:\s+(.+)\n\s+service:\s+(.+)')
foreach ($m in $routeBlocks) {
    $localRoutes[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim()
}

# Parse health check endpoints
$healthChecks = @{}
$hcBlocks = [regex]::Matches($yamlContent, '(?ms)^\s+-\s+hostname:\s+(.+?)\n\s+service:\s+(.+?)\n\s+description:.*?\n\s+health_check:\s+(.+?)\n\s+critical:\s+(.+)')
foreach ($m in $hcBlocks) {
    $healthChecks[$m.Groups[1].Value.Trim()] = @{
        service      = $m.Groups[2].Value.Trim()
        health_path  = $m.Groups[3].Value.Trim()
        critical     = $m.Groups[4].Value.Trim() -eq "true"
    }
}

Write-Log "Local config: $($localRoutes.Count) routes"

# ── 2. Fetch live config from CF API ──────────────────────────────────
Write-Log "Fetching live tunnel config from Cloudflare..."

$EnvFile = Join-Path $ProjectRoot ".env"
$apiToken  = $env:CLOUDFLARE_API_TOKEN
$accountId = $env:CLOUDFLARE_ACCOUNT_ID
$tunnelId  = $env:CLOUDFLARE_TUNNEL_ID

if (Test-Path $EnvFile) {
    $envContent = Get-Content $EnvFile -Raw
    if (-not $apiToken  -and $envContent -match 'CLOUDFLARE_API_TOKEN=(.+)')  { $apiToken  = $Matches[1].Trim() }
    if (-not $accountId -and $envContent -match 'CLOUDFLARE_ACCOUNT_ID=(.+)') { $accountId = $Matches[1].Trim() }
    if (-not $tunnelId  -and $envContent -match 'CLOUDFLARE_TUNNEL_ID=(.+)')  { $tunnelId  = $Matches[1].Trim() }
}

if (-not $apiToken -or -not $accountId -or -not $tunnelId) {
    Write-Log "Missing CF credentials — cannot check live config" -Level ERROR
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $apiToken"
    "Content-Type"  = "application/json"
}
$cfUri = "https://api.cloudflare.com/client/v4/accounts/$accountId/cfd_tunnel/$tunnelId/configurations"

try {
    $resp = Invoke-RestMethod -Uri $cfUri -Headers $headers -Method GET
    $liveIngress = $resp.result.config.ingress
} catch {
    Write-Log "Failed to fetch live config: $_" -Level ERROR
    exit 1
}

$liveRoutes = @{}
foreach ($r in $liveIngress) {
    if ($r.hostname) { $liveRoutes[$r.hostname] = $r.service }
}

Write-Log "Live config: $($liveRoutes.Count) routes"

# ── 3. Drift detection ────────────────────────────────────────────────
$missing = @()   # In local but not live
$extra   = @()   # In live but not local
$changed = @()   # Different service target

foreach ($host in $localRoutes.Keys) {
    if (-not $liveRoutes.ContainsKey($host)) {
        $missing += $host
    } elseif ($liveRoutes[$host] -ne $localRoutes[$host]) {
        $changed += @{ hostname = $host; live = $liveRoutes[$host]; local = $localRoutes[$host] }
    }
}
foreach ($host in $liveRoutes.Keys) {
    if (-not $localRoutes.ContainsKey($host)) {
        $extra += $host
    }
}

$driftDetected = ($missing.Count -gt 0) -or ($changed.Count -gt 0) -or ($extra.Count -gt 0)

if ($driftDetected) {
    Write-Log "⚠ DRIFT DETECTED" -Level WARN
    foreach ($h in $missing) { Write-Log "  MISSING from live: $h → $($localRoutes[$h])" -Level WARN }
    foreach ($c in $changed) { Write-Log "  CHANGED: $($c.hostname) live=$($c.live) local=$($c.local)" -Level WARN }
    foreach ($h in $extra)   { Write-Log "  EXTRA in live (not in config): $h → $($liveRoutes[$h])" -Level WARN }
} else {
    Write-Log "No drift — live matches tunnel-routes.yaml" -Level OK
}

# ── 4. Health check each route ────────────────────────────────────────
Write-Log "Running health checks..."

$healthResults = @()
foreach ($host in $localRoutes.Keys) {
    $hcMeta = $healthChecks[$host]
    $healthPath = if ($hcMeta) { $hcMeta.health_path } else { "/health" }
    $critical   = if ($hcMeta) { $hcMeta.critical } else { $false }
    $service    = $localRoutes[$host]

    $status = "unknown"
    $httpCode = 0

    try {
        $publicUrl = "https://$host$healthPath"
        $r = Invoke-WebRequest -Uri $publicUrl -TimeoutSec 10 -SkipHttpErrorCheck -MaximumRedirection 0
        $httpCode = $r.StatusCode
        $status = if ($httpCode -ge 200 -and $httpCode -lt 400) { "healthy" }
                 elseif ($httpCode -in @(301, 302, 307, 308)) { "auth-gated" }
                 else { "unhealthy" }
    } catch {
        $status = "unreachable"
    }

    $healthResults += @{
        hostname  = $host
        service   = $service
        status    = $status
        http_code = $httpCode
        critical  = $critical
    }

    $levelStr = switch ($status) { "healthy" { "OK" }; "auth-gated" { "INFO" }; default { "ERROR" } }
    Write-Log "  $host → $status ($httpCode)" -Level $levelStr
}

$unhealthyCritical = $healthResults | Where-Object { $_.status -in @("unhealthy", "unreachable") -and $_.critical }
$unhealthyAny      = $healthResults | Where-Object { $_.status -in @("unhealthy", "unreachable") }

# ── 5. Auto-sync if drift detected ───────────────────────────────────
if ($driftDetected -and $AutoSync -and -not $ReportOnly) {
    Write-Log "Auto-syncing tunnel-routes.yaml → Cloudflare..." -Level WARN
    try {
        & $SyncScript -Action sync -Force
        Write-Log "Auto-sync completed" -Level OK
    } catch {
        Write-Log "Auto-sync FAILED: $_" -Level ERROR
    }
}

# ── 6. Auto-restart unhealthy containers ──────────────────────────────
if ($unhealthyAny.Count -gt 0 -and $AutoRestart -and -not $ReportOnly) {
    foreach ($route in $unhealthyAny) {
        # Extract container name from service URL: http://aitheros-foo:1234 → aitheros-foo
        if ($route.service -match 'http://([^:]+):\d+') {
            $containerName = $Matches[1]
            Write-Log "Restarting unhealthy container: $containerName" -Level WARN
            try {
                docker restart $containerName 2>&1 | Out-Null
                Write-Log "  Restarted $containerName" -Level OK
            } catch {
                Write-Log "  Failed to restart $containerName: $_" -Level ERROR
            }
        }
    }
}

# ── 7. Report to Pulse/Flux ──────────────────────────────────────────
$report = @{
    timestamp       = (Get-Date).ToUniversalTime().ToString("o")
    drift_detected  = $driftDetected
    missing_routes  = $missing
    extra_routes    = $extra
    changed_routes  = $changed
    health_results  = $healthResults
    unhealthy_count = $unhealthyAny.Count
    critical_unhealthy = $unhealthyCritical.Count
    auto_synced     = ($driftDetected -and $AutoSync -and -not $ReportOnly)
}

# Try to send to Pulse
if ($unhealthyCritical.Count -gt 0 -or $driftDetected) {
    try {
        $pulsePayload = @{
            service    = "cloudflare-tunnel"
            alert_type = if ($unhealthyCritical.Count -gt 0) { "tunnel_route_unhealthy" } else { "tunnel_config_drift" }
            severity   = if ($unhealthyCritical.Count -gt 0) { "critical" } else { "warning" }
            message    = "Tunnel health check: drift=$driftDetected, unhealthy=$($unhealthyAny.Count)"
            details    = $report
            timestamp  = (Get-Date).ToUniversalTime().ToString("o")
        }
        Invoke-RestMethod -Uri "http://localhost:8081/alerts/webhook" -Method POST `
            -Body ($pulsePayload | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType "application/json" -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
    } catch { }
}

# ── 8. Summary ────────────────────────────────────────────────────────
$healthy = ($healthResults | Where-Object { $_.status -eq "healthy" }).Count
$gated   = ($healthResults | Where-Object { $_.status -eq "auth-gated" }).Count
$total   = $healthResults.Count

# ── 8.5. SSL/TLS Hardening Check ──────────────────────────────────────
$sslDrift = $false
if (Test-Path $SslScript) {
    Write-Log "Checking Cloudflare SSL/TLS hardening..."
    try {
        & $SslScript -Action verify 2>&1 | Out-Null
        $sslExitCode = $LASTEXITCODE
        if ($sslExitCode -ne 0) {
            Write-Log "SSL/TLS drift detected — enforcing..." -Level WARN
            $sslDrift = $true
            if (-not $ReportOnly) {
                & $SslScript -Action enforce 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "SSL/TLS hardening enforced successfully" -Level OK
                } else {
                    Write-Log "SSL/TLS enforcement failed" -Level ERROR
                }
            }
        } else {
            Write-Log "SSL/TLS settings compliant" -Level OK
        }
    } catch {
        Write-Log "SSL/TLS check failed: $_" -Level WARN
    }
} else {
    Write-Log "SSL enforcement script not found at: $SslScript" -Level WARN
}

Write-Log ""
Write-Log "━━━ Summary ━━━" -Level INFO
Write-Log "  Routes: $total total, $healthy healthy, $gated auth-gated, $($unhealthyAny.Count) unhealthy"
Write-Log "  Drift: $(if ($driftDetected) { 'YES — ' + $missing.Count + ' missing, ' + $changed.Count + ' changed' } else { 'None' })"
Write-Log "  SSL/TLS: $(if ($sslDrift) { 'DRIFT DETECTED (auto-enforced)' } else { 'Compliant' })"
if ($unhealthyCritical.Count -gt 0) {
    Write-Log "  ⚠ $($unhealthyCritical.Count) CRITICAL route(s) unhealthy!" -Level ERROR
}

exit $(if ($unhealthyCritical.Count -gt 0) { 2 } elseif ($driftDetected -or $sslDrift) { 1 } else { 0 })
