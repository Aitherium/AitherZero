#Requires -Version 7.0
<#
.SYNOPSIS
    Syncs Cloudflare Tunnel routes from config/tunnel-routes.yaml to the CF API.

.DESCRIPTION
    This script is the single management point for Cloudflare Tunnel configuration.
    It reads the canonical route definitions from AitherOS/config/tunnel-routes.yaml,
    backs up the current live config, pushes the new config to the CF API, and
    verifies all routes are healthy.

    Features:
    - Source-of-truth: tunnel-routes.yaml is the only place routes are defined
    - Auto-backup: every sync creates a timestamped backup for rollback
    - Health checks: verifies each route after deployment
    - Rollback: restore any previous config version
    - Diff: preview changes before pushing
    - DNS verification: optionally checks CNAME records

.PARAMETER Action
    What to do:
    - "sync"     : Push tunnel-routes.yaml to CF API (default)
    - "status"   : Show current live config vs local config
    - "diff"     : Show differences between live and local
    - "rollback" : Restore a previous backup
    - "health"   : Run health checks on all routes
    - "backup"   : Just backup current live config without pushing
    - "list"     : List available backups

.PARAMETER BackupId
    For rollback: the backup timestamp to restore (from -Action list).
    Use "latest" to restore the most recent backup.

.PARAMETER DryRun
    Show what would be pushed without actually calling the CF API.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER EnsureDNS
    After syncing, verify CNAME records exist for all hostnames.

.EXAMPLE
    # Push current config to CF
    .\3040_Sync-CloudflareTunnel.ps1

.EXAMPLE
    # Preview changes
    .\3040_Sync-CloudflareTunnel.ps1 -Action diff

.EXAMPLE
    # Rollback to last known good
    .\3040_Sync-CloudflareTunnel.ps1 -Action rollback -BackupId latest

.EXAMPLE
    # Health check all routes
    .\3040_Sync-CloudflareTunnel.ps1 -Action health
