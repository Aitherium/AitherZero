<#
.SYNOPSIS
    Deploy TLS certificates for all AitherOS services via the internal CA.

.DESCRIPTION
    Issues TLS certificates from AitherSecrets CA for every running service,
    deploys them to Library/Data/tls/{service}/, downloads the CA chain,
    and creates a timestamped backup. Idempotent — skips services that
    already have valid certs.

.PARAMETER Force
    Re-issue certs even if they already exist on disk.

.PARAMETER BackupOnly
    Only create a backup of existing certs without issuing new ones.

.PARAMETER Services
    Comma-separated list of specific services to provision. Default: all running.

.EXAMPLE
    # Issue certs for all running services
    .\6020_Deploy-TLSCertificates.ps1

    # Force re-issue for specific services
    .\6020_Deploy-TLSCertificates.ps1 -Force -Services "genesis,microscheduler,pulse"

    # Backup only
    .\6020_Deploy-TLSCertificates.ps1 -BackupOnly
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$BackupOnly,
    [string]$Services = ""
)

$ErrorActionPreference = "Continue"

# ── Configuration ────────────────────────────────────────────────────────
$AITHEROS_ROOT = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$TLS_DIR = Join-Path $AITHEROS_ROOT "AitherOS" "Library" "Data" "tls"
$BACKUP_DIR = Join-Path $AITHEROS_ROOT "AitherOS" "Library" "Data" "backups" "tls"
$SECRETS_URL = $env:AITHER_SECRETS_URL ?? "http://localhost:8111"
$API_KEY = $env:AITHER_INTERNAL_SECRET ?? $env:AITHER_MASTER_KEY ?? "dev-internal-secret-687579a3"

# Service name mapping: Docker container name → cert common name
# Services with non-standard naming get explicit mappings
$SERVICE_MAP = @{
    "genesis"              = "Genesis"
    "microscheduler"       = "MicroScheduler"
    "pulse"                = "Pulse"
    "chronicle"            = "Chronicle"
    "watch"                = "Watch"
    "node"                 = "Node"
    "secrets"              = "Secrets"
    "security-core"        = "SecurityCore"
    "security-defense"     = "SecurityDefense"
    "strata"               = "Strata"
    "nexus"                = "Nexus"
    "mind"                 = "Mind"
    "reasoning"            = "Reasoning"
    "aeon"                 = "Aeon"
    "a2a"                  = "A2A"
    "perception-core"      = "PerceptionCore"
    "perception-media"     = "PerceptionMedia"
    "cognition-core"       = "CognitionCore"
    "cognition-advanced"   = "CognitionAdvanced"
    "cognition-ci"         = "CognitionCI"
    "memory-core"          = "MemoryCore"
    "mesh-core"            = "MeshCore"
    "automation-core"      = "AutomationCore"
    "workflow-hub"         = "WorkflowHub"
    "training-pipeline"    = "TrainingPipeline"
    "communication-core"   = "CommunicationCore"
    "creative-engine"      = "CreativeEngine"
    "social-hub"           = "SocialHub"
    "dark-factory"         = "DarkFactory"
    "spiritmem"            = "SpiritMem"
    "workingmemory"        = "WorkingMemory"
    "knowledgegraph"       = "KnowledgeGraph"
    "demiurge"             = "Demiurge"
    "atlas"                = "Atlas"
    "lyra"                 = "Lyra"
    "vera"                 = "Vera"
    "hera"                 = "Hera"
    "saga"                 = "Saga"
    "iris"                 = "Iris"
    "prometheus"           = "Prometheus"
    "registry"             = "Registry"
    "gateway"              = "Gateway"
    "mcpgateway"           = "MCPGateway"
    "canvas"               = "Canvas"
    "flow"                 = "Flow"
    "parallel"             = "Parallel"
    "accel"                = "Accel"
    "force"                = "Force"
    "exo"                  = "Exo"
    "exonodes"             = "ExoNodes"
    "compute"              = "Compute"
    "nanogpt"              = "NanoGPT"
    "search"               = "Search"
    "sandbox"              = "Sandbox"
    "jail"                 = "Jail"
    "moltbook"             = "Moltbook"
    "portal-gateway"       = "PortalGateway"
    "external-gateway"     = "ExternalGateway"
}

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  TLS Certificate Deployment" -ForegroundColor Cyan
Write-Host "  AitherOS Inter-Service Encryption" -ForegroundColor Cyan
Write-Host "=============================================`n" -ForegroundColor Cyan

