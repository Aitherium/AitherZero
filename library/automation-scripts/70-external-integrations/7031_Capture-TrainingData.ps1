#Requires -Version 7.0

<#
.SYNOPSIS
    Capture and upload training data for the Roboflow 3D Asset Pipeline
    
.DESCRIPTION
    Automates data capture from webcam/phone, organizes by class, applies naming
    conventions, and batch-uploads to Roboflow for annotation. Also pulls
    supplementary data from Roboflow Universe.
    
    Exit Codes:
    0 - Success
    1 - Capture device not available
    2 - Upload failed
    
.PARAMETER Mode
    Capture mode: Webcam, Import, Universe, Upload
    - Webcam: Capture from webcam using OpenCV
    - Import: Import existing images from a directory
    - Universe: Pull supplementary data from Roboflow Universe
    - Upload: Upload raw images to Roboflow project
    
.PARAMETER Class
    Target class to capture: person, furniture, object, prop
    
.PARAMETER Count
    Number of images to capture (Webcam mode, default: 50)
    
.PARAMETER ImportPath
    Path to import images from (Import mode)
    
.PARAMETER UniverseDataset
    Universe dataset slug to pull from (Universe mode)
    
.PARAMETER DryRun
    Show what would be done without making changes

.NOTES
    Stage: ExternalIntegrations
    Order: 7031
    Dependencies: 7030
    Tags: roboflow, data-capture, training-data, upload
    AllowParallel: false
    
.EXAMPLE
    .\7031_Capture-TrainingData.ps1 -Mode Webcam -Class person -Count 60
    
.EXAMPLE
    .\7031_Capture-TrainingData.ps1 -Mode Import -ImportPath "C:\Photos\furniture" -Class furniture
    
.EXAMPLE
    .\7031_Capture-TrainingData.ps1 -Mode Universe -UniverseDataset "coco-128/2"
    
.EXAMPLE
    .\7031_Capture-TrainingData.ps1 -Mode Upload
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Webcam", "Import", "Universe", "Upload")]
    [string]$Mode = "Upload",
    
    [ValidateSet("person", "furniture", "object", "prop", "all")]
    [string]$Class = "all",
    
    [int]$Count = 50,
    [string]$ImportPath,
    [string]$UniverseDataset = "coco-128/2",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       Roboflow Data Capture & Upload                      ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$roboflowRoot = Join-Path $projectRoot ".roboflow"
$rawDir = Join-Path $roboflowRoot "training_data/raw"
$envFile = Join-Path $roboflowRoot ".env"

# Load .env
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^(\w+)=(.*)$') {
            Set-Item "env:$($matches[1])" $matches[2]
        }
    }
}

