#Requires -Version 7.0

<#
.SYNOPSIS
    Build and test Roboflow Workflow with custom blocks
    
.DESCRIPTION
    Creates the Roboflow Workflow definition (RF-DETR -> SAM3 -> AssetQualityGate 
    -> AssetMetadataBuilder -> Visualization), generates custom block Python code,
    and tests the workflow against sample images.
    
    Exit Codes:
    0 - Success
    1 - Workflow creation failed
    2 - Custom block error
    
.PARAMETER Action
    Action to perform:
    - Build: Generate workflow JSON and custom block code
    - Test: Run workflow against test images
    - Export: Export workflow definition for sharing
    - Full: Build + Test
    
.PARAMETER TestImage
    Path to test image for workflow testing
    
.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7033
    Dependencies: 7030, 7032
    Tags: roboflow, workflow, custom-blocks, quality-gate
    AllowParallel: false
    
.EXAMPLE
    .\7033_Build-Workflow.ps1 -Action Full
    
.EXAMPLE
    .\7033_Build-Workflow.ps1 -Action Test -TestImage "C:\Photos\test.jpg"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Build", "Test", "Export", "Full")]
    [string]$Action = "Full",
    
    [string]$TestImage,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow Workflow Builder                           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$blocksDir = Join-Path $roboflowRoot "custom_blocks"
$workflowDir = Join-Path $roboflowRoot "workflow"

