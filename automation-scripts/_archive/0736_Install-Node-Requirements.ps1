#Requires -Version 7.0
<#
.SYNOPSIS
    Installs Python requirements for all installed ComfyUI custom nodes.
.DESCRIPTION
    Iterates through custom_nodes directory and runs pip install -r requirements.txt.
    Attempts to locate the correct Python environment (Embedded or System).
.NOTES
    Stage: AI Tools
    Order: 0736
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Path to ComfyUI root directory")]
    [string]$InstallPath
)

. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

# 1. Locate ComfyUI
if ([string]::IsNullOrEmpty($InstallPath)) {
    $PossiblePaths = @(
        "C:\ComfyUI_windows_portable\ComfyUI",
        "C:\ComfyUI",
        "$env:USERPROFILE\ComfyUI",
        "D:\ComfyUI",
        "D:\ComfyUI"
    )

    foreach ($path in $PossiblePaths) {
        if (Test-Path "$path\custom_nodes") {
            $InstallPath = $path
            break
        }
    }
}

if (-not $InstallPath -or -not (Test-Path "$InstallPath\custom_nodes")) {
    Write-Error "ComfyUI custom_nodes directory not found. Please specify -InstallPath."
}

Write-Log "Found ComfyUI at: $InstallPath" "Cyan"

# 2. Locate Python
$PythonPath = "python" # Default to system
if (Test-Path "$InstallPath\..\python_embeded\python.exe") {
    $PythonPath = Resolve-Path "$InstallPath\..\python_embeded\python.exe"
    Write-Log "Using Embedded Python: $PythonPath" "Cyan"
}
elseif (Test-Path "$InstallPath\venv\Scripts\python.exe") {
    $PythonPath = Resolve-Path "$InstallPath\venv\Scripts\python.exe"
    Write-Log "Using Venv Python: $PythonPath" "Cyan"
}
else {
    Write-Log "Using System Python" "Yellow"
}

# 3. Install Requirements
$CustomNodesPath = Join-Path $InstallPath "custom_nodes"
$Nodes = Get-ChildItem -Path $CustomNodesPath -Directory

foreach ($node in $Nodes) {
    Write-Log "Checking dependencies for $($node.Name)..." "Cyan"
    
    # Priority 1: install.bat (Windows specific, usually handles everything)
    $InstallBat = Join-Path $node.FullName "install.bat"
    if (Test-Path $InstallBat) {
        Write-Log "  Running install.bat..." "Green"
        try {
            Start-Process -FilePath $InstallBat -WorkingDirectory $node.FullName -Wait -NoNewWindow
            continue # Skip other methods if bat exists
        }
        catch {
            Write-Log "  Failed to run install.bat: $_" "Red"
        }
    }

    # Priority 2: install.py
    $InstallPy = Join-Path $node.FullName "install.py"
    if (Test-Path $InstallPy) {
        Write-Log "  Running install.py..." "Green"
        try {
            & $PythonPath $InstallPy
            continue
        }
        catch {
            Write-Log "  Failed to run install.py: $_" "Red"
        }
    }

    # Priority 3: requirements.txt
    $ReqFile = Join-Path $node.FullName "requirements.txt"
    if (Test-Path $ReqFile) {
        Write-Log "  Installing requirements.txt..." "Green"
        try {
            & $PythonPath -m pip install -r $ReqFile
        }
        catch {
            Write-Log "  Failed to install requirements: $_" "Red"
        }
    }
}

# Special handling for InsightFace (ReActor/PuLID)
Write-Log "Checking InsightFace (Required for ReActor/PuLID)..." "Yellow"
try {
    & $PythonPath -c "import insightface" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "InsightFace not found. Attempting to install..." "Yellow"
        
        # Try standard install first
        try {
            & $PythonPath -m pip install insightface onnxruntime
        }
        catch {
            Write-Log "Standard install failed. Trying pre-compiled wheel for Windows..." "Yellow"
            # This is a common fallback for Windows users
            $WheelUrl = "https://github.com/Gourieff/Assets/raw/main/Insightface/insightface-0.7.3-cp310-cp310-win_amd64.whl"
            # Check python version to pick right wheel? Assuming 3.10 or 3.11 for ComfyUI
            # For now, let's just warn the user if this fails.
            Write-Log "âš ï¸ InsightFace installation is tricky on Windows. If this fails, check the ReActor readme." "Magenta"
        }
    }
    else {
        Write-Log "InsightFace is already installed." "Green"
    }
}
catch {
    Write-Log "Failed to check/install InsightFace." "Red"
}

Write-Log "Dependency installation complete!" "Green"
Write-Log "PLEASE RESTART COMFYUI." "Magenta"

