#Requires -Version 7.0
# Stage: Build
# Dependencies: Node.js (1003_Install-Node)
# Description: Install Veil npm dependencies and run Next.js production build.

<#
.SYNOPSIS
    Build the AitherVeil Next.js dashboard (local, no Docker required).

.DESCRIPTION
    Automates the full Veil build pipeline:
      1. Validates Node.js and npm are available
      2. Runs npm install (installs all dependencies from package.json)
      3. Generates architecture stats, docs data, and benchmarks (non-fatal)
      4. Runs Next.js production build (npm run build)

    Idempotent — safe to run repeatedly. Skips npm install if node_modules
    is up-to-date (package-lock.json unchanged).

.PARAMETER VeilPath
    Path to the AitherVeil directory. Defaults to auto-detection.

.PARAMETER SkipInstall
    Skip npm install (assume dependencies are already installed).

.PARAMETER SkipGenerate
    Skip prebuild generation (stats, docs, benchmarks).

.PARAMETER DevMode
    Run dev server instead of production build (npm run dev).

.EXAMPLE
    .\2004_Build-Veil.ps1
    .\2004_Build-Veil.ps1 -DevMode
    .\2004_Build-Veil.ps1 -SkipGenerate -Verbose

.NOTES
    Category: build
    Platform: Windows, Linux, macOS
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$VeilPath,

    [switch]$SkipInstall,
    [switch]$SkipGenerate,
    [switch]$DevMode,

    [Parameter()]
    [hashtable]$Configuration
)

# ── Init ──────────────────────────────────────────────────────────────────

$initPath = Join-Path $PSScriptRoot "_init.ps1"
if (Test-Path $initPath) { . $initPath }

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source '2004_Build-Veil'
    } else {
        $prefix = switch ($Level) {
            'Success' { '[OK]' }
            'Warning' { '[WARN]' }
            'Error'   { '[ERR]' }
            default   { '[INFO]' }
        }
        Write-Host "$prefix $Message"
    }
}

# ── Locate Veil ───────────────────────────────────────────────────────────

if (-not $VeilPath) {
    # Walk up from script dir to find AitherOS/apps/AitherVeil
    $searchBase = (Get-Item $PSScriptRoot).Parent.Parent.Parent  # AitherZero -> repo root
    $candidates = @(
        (Join-Path $searchBase.FullName "AitherOS/apps/AitherVeil"),
        (Join-Path $searchBase.Parent.FullName "AitherOS/apps/AitherVeil")
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "package.json")) {
            $VeilPath = $c
            break
        }
    }
}

if (-not $VeilPath -or -not (Test-Path (Join-Path $VeilPath "package.json"))) {
    Write-ScriptLog "Cannot locate AitherVeil directory. Use -VeilPath to specify." -Level Error
    exit 1
}

$VeilPath = (Resolve-Path $VeilPath).Path
Write-ScriptLog "Veil directory: $VeilPath"

# ── Prerequisites ─────────────────────────────────────────────────────────

Write-ScriptLog "Checking prerequisites..."

# Node.js
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-ScriptLog "Node.js not found. Run 10-devtools/1003_Install-Node.ps1 first." -Level Error
    exit 1
}
$nodeVersion = node --version
Write-ScriptLog "Node.js: $nodeVersion"

# npm
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-ScriptLog "npm not found." -Level Error
    exit 1
}
$npmVersion = npm --version
Write-ScriptLog "npm: $npmVersion"

# ── npm install ───────────────────────────────────────────────────────────

if (-not $SkipInstall) {
    Write-ScriptLog "Installing npm dependencies..."

    if ($PSCmdlet.ShouldProcess("AitherVeil", "npm install")) {
        Push-Location $VeilPath
        try {
            # Check if node_modules exists and package-lock hasn't changed
            $nodeModules = Join-Path $VeilPath "node_modules"
            $lockFile = Join-Path $VeilPath "package-lock.json"
            $stampFile = Join-Path $nodeModules ".install-stamp"

            $needsInstall = $true
            if ((Test-Path $nodeModules) -and (Test-Path $stampFile) -and (Test-Path $lockFile)) {
                $stampTime = (Get-Item $stampFile).LastWriteTime
                $lockTime = (Get-Item $lockFile).LastWriteTime
                if ($stampTime -ge $lockTime) {
                    Write-ScriptLog "Dependencies up-to-date (skipping npm install)"
                    $needsInstall = $false
                }
            }

            if ($needsInstall) {
                $result = npm install 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-ScriptLog "npm install failed: $result" -Level Error
                    exit 1
                }
                # Write stamp file so we can skip next time
                "" | Set-Content $stampFile -NoNewline
                Write-ScriptLog "npm install complete" -Level Success
            }
        } finally {
            Pop-Location
        }
    }
} else {
    Write-ScriptLog "Skipping npm install (--SkipInstall)"
}

# ── Prebuild generation ──────────────────────────────────────────────────

if (-not $SkipGenerate) {
    Write-ScriptLog "Running prebuild generators..."

    Push-Location $VeilPath
    try {
        # Stats — required
        Write-ScriptLog "  Generating architecture stats..."
        $statsResult = npm run generate:stats 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "  Stats generation failed (non-fatal): $statsResult" -Level Warning
        } else {
            Write-ScriptLog "  Stats: OK" -Level Success
        }

        # Docs — required
        Write-ScriptLog "  Generating docs data..."
        $docsResult = npm run generate:docs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "  Docs generation failed (non-fatal): $docsResult" -Level Warning
        } else {
            Write-ScriptLog "  Docs: OK" -Level Success
        }

        # Benchmarks — optional (data files may not exist)
        Write-ScriptLog "  Generating benchmarks..."
        $benchResult = npm run generate:benchmarks 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-ScriptLog "  Benchmarks skipped (no eval data — this is normal)" -Level Warning
        } else {
            Write-ScriptLog "  Benchmarks: OK" -Level Success
        }
    } finally {
        Pop-Location
    }
} else {
    Write-ScriptLog "Skipping prebuild generation (--SkipGenerate)"
}

# ── Build / Dev ───────────────────────────────────────────────────────────

Push-Location $VeilPath
try {
    if ($DevMode) {
        Write-ScriptLog "Starting Veil dev server..."
        if ($PSCmdlet.ShouldProcess("AitherVeil", "npm run dev")) {
            $env:SKIP_PREBUILD = "1"
            npm run dev
        }
    } else {
        Write-ScriptLog "Building Veil for production..."
        if ($PSCmdlet.ShouldProcess("AitherVeil", "npm run build")) {
            $env:SKIP_PREBUILD = "1"  # We already ran generators above
            $buildResult = npm run build 2>&1
            $buildExit = $LASTEXITCODE

            if ($buildExit -ne 0) {
                Write-ScriptLog "Next.js build failed!" -Level Error
                # Output last 50 lines for context
                $lines = ($buildResult -split "`n") | Select-Object -Last 50
                foreach ($line in $lines) {
                    Write-Host "  $line"
                }
                exit 1
            }

            Write-ScriptLog "Veil production build complete!" -Level Success
        }
    }
} finally {
    Pop-Location
}