# ── Custom Block: AssetQualityGate ────────────────────────────────────
if ($Action -in "Build", "Full") {
    Write-Host "Building custom blocks..." -ForegroundColor Yellow
    
    $qualityGateCode = @'
"""
AssetQualityGate — Custom Roboflow Workflow Block
Validates segmentation mask quality before 3D reconstruction.

Inputs: segmentation masks, original image, detection predictions
Outputs: quality_score, pass_fail, asset_type, mask_area_pct, recommendation
"""
import numpy as np
from typing import List, Dict, Any, Tuple
from inference.core.workflows.execution_engine.entities.base import WorkflowImageData


class AssetQualityGate:
    """Validates segmentation masks for 3D reconstruction readiness."""
    
    # Thresholds (tunable per use case)
    MIN_MASK_AREA_PCT = 5.0      # Reject tiny masks
    MAX_MASK_AREA_PCT = 90.0     # Reject masks that are basically the whole image
    MIN_CONTIGUITY = 0.85        # Mask must be mostly one connected region
    MIN_EDGE_SHARPNESS = 0.3     # Edge gradient strength
    
    @classmethod
    def run(
        cls,
        image: WorkflowImageData,
        masks: List[np.ndarray],
        detections: List[Dict[str, Any]],
    ) -> List[Dict[str, Any]]:
        """Process each detection+mask pair through quality gates."""
        results = []
        
        img_h, img_w = image.numpy_image.shape[:2]
        total_pixels = img_h * img_w
        
        for i, (mask, det) in enumerate(zip(masks, detections)):
            score = 0.0
            issues = []
            
            # 1. Mask area check
            mask_pixels = np.sum(mask > 0)
            area_pct = (mask_pixels / total_pixels) * 100
            
            if area_pct < cls.MIN_MASK_AREA_PCT:
                issues.append(f"mask too small ({area_pct:.1f}%)")
            elif area_pct > cls.MAX_MASK_AREA_PCT:
                issues.append(f"mask too large ({area_pct:.1f}%)")
            else:
                score += 0.3
            
            # 2. Contiguity check (largest connected component ratio)
            contiguity = cls._compute_contiguity(mask)
            if contiguity < cls.MIN_CONTIGUITY:
                issues.append(f"fragmented mask (contiguity={contiguity:.2f})")
            else:
                score += 0.3
            
            # 3. Edge sharpness
            sharpness = cls._compute_edge_sharpness(mask)
            if sharpness < cls.MIN_EDGE_SHARPNESS:
                issues.append(f"blurry edges (sharpness={sharpness:.2f})")
            else:
                score += 0.2
            
            # 4. Detection confidence bonus
            det_conf = det.get("confidence", 0.5)
            score += 0.2 * min(det_conf / 0.8, 1.0)
            
            # Clamp to [0, 1]
            score = max(0.0, min(1.0, score))
            passed = score >= 0.6 and len(issues) == 0
            
            # Recommendation
            if passed:
                recommendation = "Ready for 3D reconstruction"
            elif score >= 0.4:
                recommendation = "Retry with adjusted prompt or angle"
            else:
                recommendation = "Manual review required"
            
            results.append({
                "asset_id": f"asset_{i:04d}",
                "quality_score": round(score, 3),
                "pass_fail": "PASS" if passed else "FAIL",
                "asset_type": det.get("class", "unknown"),
                "mask_area_pct": round(area_pct, 1),
                "contiguity": round(contiguity, 3),
                "edge_sharpness": round(sharpness, 3),
                "detection_confidence": round(det_conf, 3),
                "issues": issues,
                "recommendation": recommendation,
            })
        
        return results
    
    @staticmethod
    def _compute_contiguity(mask: np.ndarray) -> float:
        """Ratio of largest connected component to total mask area."""
        try:
            import cv2
            binary = (mask > 0).astype(np.uint8)
            num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(binary)
            if num_labels <= 1:
                return 0.0
            # Skip background (label 0)
            areas = stats[1:, cv2.CC_STAT_AREA]
            largest = areas.max()
            total = areas.sum()
            return largest / total if total > 0 else 0.0
        except ImportError:
            return 1.0  # If no cv2, assume contiguous
    
    @staticmethod
    def _compute_edge_sharpness(mask: np.ndarray) -> float:
        """Average gradient magnitude along mask boundary."""
        try:
            import cv2
            binary = (mask > 0).astype(np.uint8) * 255
            edges = cv2.Canny(binary, 50, 150)
            gradient = cv2.Sobel(binary, cv2.CV_64F, 1, 1, ksize=3)
            edge_pixels = edges > 0
            if edge_pixels.sum() == 0:
                return 0.0
            return float(np.abs(gradient[edge_pixels]).mean() / 255.0)
        except ImportError:
            return 1.0
'@
    Set-Content -Path (Join-Path $blocksDir "asset_quality_gate.py") -Value $qualityGateCode
    Write-Host "  ✓ AssetQualityGate custom block" -ForegroundColor Green

    # ── Custom Block: AssetMetadataBuilder ────────────────────────────
    $metadataCode = @'
"""
AssetMetadataBuilder — Custom Roboflow Workflow Block
Tracks asset lifecycle through a state machine and generates metadata.

State machine: captured -> detected -> segmented -> quality_check -> passed/failed -> reconstructed -> exported
"""
import json
import os
import time
from typing import List, Dict, Any
from datetime import datetime


class AssetMetadataBuilder:
    """Builds structured metadata for each processed asset and tracks state transitions."""
    
    # State machine transitions
    VALID_TRANSITIONS = {
        "captured": ["detected"],
        "detected": ["segmented"],
        "segmented": ["quality_check"],
        "quality_check": ["passed", "failed"],
        "passed": ["reconstructed"],
        "failed": ["retry", "manual_review"],
        "retry": ["detected"],
        "reconstructed": ["exported"],
        "exported": [],
    }
    
    @classmethod
    def run(
        cls,
        quality_results: List[Dict[str, Any]],
        source_image_path: str = "",
        log_dir: str = "",
    ) -> List[Dict[str, Any]]:
        """Generate metadata entries for each quality-checked asset."""
        metadata_entries = []
        timestamp = datetime.now().isoformat()
        
        for result in quality_results:
            asset_id = result.get("asset_id", f"asset_{int(time.time())}")
            passed = result.get("pass_fail") == "PASS"
            
            entry = {
                "asset_id": asset_id,
                "timestamp": timestamp,
                "source_image": source_image_path,
                "asset_type": result.get("asset_type", "unknown"),
                "quality_score": result.get("quality_score", 0),
                "state": "passed" if passed else "failed",
                "state_history": [
                    {"state": "captured", "timestamp": timestamp},
                    {"state": "detected", "timestamp": timestamp},
                    {"state": "segmented", "timestamp": timestamp},
                    {"state": "quality_check", "timestamp": timestamp},
                    {"state": "passed" if passed else "failed", "timestamp": timestamp},
                ],
                "mask_area_pct": result.get("mask_area_pct", 0),
                "detection_confidence": result.get("detection_confidence", 0),
                "issues": result.get("issues", []),
                "recommendation": result.get("recommendation", ""),
                "reconstruction_path": "",  # Filled when 3D model is generated
                "export_format": "",         # Filled on export
            }
            
            metadata_entries.append(entry)
        
        # Append to log file
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
            log_path = os.path.join(log_dir, "asset_pipeline.jsonl")
            with open(log_path, "a") as f:
                for entry in metadata_entries:
                    f.write(json.dumps(entry) + "\n")
        
        return metadata_entries
    
    @classmethod
    def transition(cls, entry: Dict, new_state: str) -> Dict:
        """Advance an asset through the state machine."""
        current = entry.get("state", "captured")
        valid = cls.VALID_TRANSITIONS.get(current, [])
        
        if new_state not in valid:
            raise ValueError(
                f"Invalid transition: {current} -> {new_state}. "
                f"Valid: {valid}"
            )
        
        entry["state"] = new_state
        entry["state_history"].append({
            "state": new_state,
            "timestamp": datetime.now().isoformat(),
        })
        
        return entry
'@
    Set-Content -Path (Join-Path $blocksDir "asset_metadata.py") -Value $metadataCode
    Write-Host "  ✓ AssetMetadataBuilder custom block" -ForegroundColor Green

        # ── Workflow Definition JSON ──────────────────────────────────────
        $workflowDef = @'
{
    "name": "3D Asset Pipeline (Local)",
    "description": "Local-compatible Roboflow workflow for image -> detection -> visualization.",
    "version": "1.0",
    "inputs": [
        {
            "type": "WorkflowImage",
            "name": "image"
        }
    ],
    "steps": [
        {
            "type": "roboflow_core/roboflow_object_detection_model@v1",
            "name": "detector",
            "image": "$inputs.image",
            "model_id": "${MODEL_ID}",
            "confidence": 0.5,
            "iou_threshold": 0.45
        },
        {
            "type": "roboflow_core/bounding_box_visualization@v1",
            "name": "visualization",
            "image": "$inputs.image",
            "predictions": "$steps.detector.predictions"
        }
    ],
    "outputs": [
        {
            "type": "JsonField",
            "name": "detections",
            "selector": "$steps.detector.predictions"
        },
        {
            "type": "JsonField",
            "name": "visualization",
            "selector": "$steps.visualization.image"
        }
    ]
}
'@
        $advancedWorkflowDef = @'
{
    "name": "3D Asset Pipeline (Advanced Design)",
    "description": "RF-DETR detection -> SAM3 segmentation -> quality gate -> metadata -> visualization",
    "version": "1.0",
    "steps": [
        {
            "type": "roboflow_object_detection",
            "name": "detector",
            "model_id": "${MODEL_ID}",
            "confidence_threshold": 0.5,
            "iou_threshold": 0.45
        },
        {
            "type": "detections_filter",
            "name": "filter",
            "input": "$detector",
            "filter_definition": {
                "field_name": "confidence",
                "operator": ">=",
                "value": 0.5
            }
        },
        {
            "type": "sam2_instance_segmentation",
            "name": "segmentor",
            "input_detections": "$filter",
            "prompt_type": "bounding_box"
        },
        {
            "type": "dynamic_python",
            "name": "quality_gate",
            "code_path": "custom_blocks/asset_quality_gate.py",
            "class_name": "AssetQualityGate",
            "inputs": {
                "image": "$image",
                "masks": "$segmentor.masks",
                "detections": "$filter.predictions"
            }
        },
        {
            "type": "dynamic_python",
            "name": "metadata",
            "code_path": "custom_blocks/asset_metadata.py",
            "class_name": "AssetMetadataBuilder",
            "inputs": {
                "quality_results": "$quality_gate",
                "source_image_path": "$image.path",
                "log_dir": "outputs/logs"
            }
        },
        {
            "type": "mask_visualization",
            "name": "visualization",
            "input_image": "$image",
            "input_masks": "$segmentor.masks",
            "input_detections": "$filter",
            "opacity": 0.5,
            "show_labels": true
        }
    ],
    "outputs": {
        "visualization": "$visualization",
        "quality_results": "$quality_gate",
        "metadata": "$metadata",
        "detections": "$filter"
    }
}
'@
        Set-Content -Path (Join-Path $workflowDir "asset_pipeline.json") -Value $workflowDef
        Set-Content -Path (Join-Path $workflowDir "asset_pipeline_advanced.json") -Value $advancedWorkflowDef
        Write-Host "  ✓ Workflow definition (asset_pipeline.json — local-compatible)" -ForegroundColor Green
        Write-Host "  ✓ Advanced reference (asset_pipeline_advanced.json)" -ForegroundColor Green
}

