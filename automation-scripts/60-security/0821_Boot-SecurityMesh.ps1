$PythonPath = "d:\AitherOS-Fresh\AitherOS\.venv\Scripts\python.exe"
$AitherOSRoot = "d:\AitherOS-Fresh\AitherOS"
$env:PYTHONPATH = $AitherOSRoot
$LogDir = "d:\AitherOS-Fresh\logs\startup"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Stop-PortOwner {
    param($Port)
    $RetryCount = 3
    
    for ($i = 0; $i -lt $RetryCount; $i++) {
        $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if (-not $conn) { return }
        
        $procId = $conn.OwningProcess
        Write-Host "Killing process on port $Port (PID $procId)... (Attempt $($i+1))"
        
        # Try Stop-Process
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
        
        # Try aggressive taskkill
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            Start-Process -FilePath "taskkill.exe" -ArgumentList "/F /PID $procId" -NoNewWindow -Wait
        }
        
        Start-Sleep -Seconds 2
        
        if (-not (Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) {
            Write-Host "Port $Port is now free."
            return
        }
    }
    Write-Warning "Failed to clear port $Port after $RetryCount attempts."
}

function Start-Service {
    param($Name, $Port, $Script)
    Stop-PortOwner $Port # Ensure clean start
    
    Write-Host "Starting $Name on port $Port..."
    $stdOut = "$LogDir\$Name.log"
    $stdErr = "$LogDir\$Name.err.log"
    # Clear logs
    if (Test-Path $stdErr) { Remove-Item $stdErr }
    
    Start-Process -FilePath $PythonPath -ArgumentList "$AitherOSRoot\$Script" -RedirectStandardOutput $stdOut -RedirectStandardError $stdErr -WindowStyle Hidden
    Write-Host "Started $Name. Logs at $stdErr"
}

Start-Service -Name "Inspector" -Port 8134 -Script "services\security\AitherInspector.py"
Start-Service -Name "Chaos" -Port 8160 -Script "services\security\AitherChaos.py"
Start-Service -Name "Jail" -Port 8163 -Script "services\security\AitherJail.py"
Start-Service -Name "Guard" -Port 8162 -Script "services\security\AitherGuard.py"

Write-Host "Waiting 10 seconds for services to initialize..."
Start-Sleep -Seconds 10

# Check logs for errors immediately
Get-ChildItem "$LogDir\*.err.log" | ForEach-Object {
    if ((Get-Item $_.FullName).Length -gt 0) {
        Write-Host "⚠️  Error log found for $($_.BaseName) (Tail 5):" -ForegroundColor Red
        Get-Content $_.FullName -Tail 5 | Write-Host -ForegroundColor Red
    }
}

Write-Host "Running Validation Script..."
& "d:\AitherOS-Fresh\AitherZero\library\automation-scripts\0820_Setup-SecurityMesh.ps1"
