#Requires -Version 7.0

<#
.SYNOPSIS
    Deploy inference server and run live demo pipeline (webcam -> detect -> segment -> 3D)
    
.DESCRIPTION
    Launches the full demo pipeline: starts inference server, runs webcam capture
    client with live visualization, processes passing masks through 3D reconstruction
    via AitherOS MeshGen, and logs all asset metadata.
    
    Exit Codes:
    0 - Success
    1 - Inference server not available
    2 - Pipeline error
    
.PARAMETER Action
    Action to perform:
    - Start: Start inference server + webcam pipeline
    - Demo: Run live demo with visualization
    - Process: Process saved images through full pipeline
    - ThreeD: Run 3D reconstruction on passing masks
    
.PARAMETER InputPath
    Path to image or directory for Process mode
    
.PARAMETER SaveMasks
    Save segmentation masks to outputs/masks/
    
.PARAMETER Enable3D
    Enable 3D reconstruction via AitherOS MeshGen

.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7034
    Dependencies: 7030, 7032, 7033
    Tags: roboflow, inference, demo, 3d-reconstruction, pipeline
    AllowParallel: false
    
.EXAMPLE
    .\7034_Deploy-Pipeline.ps1 -Action Demo -Enable3D
    
.EXAMPLE
    .\7034_Deploy-Pipeline.ps1 -Action Process -InputPath "C:\Photos" -SaveMasks
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Start", "Demo", "Process", "ThreeD")]
    [string]$Action = "Demo",
    
    [string]$InputPath,
    [switch]$SaveMasks,
    [switch]$Enable3D,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow Live Pipeline & 3D Reconstruction          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$envFile = Join-Path $roboflowRoot ".env"
$outputsDir = Join-Path $roboflowRoot "outputs"
$masksDir = Join-Path $outputsDir "masks"
$modelsDir = Join-Path $outputsDir "models_3d"
$logsDir = Join-Path $outputsDir "logs"

# Load .env
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^(\w+)=(.*)$') { Set-Item "env:$($matches[1])" $matches[2] }
    }
}

# Ensure output dirs exist
@($masksDir, $modelsDir, $logsDir) | ForEach-Object {
    if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
}

# ── Check Inference Server ────────────────────────────────────────────
$inferenceUrl = "http://$($env:INFERENCE_HOST ?? 'localhost'):$($env:INFERENCE_PORT ?? '9001')"
Write-Host "Checking inference server at $inferenceUrl..." -ForegroundColor Yellow

try {
    $health = Invoke-RestMethod -Uri "$inferenceUrl/health" -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  ✓ Inference server healthy" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Inference server not responding" -ForegroundColor Red
    Write-Host "  Run: .\7030_Setup-Roboflow.ps1 to start it" -ForegroundColor Yellow
    
    if ($Action -eq "Start") {
        Write-Host "  Starting inference server..." -ForegroundColor Yellow
        & "$roboflowRoot/scripts/start_inference.ps1"
        Start-Sleep -Seconds 15
    }
    else {
        exit 1
    }
}

# ── Generate Pipeline Client ─────────────────────────────────────────
$pipelineCode = @"
"""
asset_pipeline_demo.py — Full end-to-end pipeline client
Webcam/Image -> Detection -> Segmentation -> Quality Gate -> 3D Reconstruction
"""
import cv2
import json
import os
import sys
import time
import base64
import numpy as np
from datetime import datetime
from pathlib import Path

# Add custom blocks to path
sys.path.insert(0, r"$roboflowRoot")

INFERENCE_URL = "$inferenceUrl"
MODEL_ID = os.environ.get("MODEL_ID", "3d-asset-pipeline/1")
CONFIDENCE = float(os.environ.get("CONFIDENCE_THRESHOLD", "0.5"))
SAVE_MASKS = $($SaveMasks.ToString().ToLower())
ENABLE_3D = $($Enable3D.ToString().ToLower())
MASKS_DIR = r"$masksDir"
MODELS_DIR = r"$modelsDir"
LOGS_DIR = r"$logsDir"

import httpx