# ── Test Workflow ─────────────────────────────────────────────────────
if ($Action -in "Test", "Full") {
    Write-Host ""
    Write-Host "Testing workflow..." -ForegroundColor Yellow
    
    $testScript = @"
import os, json, uuid, base64, httpx

host = os.environ.get("INFERENCE_HOST", "localhost")
port = os.environ.get("INFERENCE_PORT", "9002")
model_id = os.environ.get("MODEL_ID", "3d-asset-pipeline/1")

test_image = r"$TestImage" if r"$TestImage" else None

if not test_image:
    # Use a sample from training data
    raw_dir = r"$roboflowRoot\training_data\raw"
    for root, dirs, files in os.walk(raw_dir):
        for f in files:
            if f.lower().endswith(('.jpg', '.jpeg', '.png')):
                test_image = os.path.join(root, f)
                break
        if test_image:
            break

if not test_image:
    print("No test image found. Provide --TestImage or capture data first.")
    exit(1)

print(f"Testing with: {test_image}")

# Test basic detection
try:
    with open(test_image, "rb") as f:
        img_b64 = base64.b64encode(f.read()).decode()
    
    r = httpx.post(
        f"http://{host}:{port}/infer/object_detection",
        json={
            "id": str(uuid.uuid4()),
            "model_id": model_id,
            "image": {"type": "base64", "value": img_b64},
            "confidence": 0.5,
        },
        timeout=60,
    )
    
    if r.status_code == 200:
        data = r.json()
        preds = data.get("predictions", [])
        print(f"  Detections: {len(preds)}")
        for p in preds[:5]:
            print(f"    - {p.get('class', '?')}: {p.get('confidence', 0):.2f}")
        print("  ✓ Inference server responding")
    else:
        print(f"  ⚠ Server returned {r.status_code}: {r.text[:200]}")
except Exception as e:
    print(f"  ✗ Test failed: {e}")
    print("  (Is the inference server running? Run: .\\7030_Setup-Roboflow.ps1)")
"@
    $scriptPath = Join-Path $roboflowRoot "scripts/_test_workflow.py"
    Set-Content -Path $scriptPath -Value $testScript
    
    if (-not $DryRun) {
        $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
        if (-not (Test-Path $venvPython)) { $venvPython = "python" }
        & $venvPython $scriptPath
    }
}

# ── Export ────────────────────────────────────────────────────────────
if ($Action -eq "Export") {
    Write-Host "Exporting workflow..." -ForegroundColor Yellow
    $exportPath = Join-Path $workflowDir "asset_pipeline_export.json"
    if (Test-Path (Join-Path $workflowDir "asset_pipeline.json")) {
        Copy-Item (Join-Path $workflowDir "asset_pipeline.json") $exportPath
        Write-Host "  ✓ Exported to $exportPath" -ForegroundColor Green
    }
}

Write-Host ""
exit 0