#>
[CmdletBinding()]
param(
    [ValidateSet("sync", "status", "diff", "rollback", "health", "backup", "list")]
    [string]$Action = "sync",

    [string]$BackupId = "",

    [switch]$DryRun,
    [switch]$Force,
    [switch]$EnsureDNS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Paths ─────────────────────────────────────────────────────────────────
$ProjectRoot = (Resolve-Path "$PSScriptRoot/../../../../").Path
$ConfigPath  = Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml"
$BackupDir   = Join-Path $ProjectRoot "AitherOS/config/tunnel-backups"
$EnvFile     = Join-Path $ProjectRoot ".env"

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

# ── Helpers ───────────────────────────────────────────────────────────────

function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

function Get-CfCredentials {
    <#
    .SYNOPSIS
        Resolve CF API token, account ID, and tunnel ID from env/.env/secrets.
    #>
    $creds = @{
        ApiToken  = $env:CLOUDFLARE_API_TOKEN
        AccountId = $env:CLOUDFLARE_ACCOUNT_ID
        TunnelId  = $env:CLOUDFLARE_TUNNEL_ID
    }

    # Try .env file
    if (Test-Path $EnvFile) {
        $envContent = Get-Content $EnvFile -Raw
        if (-not $creds.ApiToken) {
            if ($envContent -match 'CLOUDFLARE_API_TOKEN=(.+)') { $creds.ApiToken = $Matches[1].Trim() }
        }
        if (-not $creds.AccountId) {
            if ($envContent -match 'CLOUDFLARE_ACCOUNT_ID=(.+)') { $creds.AccountId = $Matches[1].Trim() }
        }
        if (-not $creds.TunnelId) {
            if ($envContent -match 'CLOUDFLARE_TUNNEL_ID=(.+)') { $creds.TunnelId = $Matches[1].Trim() }
        }
    }

    # Try AitherSecrets (localhost:8111)
    foreach ($key in @("CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_TUNNEL_ID")) {
        $prop = switch ($key) {
            "CLOUDFLARE_API_TOKEN"  { "ApiToken" }
            "CLOUDFLARE_ACCOUNT_ID" { "AccountId" }
            "CLOUDFLARE_TUNNEL_ID"  { "TunnelId" }
        }
        if (-not $creds[$prop]) {
            try {
                $resp = Invoke-RestMethod -Uri "http://localhost:8111/secrets/$key" -TimeoutSec 3 -ErrorAction SilentlyContinue
                if ($resp.value) { $creds[$prop] = $resp.value }
            } catch { }
        }
    }

    # Validate
    $missing = @()
    if (-not $creds.ApiToken)  { $missing += "CLOUDFLARE_API_TOKEN" }
    if (-not $creds.AccountId) { $missing += "CLOUDFLARE_ACCOUNT_ID" }
    if (-not $creds.TunnelId)  { $missing += "CLOUDFLARE_TUNNEL_ID" }

    if ($missing.Count -gt 0) {
        Write-Bad "Missing credentials: $($missing -join ', ')"
        Write-Info "Set them in .env, environment variables, or AitherSecrets."
        throw "Missing Cloudflare credentials"
    }

    return $creds
}

function Read-TunnelConfig {
    <#
    .SYNOPSIS
        Parse tunnel-routes.yaml into an ingress array for the CF API.
    #>
    if (-not (Test-Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    # Use powershell-yaml if available, else parse manually
    $yamlContent = Get-Content $ConfigPath -Raw

    try {
        Import-Module powershell-yaml -ErrorAction Stop
        $config = ConvertFrom-Yaml $yamlContent
    } catch {
        # Fallback: simple regex parsing for our known format
        $config = @{ routes = @() }
        $routeBlocks = [regex]::Matches($yamlContent, '(?m)^\s+-\s+hostname:\s+(.+)\n\s+service:\s+(.+)')
        foreach ($m in $routeBlocks) {
            $config.routes += @{
                hostname = $m.Groups[1].Value.Trim()
                service  = $m.Groups[2].Value.Trim()
            }
        }
        # Catchall
        if ($yamlContent -match 'catchall:\s*\n\s+service:\s+"?([^"\n]+)') {
            $config.catchall = @{ service = $Matches[1].Trim() }
        }
    }

    # Build CF API ingress array
    $ingress = @()
    foreach ($route in $config.routes) {
        $ingress += @{
            hostname = $route.hostname
            service  = $route.service
        }
    }
    # Add catchall (required)
    $catchallService = if ($config.catchall -and $config.catchall.service) { $config.catchall.service } else { "http_status:404" }
    $ingress += @{ service = $catchallService }

    return @{
        ingress  = $ingress
        metadata = $config
    }
}

function Get-HostnameRoutes {
    <#
    .SYNOPSIS
        Filter an ingress array to only routes that have a hostname.
        Works on both PSCustomObject (from CF API) and hashtables (from Read-TunnelConfig).
    #>
    param([array]$Ingress)
    $filtered = @()
    foreach ($r in $Ingress) {
        $h = $null
        if ($r -is [hashtable]) {
            if ($r.ContainsKey('hostname') -and $r['hostname']) { $h = $r['hostname'] }
        } else {
            try { $h = $r.hostname } catch { }
        }
        if ($h) { $filtered += $r }
    }
    return $filtered
}

function Sync-DnsRecords {
    <#
    .SYNOPSIS
        Ensure every hostname in the tunnel config has a CNAME DNS record
        pointing to <tunnel-id>.cfargotunnel.com. Creates missing records.
    #>
    param(
        [hashtable]$Creds,
        [array]$Hostnames
    )

    $headers = @{
        "Authorization" = "Bearer $($Creds.ApiToken)"
        "Content-Type"  = "application/json"
    }
    $tunnelTarget = "$($Creds.TunnelId).cfargotunnel.com"

    # Resolve zone ID for the domain
    $domain = ($Hostnames | Select-Object -First 1) -replace '^[^.]+\.', ''
    $zoneResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?name=$domain" -Headers $headers
    if (-not $zoneResp.result -or $zoneResp.result.Count -eq 0) {
        Write-Bad "Could not find zone for $domain"
        return
    }
    $zoneId = $zoneResp.result[0].id

    # Get all existing CNAME records in the zone
    $existingResp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=CNAME&per_page=100" -Headers $headers
    $existingNames = @($existingResp.result | ForEach-Object { $_.name })

    $created = 0
    foreach ($hostname in $Hostnames) {
        if ($hostname -in $existingNames) {
            Write-Info "  DNS: $hostname (exists)"
            continue
        }
        Write-Step "Creating DNS CNAME: $hostname → $tunnelTarget"
        $body = @{
            type    = "CNAME"
            name    = $hostname
            content = $tunnelTarget
            proxied = $true
            ttl     = 1
            comment = "Auto-created by 3040_Sync-CloudflareTunnel.ps1"
        } | ConvertTo-Json

        try {
            $result = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records" -Method Post -Headers $headers -Body $body
            if ($result.success) {
                Write-Good "  DNS: $hostname created"
                $created++
            } else {
                Write-Bad "  DNS: $hostname failed — $($result.errors[0].message)"
            }
        } catch {
            Write-Bad "  DNS: $hostname error — $($_.Exception.Message)"
        }
    }

    if ($created -gt 0) {
        Write-Good "Created $created DNS record(s)"
    } else {
        Write-Info "All DNS records already exist"
    }
}

function Get-LiveConfig {
    <#
    .SYNOPSIS
        Fetch the current tunnel configuration from CF API.
    #>
    param([hashtable]$Creds)

    $headers = @{
        "Authorization" = "Bearer $($Creds.ApiToken)"
        "Content-Type"  = "application/json"
    }
    $uri = "https://api.cloudflare.com/client/v4/accounts/$($Creds.AccountId)/cfd_tunnel/$($Creds.TunnelId)/configurations"

    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET
        if ($resp.success) {
            return $resp.result.config
        } else {
            throw "CF API error: $($resp.errors | ConvertTo-Json -Compress)"
        }
    } catch {
        throw "Failed to fetch live config: $_"
    }
}

function Push-TunnelConfig {
    <#
    .SYNOPSIS
        Push a new tunnel configuration to the CF API.
    #>
    param(
        [hashtable]$Creds,
        [array]$Ingress
    )

    $headers = @{
        "Authorization" = "Bearer $($Creds.ApiToken)"
        "Content-Type"  = "application/json"
    }
    $uri = "https://api.cloudflare.com/client/v4/accounts/$($Creds.AccountId)/cfd_tunnel/$($Creds.TunnelId)/configurations"

    $body = @{
        config = @{
            ingress = $Ingress
        }
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method PUT -Body $body
        if ($resp.success) {
            return $resp.result
        } else {
            throw "CF API error: $($resp.errors | ConvertTo-Json -Compress)"
        }
    } catch {
        throw "Failed to push config: $_"
    }
}

function Save-Backup {
    <#
    .SYNOPSIS
        Save a timestamped backup of the live tunnel config.
    #>
    param(
        [object]$LiveConfig,
        [string]$Label = "auto"
    )

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $filename = "tunnel-config_${ts}_${Label}.json"
    $path = Join-Path $BackupDir $filename

    $backup = @{
        timestamp    = (Get-Date).ToUniversalTime().ToString("o")
        label        = $Label
        config       = $LiveConfig
        backed_up_by = "3040_Sync-CloudflareTunnel.ps1"
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    Write-Good "Backup saved: $filename"

    # Keep only last 50 backups
    $allBackups = Get-ChildItem $BackupDir -Filter "tunnel-config_*.json" | Sort-Object Name -Descending
    if ($allBackups.Count -gt 50) {
        $allBackups | Select-Object -Skip 50 | Remove-Item -Force
        Write-Info "Pruned old backups (keeping last 50)"
    }

    return $path
}

function Test-RouteHealth {
    <#
    .SYNOPSIS
        Health-check each route by hitting its health endpoint.
    #>
    param([object]$Config)

    $yamlContent = Get-Content $ConfigPath -Raw
    $results = @()

    # Parse health check paths from YAML
    $routeBlocks = [regex]::Matches($yamlContent, '(?ms)^\s+-\s+hostname:\s+(.+?)\n\s+service:\s+(.+?)\n\s+description:.*?\n\s+health_check:\s+(.+?)\n\s+critical:\s+(.+)')
    $healthMap = @{}
    foreach ($m in $routeBlocks) {
        $healthMap[$m.Groups[1].Value.Trim()] = @{
            health_check = $m.Groups[3].Value.Trim()
            critical     = $m.Groups[4].Value.Trim() -eq "true"
        }
    }

    foreach ($route in (Get-HostnameRoutes -Ingress $Config.ingress)) {
        $hostname = $route.hostname
        $service  = $route.service

        # Determine internal health URL
        $healthPath = if ($healthMap[$hostname]) { $healthMap[$hostname].health_check } else { "/health" }
        $critical   = if ($healthMap[$hostname]) { $healthMap[$hostname].critical } else { $false }
        $internalUrl = "$service$healthPath"

        # Check via Docker network (if running in container context) or via public URL
        $status = "unknown"
        $httpCode = 0

        # Try internal (Docker) first
        try {
            $dockerResult = docker exec aitheros-tunnel wget -q -O /dev/null -S --timeout=5 $internalUrl 2>&1
            if ($LASTEXITCODE -eq 0) {
                $status = "healthy"
                $httpCode = 200
            }
        } catch { }

        # Fallback: try public URL
        if ($status -eq "unknown") {
            try {
                $publicUrl = "https://$hostname$healthPath"
                $resp = Invoke-WebRequest -Uri $publicUrl -TimeoutSec 10 -SkipHttpErrorCheck -MaximumRedirection 0
                $httpCode = $resp.StatusCode
                $status = if ($httpCode -ge 200 -and $httpCode -lt 400) { "healthy" }
                         elseif ($httpCode -eq 307 -or $httpCode -eq 302) { "auth-gated" }
                         else { "unhealthy" }
            } catch {
                $status = "unreachable"
            }
        }

        $result = @{
            hostname  = $hostname
            service   = $service
            status    = $status
            http_code = $httpCode
            critical  = $critical
        }
        $results += $result

        $icon = switch ($status) {
            "healthy"    { "✓"; $color = "Green" }
            "auth-gated" { "🔒"; $color = "Yellow" }
            "unhealthy"  { "✗"; $color = "Red" }
            "unreachable" { "⚠"; $color = "Red" }
            default      { "?"; $color = "DarkGray" }
        }
        $critLabel = if ($critical) { " [CRITICAL]" } else { "" }
        Write-Host "  $icon $hostname → $service [$httpCode $status]$critLabel" -ForegroundColor $color
    }

    return $results
}

# ══════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════

Write-Title "Cloudflare Tunnel Manager"

switch ($Action) {

    "sync" {
        Write-Step "Reading tunnel-routes.yaml..."
        $localConfig = Read-TunnelConfig
        $routeCount = (Get-HostnameRoutes -Ingress $localConfig.ingress).Count
        Write-Good "Parsed $routeCount routes from config"

        foreach ($r in (Get-HostnameRoutes -Ingress $localConfig.ingress)) {
            Write-Info "  $($r.hostname) → $($r.service)"
        }

        Write-Step "Resolving Cloudflare credentials..."
        $creds = Get-CfCredentials
        Write-Good "Credentials resolved (tunnel: $($creds.TunnelId.Substring(0,8))...)"

        Write-Step "Fetching current live config for backup..."
        $liveConfig = Get-LiveConfig -Creds $creds
        $liveRouteCount = (Get-HostnameRoutes -Ingress $liveConfig.ingress).Count
        Write-Info "Live config has $liveRouteCount routes"

        Save-Backup -LiveConfig $liveConfig -Label "pre-sync"

        if ($DryRun) {
            Write-Title "DRY RUN — would push:"
            $localConfig.ingress | ConvertTo-Json -Depth 5
            return
        }

        if (-not $Force) {
            Write-Host ""
            Write-Host "  Push $routeCount routes to tunnel? (current live: $liveRouteCount)" -ForegroundColor Yellow
            $confirm = Read-Host "  Confirm [y/N]"
            if ($confirm -notin @("y", "yes", "Y")) {
                Write-Bad "Aborted."
                return
            }
        }

        Write-Step "Pushing config to Cloudflare API..."
        $result = Push-TunnelConfig -Creds $creds -Ingress $localConfig.ingress
        Write-Good "Config pushed successfully!"

        Start-Sleep -Seconds 3
        Write-Step "Running health checks..."
        $liveAfter = Get-LiveConfig -Creds $creds
        $healthResults = Test-RouteHealth -Config $liveAfter

        $unhealthy = @($healthResults | Where-Object { $_.status -in @("unhealthy", "unreachable") -and $_.critical })
        if ($unhealthy.Count -gt 0) {
            Write-Bad "WARNING: $($unhealthy.Count) critical route(s) unhealthy after sync!"
            Write-Info "Consider: .\3040_Sync-CloudflareTunnel.ps1 -Action rollback -BackupId latest"
        } else {
            Write-Good "All routes verified! ($routeCount routes active)"
        }

        # Auto-create DNS CNAME records for any new hostnames
        if ($EnsureDNS -or $Force) {
            Write-Step "Ensuring DNS records for all routes..."
            $hostnames = @((Get-HostnameRoutes -Ingress $localConfig.ingress) | ForEach-Object {
                if ($_ -is [hashtable]) { $_['hostname'] } else { $_.hostname }
            })
            Sync-DnsRecords -Creds $creds -Hostnames $hostnames
        }
    }

    "status" {
        $creds = Get-CfCredentials
        $liveConfig = Get-LiveConfig -Creds $creds

        Write-Title "Live Tunnel Routes"
        foreach ($r in $liveConfig.ingress) {
            $h = $null; try { if ($r -is [hashtable]) { if ($r.ContainsKey('hostname')) { $h = $r['hostname'] } } else { $h = $r.hostname } } catch { }
            if ($h) {
                Write-Host "  $h → $($r.service)" -ForegroundColor Cyan
            } else {
                Write-Host "  [catch-all] → $($r.service)" -ForegroundColor DarkGray
            }
        }

        Write-Title "Local Config (tunnel-routes.yaml)"
        $localConfig = Read-TunnelConfig
        foreach ($r in $localConfig.ingress) {
            $h = $null; try { if ($r -is [hashtable]) { if ($r.ContainsKey('hostname')) { $h = $r['hostname'] } } else { $h = $r.hostname } } catch { }
            if ($h) {
                Write-Host "  $h → $($r.service)" -ForegroundColor Green
            } else {
                Write-Host "  [catch-all] → $($r.service)" -ForegroundColor DarkGray
            }
        }

        $liveHosts = @()
        foreach ($r in $liveConfig.ingress) { try { if ($r.hostname) { $liveHosts += $r.hostname } } catch { } }
        $liveHosts = $liveHosts | Sort-Object
        $localHosts = @()
        foreach ($r in $localConfig.ingress) { try { if ($r.hostname) { $localHosts += $r.hostname } } catch { } }
        $localHosts = $localHosts | Sort-Object
        $diff = Compare-Object $liveHosts $localHosts
        if ($diff) {
            Write-Title "DRIFT DETECTED"
            foreach ($d in $diff) {
                if ($d.SideIndicator -eq "<=") {
                    Write-Bad "  In live but NOT in config: $($d.InputObject)"
                } else {
                    Write-Bad "  In config but NOT in live: $($d.InputObject)"
                }
            }
        } else {
            Write-Good "Live config matches tunnel-routes.yaml ✓"
        }
    }

    "diff" {
        $creds = Get-CfCredentials
        $liveConfig = Get-LiveConfig -Creds $creds
        $localConfig = Read-TunnelConfig

        Write-Title "Config Diff (live ↔ local)"

        $liveMap = @{}
        foreach ($r in $liveConfig.ingress) {
            $h = $null
            try { $h = $r.hostname } catch { }
            if ($h) { $liveMap[$h] = $r.service }
        }

        $localMap = @{}
        foreach ($r in $localConfig.ingress) {
            $h = $null
            try { $h = $r.hostname } catch { }
            if ($h) { $localMap[$h] = $r.service }
        }

        $allHosts = ($liveMap.Keys + $localMap.Keys) | Sort-Object -Unique
        $hasChanges = $false

        foreach ($hostname in $allHosts) {
            $inLive  = $liveMap.ContainsKey($hostname)
            $inLocal = $localMap.ContainsKey($hostname)

            if ($inLive -and $inLocal) {
                if ($liveMap[$hostname] -ne $localMap[$hostname]) {
                    Write-Host "  ~ $hostname" -ForegroundColor Yellow
                    Write-Host "    live:  $($liveMap[$hostname])" -ForegroundColor Red
                    Write-Host "    local: $($localMap[$hostname])" -ForegroundColor Green
                    $hasChanges = $true
                }
            } elseif ($inLive -and -not $inLocal) {
                Write-Host "  - $hostname → $($liveMap[$hostname])" -ForegroundColor Red
                $hasChanges = $true
            } elseif (-not $inLive -and $inLocal) {
                Write-Host "  + $hostname → $($localMap[$hostname])" -ForegroundColor Green
                $hasChanges = $true
            }
        }

        if (-not $hasChanges) {
            Write-Good "No differences — live matches local."
        }
    }

    "rollback" {
        Write-Title "Tunnel Config Rollback"

        $backups = Get-ChildItem $BackupDir -Filter "tunnel-config_*.json" | Sort-Object Name -Descending
        if ($backups.Count -eq 0) {
            Write-Bad "No backups found in $BackupDir"
            return
        }

        $targetBackup = $null
        if ($BackupId -eq "latest" -or $BackupId -eq "") {
            $targetBackup = $backups[0]
        } else {
            $targetBackup = $backups | Where-Object { $_.Name -like "*$BackupId*" } | Select-Object -First 1
        }

        if (-not $targetBackup) {
            Write-Bad "Backup not found: $BackupId"
            Write-Info "Available backups:"
            foreach ($b in $backups | Select-Object -First 10) {
                Write-Host "    $($b.Name)" -ForegroundColor DarkGray
            }
            return
        }

        Write-Step "Restoring from: $($targetBackup.Name)"
        $backupContent = Get-Content $targetBackup.FullName -Raw | ConvertFrom-Json
        $oldIngress = $backupContent.config.ingress

        $routeCount = (Get-HostnameRoutes -Ingress $oldIngress).Count
        Write-Info "Backup contains $routeCount routes"

        $creds = Get-CfCredentials

        # Backup current before rollback
        $liveConfig = Get-LiveConfig -Creds $creds
        Save-Backup -LiveConfig $liveConfig -Label "pre-rollback"

        if (-not $Force) {
            Write-Host "  Rollback to $($targetBackup.Name)? ($routeCount routes)" -ForegroundColor Yellow
            $confirm = Read-Host "  Confirm [y/N]"
            if ($confirm -notin @("y", "yes", "Y")) {
                Write-Bad "Aborted."
                return
            }
        }

        # Convert PSObject array to hashtable array for the API
        $ingressArray = @()
        foreach ($r in $oldIngress) {
            $entry = @{ service = $r.service }
            $h = $null; try { if ($r -is [hashtable]) { if ($r.ContainsKey('hostname')) { $h = $r['hostname'] } } else { $h = $r.hostname } } catch { }
            if ($h) { $entry.hostname = $h }
            $ingressArray += $entry
        }

        Push-TunnelConfig -Creds $creds -Ingress $ingressArray
        Write-Good "Rollback complete!"

        Start-Sleep -Seconds 3
        Write-Step "Verifying..."
        $liveAfter = Get-LiveConfig -Creds $creds
        Test-RouteHealth -Config $liveAfter | Out-Null
    }

    "health" {
        Write-Title "Route Health Checks"
        $creds = Get-CfCredentials
        $liveConfig = Get-LiveConfig -Creds $creds
        $results = Test-RouteHealth -Config $liveConfig

        $healthy   = @($results | Where-Object { $_.status -eq "healthy" }).Count
        $gated     = @($results | Where-Object { $_.status -eq "auth-gated" }).Count
        $unhealthy = @($results | Where-Object { $_.status -in @("unhealthy", "unreachable") }).Count
        $total     = @($results).Count

        Write-Host ""
        Write-Host "  Summary: $healthy healthy, $gated auth-gated, $unhealthy unhealthy (of $total)" `
            -ForegroundColor $(if ($unhealthy -gt 0) { "Red" } else { "Green" })
    }

    "backup" {
        Write-Step "Fetching live config..."
        $creds = Get-CfCredentials
        $liveConfig = Get-LiveConfig -Creds $creds
        Save-Backup -LiveConfig $liveConfig -Label "manual"
    }

    "list" {
        Write-Title "Available Backups"
        $backups = Get-ChildItem $BackupDir -Filter "tunnel-config_*.json" | Sort-Object Name -Descending

        if ($backups.Count -eq 0) {
            Write-Info "No backups found."
            return
        }

        foreach ($b in $backups) {
            $content = Get-Content $b.FullName -Raw | ConvertFrom-Json
            $routeCount = (Get-HostnameRoutes -Ingress $content.config.ingress).Count
            $ts = if ($content.timestamp) { $content.timestamp.Substring(0, 19) } else { "?" }
            $label = if ($content.label) { $content.label } else { "?" }
            Write-Host "  $($b.Name)  [$routeCount routes]  $label  $ts" -ForegroundColor Cyan
        }
    }
}