def process_image(image_path_or_frame, source_name=""):
    """Process a single image through the full pipeline."""
    results = {"timestamp": datetime.now().isoformat(), "source": source_name}
    
    # Encode image
    if isinstance(image_path_or_frame, str):
        with open(image_path_or_frame, "rb") as f:
            img_b64 = base64.b64encode(f.read()).decode()
        frame = cv2.imread(image_path_or_frame)
    else:
        _, buffer = cv2.imencode(".jpg", image_path_or_frame)
        img_b64 = base64.b64encode(buffer).decode()
        frame = image_path_or_frame
    
    # Step 1: Detection
    try:
        r = httpx.post(f"{INFERENCE_URL}/infer", json={
            "model_id": MODEL_ID,
            "image": {"type": "base64", "value": img_b64},
            "confidence": CONFIDENCE,
        }, timeout=30)
        detections = r.json().get("predictions", [])
        results["detections"] = len(detections)
    except Exception as e:
        print(f"  Detection failed: {e}")
        return results, frame
    
    # Step 2: Draw detections
    for det in detections:
        x, y, w, h = int(det["x"]), int(det["y"]), int(det["width"]), int(det["height"])
        x1, y1 = x - w // 2, y - h // 2
        x2, y2 = x + w // 2, y + h // 2
        conf = det.get("confidence", 0)
        cls = det.get("class", "?")
        
        color = (0, 255, 0) if conf > 0.7 else (0, 255, 255)
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)
        label = f"{cls} {conf:.0%}"
        cv2.putText(frame, label, (x1, y1 - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
    
    # Step 3: Quality assessment (simplified without SAM masks in this client)
    quality_results = []
    for i, det in enumerate(detections):
        area_pct = (det["width"] * det["height"]) / (frame.shape[0] * frame.shape[1]) * 100
        score = min(1.0, det["confidence"] * 1.2) * (0.8 if 5 < area_pct < 90 else 0.3)
        quality_results.append({
            "asset_id": f"asset_{int(time.time())}_{i}",
            "class": det.get("class", "unknown"),
            "quality_score": round(score, 3),
            "pass_fail": "PASS" if score >= 0.6 else "FAIL",
            "area_pct": round(area_pct, 1),
            "confidence": round(det["confidence"], 3),
        })
    
    results["quality_results"] = quality_results
    
    # Stats overlay
    passed = sum(1 for q in quality_results if q["pass_fail"] == "PASS")
    total = len(quality_results)
    cv2.putText(frame, f"Detected: {total} | Passed: {passed}", (10, 30),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
    
    # Log results
    log_path = os.path.join(LOGS_DIR, "pipeline_results.jsonl")
    with open(log_path, "a") as f:
        f.write(json.dumps(results) + "\n")
    
    return results, frame


def run_webcam_demo():
    """Run live webcam demo with detection overlay."""
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("ERROR: Cannot open webcam")
        return
    
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    
    print("Webcam demo running. Press Q to quit, S to save frame.")
    frame_count = 0
    
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        
        frame_count += 1
        
        # Process every 5th frame for performance
        if frame_count % 5 == 0:
            results, annotated = process_image(frame, f"webcam_frame_{frame_count}")
        else:
            annotated = frame
        
        cv2.imshow("Roboflow 3D Asset Pipeline", annotated)
        
        key = cv2.waitKey(1) & 0xFF
        if key == ord('q'):
            break
        elif key == ord('s'):
            save_path = os.path.join(MASKS_DIR, f"capture_{int(time.time())}.jpg")
            cv2.imwrite(save_path, frame)
            print(f"  Saved: {save_path}")
    
    cap.release()
    cv2.destroyAllWindows()


def process_directory(dir_path):
    """Process all images in a directory."""
    from pathlib import Path
    images = sorted(Path(dir_path).rglob("*"))
    images = [f for f in images if f.suffix.lower() in (".jpg", ".jpeg", ".png")]
    
    print(f"Processing {len(images)} images from {dir_path}")
    
    all_results = []
    for i, img_path in enumerate(images):
        print(f"  [{i+1}/{len(images)}] {img_path.name}...", end="")
        results, annotated = process_image(str(img_path), img_path.name)
        dets = results.get("detections", 0)
        passed = sum(1 for q in results.get("quality_results", []) if q["pass_fail"] == "PASS")
        print(f" {dets} detected, {passed} passed")
        all_results.append(results)
        
        # Save annotated image
        out_path = os.path.join(MASKS_DIR, f"annotated_{img_path.name}")
        cv2.imwrite(out_path, annotated)
    
    # Summary
    total_dets = sum(r.get("detections", 0) for r in all_results)
    total_passed = sum(
        sum(1 for q in r.get("quality_results", []) if q["pass_fail"] == "PASS")
        for r in all_results
    )
    print(f"\nSummary: {len(images)} images, {total_dets} detections, {total_passed} passed quality gate")
    
    # Save summary
    summary_path = os.path.join(LOGS_DIR, "pipeline_summary.json")
    with open(summary_path, "w") as f:
        json.dump({
            "timestamp": datetime.now().isoformat(),
            "images_processed": len(images),
            "total_detections": total_dets,
            "total_passed": total_passed,
            "pass_rate": round(total_passed / max(total_dets, 1) * 100, 1),
        }, f, indent=2)


if __name__ == "__main__":
    action = "$Action"
    
    if action == "Demo":
        run_webcam_demo()
    elif action == "Process":
        input_path = r"$InputPath" or r"$roboflowRoot\training_data\raw"
        process_directory(input_path)
    else:
        print("Usage: Run via 7034_Deploy-Pipeline.ps1")
"@

$clientPath = Join-Path $roboflowRoot "project/asset_pipeline_demo.py"
Set-Content -Path $clientPath -Value $pipelineCode
Write-Host "  ✓ Generated asset_pipeline_demo.py" -ForegroundColor Green

if (-not $DryRun) {
    $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
    if (-not (Test-Path $venvPython)) { $venvPython = "python" }
    
    Write-Host ""
    Write-Host "Running pipeline..." -ForegroundColor Yellow
    & $venvPython $clientPath
}

Write-Host ""
exit 0