switch ($Mode) {
    "Webcam" {
        Write-Host "Mode: Webcam Capture — $Count images of class '$Class'" -ForegroundColor Yellow
        Write-Host ""
        
        $classDir = Join-Path $rawDir $Class
        if (-not (Test-Path $classDir)) {
            New-Item -ItemType Directory -Path $classDir -Force | Out-Null
        }
        
        $captureScript = @"
import cv2
import os
import time
from datetime import datetime

save_dir = r"$classDir"
os.makedirs(save_dir, exist_ok=True)
cap = cv2.VideoCapture(0)
if not cap.isOpened():
    print("ERROR: Cannot open webcam")
    exit(1)

cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)

count = 0
target = $Count
print(f"Capturing {target} images for class '$Class'")
print("Press SPACE to capture, Q to quit, A for auto-capture (2s interval)")
auto = False

while count < target:
    ret, frame = cap.read()
    if not ret:
        break
    
    display = frame.copy()
    cv2.putText(display, f"Captured: {count}/{target} | Class: $Class", (10, 30),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2)
    if auto:
        cv2.putText(display, "AUTO", (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
    cv2.imshow("Roboflow Capture", display)
    
    key = cv2.waitKey(1 if auto else 50) & 0xFF
    
    should_capture = False
    if key == ord(' '):
        should_capture = True
    elif key == ord('a'):
        auto = not auto
    elif key == ord('q'):
        break
    elif auto and time.time() % 2 < 0.05:
        should_capture = True
    
    if should_capture:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        fname = f"${Class}_{ts}.jpg"
        path = os.path.join(save_dir, fname)
        cv2.imwrite(path, frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        count += 1
        print(f"  [{count}/{target}] {fname}")

cap.release()
cv2.destroyAllWindows()
print(f"Done: {count} images saved to {save_dir}")
"@
        $scriptPath = Join-Path $roboflowRoot "scripts/_capture_webcam.py"
        Set-Content -Path $scriptPath -Value $captureScript
        
        if (-not $DryRun) {
            $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
            if (-not (Test-Path $venvPython)) {
                $venvPython = "python"
            }
            & $venvPython $scriptPath
        }
        else {
            Write-Host "  Would capture $Count images to $classDir" -ForegroundColor Gray
        }
    }
    
    "Import" {
        Write-Host "Mode: Import — copying images from $ImportPath" -ForegroundColor Yellow
        
        if (-not $ImportPath -or -not (Test-Path $ImportPath)) {
            Write-Host "  ✗ Import path not found: $ImportPath" -ForegroundColor Red
            exit 1
        }
        
        $classDir = Join-Path $rawDir $Class
        if (-not (Test-Path $classDir)) {
            New-Item -ItemType Directory -Path $classDir -Force | Out-Null
        }
        
        $images = Get-ChildItem $ImportPath -File -Include "*.jpg", "*.jpeg", "*.png", "*.bmp", "*.webp" -Recurse
        Write-Host "  Found $($images.Count) images" -ForegroundColor Gray
        
        if (-not $DryRun) {
            $copied = 0
            foreach ($img in $images) {
                $dest = Join-Path $classDir $img.Name
                Copy-Item $img.FullName $dest -Force
                $copied++
            }
            Write-Host "  ✓ Copied $copied images to $classDir" -ForegroundColor Green
        }
    }
    
    "Universe" {
        Write-Host "Mode: Universe — pulling dataset '$UniverseDataset'" -ForegroundColor Yellow
        
        $pullScript = @"
from roboflow import Roboflow
import os

rf = Roboflow(api_key=os.environ.get("ROBOFLOW_API_KEY", ""))
project = rf.workspace().project("$($UniverseDataset.Split('/')[0])")
version = project.version($($UniverseDataset.Split('/')[1]))
dataset = version.download("yolov8", location=r"$rawDir/universe_$($UniverseDataset.Replace('/', '_'))")
print(f"Downloaded to: {dataset.location}")
"@
        $scriptPath = Join-Path $roboflowRoot "scripts/_pull_universe.py"
        Set-Content -Path $scriptPath -Value $pullScript
        
        if (-not $DryRun) {
            $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
            if (-not (Test-Path $venvPython)) { $venvPython = "python" }
            & $venvPython $scriptPath
        }
    }
    
    "Upload" {
        Write-Host "Mode: Upload — batch uploading raw images to Roboflow" -ForegroundColor Yellow
        
        $uploadScript = @"
import os
import glob
from roboflow import Roboflow

api_key = os.environ.get("ROBOFLOW_API_KEY", "")
workspace = os.environ.get("ROBOFLOW_WORKSPACE", "wsnzs-workspace")
project_name = os.environ.get("ROBOFLOW_PROJECT", "3d-asset-pipeline")

rf = Roboflow(api_key=api_key)
project = rf.workspace(workspace).project(project_name)

raw_dir = r"$rawDir"
extensions = ("*.jpg", "*.jpeg", "*.png")
images = []
for ext in extensions:
    images.extend(glob.glob(os.path.join(raw_dir, "**", ext), recursive=True))

print(f"Found {len(images)} images to upload")

uploaded = 0
for i, img_path in enumerate(images):
    try:
        project.upload(img_path, split="train")
        uploaded += 1
        if (i + 1) % 10 == 0:
            print(f"  Uploaded {uploaded}/{len(images)}")
    except Exception as e:
        print(f"  Failed: {os.path.basename(img_path)} — {e}")

print(f"Done: {uploaded}/{len(images)} images uploaded")
"@
        $scriptPath = Join-Path $roboflowRoot "scripts/_upload_images.py"
        Set-Content -Path $scriptPath -Value $uploadScript
        
        if (-not $DryRun) {
            $venvPython = Join-Path $roboflowRoot ".venv/Scripts/python.exe"
            if (-not (Test-Path $venvPython)) { $venvPython = "python" }
            & $venvPython $scriptPath
        }
    }
}

Write-Host ""

# Show summary of raw data
Write-Host "Training Data Summary:" -ForegroundColor Yellow
$classDirs = Get-ChildItem $rawDir -Directory -ErrorAction SilentlyContinue
if ($classDirs) {
    foreach ($dir in $classDirs) {
        $imgCount = (Get-ChildItem $dir.FullName -File -Include "*.jpg", "*.jpeg", "*.png" -Recurse -ErrorAction SilentlyContinue).Count
        Write-Host "  $($dir.Name): $imgCount images" -ForegroundColor White
    }
}
else {
    Write-Host "  No training data captured yet" -ForegroundColor Gray
}

Write-Host ""
exit 0
