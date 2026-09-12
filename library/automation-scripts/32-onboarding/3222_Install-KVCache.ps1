#Requires -Version 7.0

<#
.SYNOPSIS
    Install aither-kvcache (TurboQuant / TriAttention / KVTransfer) into the local Python.
.DESCRIPTION
    `pip install --upgrade "aither-kvcache[<Extras>]"` and an import check.
    The vLLM plugin activates inside the vLLM that `adk setup` runs (v0.15+);
    calibration profiles (e.g. Qwen3.5) ship in the package - there is no
    separate model download for the cache itself.
.PARAMETER Extras
    pip extras: vllm (default), triton, transfer, all, or '' for the core lib.
.PARAMETER DryRun
    Print the pip command.
.EXAMPLE
    ./3222_Install-KVCache.ps1 -Extras all
.NOTES
    Stage: Onboarding
    Dependencies: 1004_Install-Python
    Tags: kvcache, vllm, inference, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Extras = 'vllm',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

Update-AitherSessionPath
# `python` before `python3` on Windows: `python3` there is usually the
# Microsoft Store stub under WindowsApps, which opens the Store instead of running.
$candidates = if ($IsWindows) { @('python', 'python3') } else { @('python3', 'python') }
$py = Get-Command $candidates -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1
if (-not $py) { throw "Python not found. Run 10-devtools/1004_Install-Python first." }

$spec = if ([string]::IsNullOrWhiteSpace($Extras)) { 'aither-kvcache' } else { "aither-kvcache[$Extras]" }
$pipArgs = @('-m', 'pip', 'install', '--upgrade', $spec)
if ($DryRun) { Write-Host "[DRY RUN] $($py.Source) $($pipArgs -join ' ')"; return }

if ($PSCmdlet.ShouldProcess("pip", "install $spec")) {
    & $py.Source @pipArgs
    if ($LASTEXITCODE -ne 0) { throw "pip exited with code $LASTEXITCODE" }
}

$ver = (& $py.Source -c "import aither_kvcache, sys; print(getattr(aither_kvcache, '__version__', 'installed'))" 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "aither-kvcache installed but 'import aither_kvcache' failed: $ver" }
Write-Host "aither-kvcache $ver" -ForegroundColor Green
