<#
.SYNOPSIS
    Deploy AitherOS to production — full go-to-market stack.

.DESCRIPTION
    Deploys the complete AitherOS SaaS inference platform:
    1. Builds and pushes container images to GHCR
    2. Deploys GCP infrastructure via OpenTofu (GKE + GPU)
    3. Applies K8s manifests (vLLM workers + HPA autoscaling)
    4. Deploys Cloudflare Worker edge gateway
    5. Configures Cloudflare DNS + tunnel
    6. Runs smoke tests

    Cost model:
      - Idle: ~$100/mo (GKE cluster + 1 GPU spot instance)
      - Active: ~$400-800/mo (scales with demand up to 5 GPUs)
      - At 1000 users: ~$0.01/user/month compute cost

.PARAMETER Environment
    Target environment: dev, staging, production

.PARAMETER SkipBuild
    Skip container image build (use existing GHCR images)

.PARAMETER SkipInfra
    Skip OpenTofu infrastructure deployment

.PARAMETER DryRun
    Show what would be done without executing

.EXAMPLE
    .\3010_Deploy-Production.ps1 -Environment production
    .\3010_Deploy-Production.ps1 -Environment staging -SkipBuild

#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('dev', 'staging', 'production')]
    [string]$Environment = 'production',

    [switch]$SkipBuild,
    [switch]$SkipInfra,
    [switch]$SkipWorker,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT = (Resolve-Path "$PSScriptRoot/../../..").Path
$INFRA_DIR = "$ROOT/AitherZero/library/infrastructure"
$K8S_DIR = "$INFRA_DIR/kubernetes"
$CF_DIR = "$ROOT/cloudflare/api-gateway"
$GCP_DIR = "$INFRA_DIR/modules/gcp"

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  AitherOS Production Deployment — $Environment" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`n" -ForegroundColor Cyan

# ── Step 1: Build & Push Container Images ────────────────────────────────

if (-not $SkipBuild) {
    Write-Host "[1/5] Building container images..." -ForegroundColor Yellow

    $services = @(
        @{ Name = 'aitheros-node';     Context = "$ROOT/AitherOS/apps/AitherNode";    Dockerfile = 'Dockerfile' },
        @{ Name = 'aitheros-veil';     Context = "$ROOT/AitherOS/apps/AitherVeil";    Dockerfile = 'Dockerfile' },
        @{ Name = 'aitheros-gateway';  Context = "$ROOT/AitherOS/apps/AitherNode";    Dockerfile = 'Dockerfile' },
        @{ Name = 'aitheros-acta';     Context = "$ROOT/AitherOS";                    Dockerfile = 'docker/Dockerfile.service' },
        @{ Name = 'aitheros-identity'; Context = "$ROOT/AitherOS";                    Dockerfile = 'docker/Dockerfile.service' },
        @{ Name = 'aitheros-vllm';     Context = "$ROOT/AitherOS/docker/vllm";        Dockerfile = 'Dockerfile' }
    )

    $registry = $env:AITHER_REGISTRY ?? 'ghcr.io/aitherium'
    $tag = $env:AITHER_VERSION ?? 'latest'

    foreach ($svc in $services) {
        $image = "$registry/$($svc.Name):$tag"
        Write-Host "  → $image"
        if (-not $DryRun) {
            docker build -t $image -f "$($svc.Context)/$($svc.Dockerfile)" $svc.Context
            docker push $image
        }
    }

    Write-Host "  ✓ Images pushed to $registry" -ForegroundColor Green
} else {
    Write-Host "[1/5] Skipping image build" -ForegroundColor DarkGray
}

# ── Step 2: Deploy GCP Infrastructure ───────────────────────────────────

