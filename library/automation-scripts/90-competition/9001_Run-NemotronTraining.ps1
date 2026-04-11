#Requires -Version 7.0

<#
.SYNOPSIS
    Launch Nemotron Challenge SFT training pipeline on Vast.ai
.DESCRIPTION
    Retrieves VAST_API_KEY from AitherSecrets, provisions a GPU on Vast.ai,
    trains Nemotron-30B with LoRA r=32 on the competition dataset, downloads
    the adapter, evaluates it, and packages for submission.
.NOTES
    Stage: Competition
    Order: 9001
    Competition: NVIDIA Nemotron Model Reasoning Challenge ($25K, deadline 2026-06-15)
.PARAMETER Phase
    Training phase: 'sft' (default) or 'grpo'
.PARAMETER DryRun
    Preview GPU offers without launching
.PARAMETER SkipEval
    Skip evaluation after training
#>

[CmdletBinding()]
param(
    [ValidateSet('sft','grpo')]
    [string]$Phase = 'sft',
    [switch]$DryRun,
    [switch]$SkipEval
)

$ErrorActionPreference = 'Stop'

$ProjectDir  = 'D:\nemotron-challenge'
$Python      = 'C:\Users\wzns\AppData\Local\Programs\Python\Python312\python.exe'
$SecretsUrl  = 'http://localhost:8111'
$SecretsKey  = 'dev-internal-secret-687579a3'
$HfToken     = $env:HF_TOKEN

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Nemotron Challenge — $($Phase.ToUpper()) Training Pipeline" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Get VAST_API_KEY from AitherSecrets ──────────────────────────────
Write-Host "[1/4] Fetching VAST_API_KEY from AitherSecrets..." -ForegroundColor Yellow
try {
    $headers = @{ 'X-API-Key' = $SecretsKey }
    $r = Invoke-RestMethod "$SecretsUrl/secrets/VAST_API_KEY" -Headers $headers
    $VastKey = $r.value
    if (-not $VastKey) { throw "VAST_API_KEY value is empty" }
    Write-Host "      Got key: $($VastKey.Substring(0,8))..." -ForegroundColor Green
} catch {
    Write-Error "Failed to get VAST_API_KEY: $_"
    exit 1
}

# ── Step 2: Verify dataset exists ────────────────────────────────────────────
$Dataset = "$ProjectDir\data\processed\${Phase}_train.jsonl"
if (-not (Test-Path $Dataset)) {
    Write-Error "Dataset not found: $Dataset — run prepare_datasets.py first"
    exit 1
}
$LineCount = (Get-Content $Dataset | Measure-Object -Line).Lines
Write-Host "[2/4] Dataset: $Dataset ($LineCount examples)" -ForegroundColor Green

# ── Step 3: Provision GPU and train ──────────────────────────────────────────
$OutputDir  = "$ProjectDir\adapters\v1_$Phase"
$ProvisionScript = "$ProjectDir\scripts\provision_gpu.py"

$env:VAST_API_KEY = $VastKey
$env:HF_TOKEN     = $HfToken

$provArgs = @(
    $ProvisionScript,
    '--phase', $Phase,
    '--dataset', $Dataset,
    '--output', $OutputDir
)
if ($DryRun)  { $provArgs += '--dry-run' }

Write-Host "[3/4] Launching GPU provisioner..." -ForegroundColor Yellow
if ($DryRun) {
    Write-Host "      DRY RUN — showing offers only" -ForegroundColor Magenta
}

Push-Location $ProjectDir
try {
    & $Python @provArgs
    if ($LASTEXITCODE -ne 0) { throw "provision_gpu.py exited with code $LASTEXITCODE" }
} finally {
    Pop-Location
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. Remove -DryRun to launch real training." -ForegroundColor Cyan
    exit 0
}

# ── Step 4: Evaluate ─────────────────────────────────────────────────────────
if (-not $SkipEval) {
    $AdapterConfig = "$OutputDir\adapter_config.json"
    if (-not (Test-Path $AdapterConfig)) {
        Write-Warning "Adapter not found at $AdapterConfig — skipping evaluation"
    } else {
        Write-Host "[4/4] Evaluating adapter..." -ForegroundColor Yellow
        $EvalDataset = "$ProjectDir\data\processed\sft_eval.jsonl"
        Push-Location $ProjectDir
        try {
            & $Python "$ProjectDir\scripts\evaluate.py" `
                --adapter $OutputDir `
                --dataset $EvalDataset
        } catch {
            Write-Warning "Evaluation failed (non-fatal): $_"
        } finally {
            Pop-Location
        }

        # Package for submission
        Write-Host "      Packaging submission..." -ForegroundColor Yellow
        $SubmissionZip = "$ProjectDir\submissions\v1_${Phase}.zip"
        Push-Location $ProjectDir
        try {
            & $Python "$ProjectDir\scripts\package_submission.py" `
                --adapter $OutputDir `
                --output $SubmissionZip
            Write-Host "      Submission: $SubmissionZip" -ForegroundColor Green
        } catch {
            Write-Warning "Packaging failed (non-fatal): $_"
        } finally {
            Pop-Location
        }
    }
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  Training complete!" -ForegroundColor Green
Write-Host "  Adapter : $OutputDir"
Write-Host "  Submission: $ProjectDir\submissions\v1_${Phase}.zip"
Write-Host "======================================================" -ForegroundColor Green