# ── Step 0: Check AitherSecrets ──────────────────────────────────────────
Write-Host "[0/5] Checking AitherSecrets CA..." -ForegroundColor Yellow
try {
    $headers = @{ "X-API-Key" = $API_KEY }
    $caStatus = Invoke-RestMethod -Uri "$SECRETS_URL/ca/status" -Headers $headers -TimeoutSec 5
    if (-not $caStatus.initialized) {
        Write-Host "  CA not initialized. Run: POST $SECRETS_URL/ca/init/root" -ForegroundColor Red
        exit 1
    }
    Write-Host "  CA ready: $($caStatus.certificates.total) certs issued, $($caStatus.certificates.services) services" -ForegroundColor Green
} catch {
    Write-Host "  AitherSecrets unreachable at $SECRETS_URL — $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Step 1: Backup existing certs ────────────────────────────────────────
Write-Host "`n[1/5] Backing up existing certificates..." -ForegroundColor Yellow
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupPath = Join-Path $BACKUP_DIR "tls_backup_$timestamp"

if (Test-Path $TLS_DIR) {
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    Copy-Item -Path "$TLS_DIR\*" -Destination $backupPath -Recurse -Force -ErrorAction SilentlyContinue
    $backupCount = (Get-ChildItem -Path $backupPath -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Host "  Backed up $backupCount files to $backupPath" -ForegroundColor Green
} else {
    Write-Host "  No existing TLS directory — fresh deployment" -ForegroundColor DarkGray
}

if ($BackupOnly) {
    Write-Host "`nBackup complete. Exiting." -ForegroundColor Green
    exit 0
}

# ── Step 2: Download CA chain ────────────────────────────────────────────
Write-Host "`n[2/5] Downloading CA chain..." -ForegroundColor Yellow
New-Item -ItemType Directory -Path $TLS_DIR -Force | Out-Null
$chainPath = Join-Path $TLS_DIR "ca-chain.pem"

try {
    $chain = Invoke-RestMethod -Uri "$SECRETS_URL/ca/chain" -Headers $headers -TimeoutSec 10
    if ($chain -is [string]) {
        Set-Content -Path $chainPath -Value $chain -NoNewline
    } else {
        # JSON response with chain field
        $chainPem = $chain.chain ?? $chain.chain_pem ?? ($chain | ConvertTo-Json)
        Set-Content -Path $chainPath -Value $chainPem -NoNewline
    }
    Write-Host "  CA chain saved: $chainPath" -ForegroundColor Green
} catch {
    Write-Host "  Failed to download CA chain: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Also save root and intermediate separately
try {
    $rootPem = Invoke-RestMethod -Uri "$SECRETS_URL/ca/root" -Headers $headers -TimeoutSec 5
    if ($rootPem) {
        $rootPath = Join-Path $TLS_DIR "root-ca.pem"
        Set-Content -Path $rootPath -Value ($rootPem.certificate ?? $rootPem) -NoNewline
        Write-Host "  Root CA saved: $rootPath" -ForegroundColor Green
    }
} catch { Write-Host "  Root CA download failed (non-fatal)" -ForegroundColor DarkGray }

try {
    $intPem = Invoke-RestMethod -Uri "$SECRETS_URL/ca/intermediate" -Headers $headers -TimeoutSec 5
    if ($intPem) {
        $intPath = Join-Path $TLS_DIR "intermediate-ca.pem"
        Set-Content -Path $intPath -Value ($intPem.certificate ?? $intPem) -NoNewline
        Write-Host "  Intermediate CA saved: $intPath" -ForegroundColor Green
    }
} catch { Write-Host "  Intermediate CA download failed (non-fatal)" -ForegroundColor DarkGray }

# ── Step 3: Determine target services ────────────────────────────────────
Write-Host "`n[3/5] Identifying services to provision..." -ForegroundColor Yellow

if ($Services) {
    $targetServices = $Services -split "," | ForEach-Object { $_.Trim().ToLower() }
} else {
    # Get all running AitherOS containers
    $targetServices = docker ps --format "{{.Names}}" 2>$null |
        Where-Object { $_ -match "^aitheros-" } |
        ForEach-Object { $_ -replace "^aitheros-", "" } |
        Sort-Object
}

Write-Host "  Found $($targetServices.Count) services to provision" -ForegroundColor Green

# ── Step 4: Issue & deploy certificates ──────────────────────────────────
Write-Host "`n[4/5] Issuing certificates..." -ForegroundColor Yellow

$issued = 0
$skipped = 0
$failed = 0

foreach ($svc in $targetServices) {
    $certName = if ($SERVICE_MAP.ContainsKey($svc)) { $SERVICE_MAP[$svc] } else {
        # Auto-generate: capitalize, remove hyphens
        ($svc -split "-" | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ""
    }

    $svcDir = Join-Path $TLS_DIR $svc.ToLower()
    $certFile = Join-Path $svcDir "cert.pem"
    $keyFile = Join-Path $svcDir "key.pem"

    # Skip if already exists (unless -Force)
    if (-not $Force -and (Test-Path $certFile) -and (Test-Path $keyFile)) {
        $skipped++
        continue
    }

    # Build SANs — include all hostname variants the service might be reached by
    $sanDns = @(
        $certName,
        $certName.ToLower(),
        "aitheros-$svc",
        "aither-$svc",
        $svc,
        "localhost"
    ) | Select-Object -Unique

    $body = @{
        validity_days = 365
        san_dns       = $sanDns
        san_ips       = @("127.0.0.1", "::1")
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod -Uri "$SECRETS_URL/ca/issue/$certName" `
            -Method Post -Headers $headers `
            -Body $body -ContentType "application/json" `
            -TimeoutSec 15

        if ($resp.cert_pem -and $resp.key_pem) {
            New-Item -ItemType Directory -Path $svcDir -Force | Out-Null
            Set-Content -Path $certFile -Value $resp.cert_pem -NoNewline
            Set-Content -Path $keyFile -Value $resp.key_pem -NoNewline

            # Also save the chain with the cert if returned
            if ($resp.chain_pem) {
                Set-Content -Path (Join-Path $svcDir "chain.pem") -Value $resp.chain_pem -NoNewline
            }

            $issued++
            Write-Host "  [OK] $($certName.PadRight(25)) -> $svcDir" -ForegroundColor Green
        } else {
            $failed++
            Write-Host "  [FAIL] $($certName.PadRight(25)) — no cert/key in response" -ForegroundColor Red
        }
    } catch {
        $failed++
        Write-Host "  [FAIL] $($certName.PadRight(25)) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ── Step 5: Summary & verification ──────────────────────────────────────
Write-Host "`n[5/5] Deployment Summary" -ForegroundColor Yellow
Write-Host "  Issued:  $issued" -ForegroundColor Green
Write-Host "  Skipped: $skipped (already on disk)" -ForegroundColor DarkGray
Write-Host "  Failed:  $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })

# Count total cert dirs
$totalDirs = (Get-ChildItem -Path $TLS_DIR -Directory -ErrorAction SilentlyContinue).Count
Write-Host "`n  Total service cert directories: $totalDirs" -ForegroundColor Cyan

# Verify CA chain
if (Test-Path $chainPath) {
    $chainSize = (Get-Item $chainPath).Length
    Write-Host "  CA chain: $chainPath ($chainSize bytes)" -ForegroundColor Cyan
} else {
    Write-Host "  CA chain: MISSING" -ForegroundColor Red
}

# Cleanup old backups (keep last 5)
if (Test-Path $BACKUP_DIR) {
    $oldBackups = Get-ChildItem -Path $BACKUP_DIR -Directory | Sort-Object Name -Descending | Select-Object -Skip 5
    foreach ($old in $oldBackups) {
        Remove-Item -Path $old.FullName -Recurse -Force
        Write-Host "  Cleaned old backup: $($old.Name)" -ForegroundColor DarkGray
    }
}

Write-Host "`n=============================================" -ForegroundColor Cyan
if ($failed -eq 0) {
    Write-Host "  TLS deployment complete!" -ForegroundColor Green
    Write-Host "  Restart services to pick up new certs." -ForegroundColor Cyan
} else {
    Write-Host "  Deployment completed with $failed failures." -ForegroundColor Yellow
    Write-Host "  Check AitherSecrets logs for details." -ForegroundColor Yellow
}
Write-Host "=============================================`n" -ForegroundColor Cyan