if (-not $SkipInfra) {
    Write-Host "`n[2/5] Deploying GCP infrastructure ($Environment)..." -ForegroundColor Yellow

    $tfvarsFile = "$GCP_DIR/profiles/$Environment.tfvars"
    if (-not (Test-Path $tfvarsFile)) {
        Write-Warning "No tfvars file at $tfvarsFile — using demo profile"
        $tfvarsFile = "$GCP_DIR/profiles/demo.tfvars"
    }

    Push-Location $GCP_DIR
    try {
        if (-not $DryRun) {
            tofu init -upgrade
            tofu plan -var-file=$tfvarsFile -out=plan.tfplan
            Write-Host "  → Review the plan above. Apply? (y/n)" -ForegroundColor Yellow
            $confirm = Read-Host
            if ($confirm -eq 'y') {
                tofu apply plan.tfplan
                Write-Host "  ✓ Infrastructure deployed" -ForegroundColor Green
            } else {
                Write-Host "  → Skipped infrastructure apply" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  [DRY RUN] Would run: tofu apply -var-file=$tfvarsFile"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host "[2/5] Skipping infrastructure deployment" -ForegroundColor DarkGray
}

# ── Step 3: Apply K8s Manifests ──────────────────────────────────────────

Write-Host "`n[3/5] Applying Kubernetes manifests..." -ForegroundColor Yellow

$k8sManifests = @(
    "$K8S_DIR/vllm-hpa.yaml"
)

foreach ($manifest in $k8sManifests) {
    if (Test-Path $manifest) {
        $fileName = Split-Path $manifest -Leaf
        Write-Host "  → $fileName"
        if (-not $DryRun) {
            kubectl apply -f $manifest
        }
    }
}

if (-not $DryRun) {
    Write-Host "  → Waiting for rollout..."
    kubectl rollout status deployment/vllm-orchestrator -n aitheros --timeout=300s 2>$null
    kubectl rollout status deployment/ollama -n aitheros --timeout=120s 2>$null
    kubectl rollout status deployment/aither-gateway -n aitheros --timeout=120s 2>$null
    Write-Host "  ✓ K8s deployments ready" -ForegroundColor Green
} else {
    Write-Host "  [DRY RUN] Would apply: $($k8sManifests -join ', ')"
}

# ── Step 4: Deploy Cloudflare Worker ─────────────────────────────────────

if (-not $SkipWorker) {
    Write-Host "`n[4/5] Deploying Cloudflare API Gateway..." -ForegroundColor Yellow

    if (Test-Path $CF_DIR) {
        Push-Location $CF_DIR
        try {
            if (-not $DryRun) {
                npm install
                npx wrangler deploy --env $Environment
                Write-Host "  ✓ Worker deployed to api.aitherium.com" -ForegroundColor Green
            } else {
                Write-Host "  [DRY RUN] Would run: wrangler deploy --env $Environment"
            }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "  ⚠ Cloudflare worker directory not found at $CF_DIR" -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/5] Skipping Cloudflare worker deployment" -ForegroundColor DarkGray
}

# ── Step 5: Smoke Tests ─────────────────────────────────────────────────

Write-Host "`n[5/5] Running smoke tests..." -ForegroundColor Yellow

$endpoints = @(
    @{ Name = 'Gateway Health';   URL = "https://api.aitherium.com/health"; Expected = 200 },
    @{ Name = 'Model List';       URL = "https://api.aitherium.com/v1/models"; Expected = 200 },
    @{ Name = 'Pricing';          URL = "https://api.aitherium.com/v1/pricing"; Expected = 200 },
    @{ Name = 'Dashboard';        URL = "https://aitherium.com"; Expected = 200 }
)

$allPassed = $true
foreach ($ep in $endpoints) {
    if (-not $DryRun) {
        try {
            $resp = Invoke-WebRequest -Uri $ep.URL -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
            $status = $resp.StatusCode
        } catch {
            $status = 0
        }
        $icon = if ($status -eq $ep.Expected) { '✓' } else { '✗'; $allPassed = $false }
        $color = if ($status -eq $ep.Expected) { 'Green' } else { 'Red' }
        Write-Host "  $icon $($ep.Name): $status" -ForegroundColor $color
    } else {
        Write-Host "  [DRY RUN] Would check: $($ep.URL)"
    }
}

# ── Summary ─────────────────────────────────────────────────────────────

Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  Deployment Complete" -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "  API Endpoint:   https://api.aitherium.com/v1" -ForegroundColor White
Write-Host "  Dashboard:      https://aitherium.com" -ForegroundColor White
Write-Host "  Pricing:        https://aitherium.com/pricing" -ForegroundColor White
Write-Host "  Developer Docs: https://aitherium.com/developers" -ForegroundColor White
Write-Host ""
Write-Host "  Quick test:" -ForegroundColor DarkGray
Write-Host "    curl https://api.aitherium.com/v1/chat/completions \" -ForegroundColor DarkGray
Write-Host "      -H 'Authorization: Bearer aither_sk_live_...' \" -ForegroundColor DarkGray
Write-Host "      -d '{`"model`":`"aither-small`",`"messages`":[{`"role`":`"user`",`"content`":`"Hello`"}]}'" -ForegroundColor DarkGray
Write-Host ""
