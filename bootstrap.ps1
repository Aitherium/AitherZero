<#
.SYNOPSIS
    AitherZero one-paste bootstrap: get the framework onto a blank machine and run a playbook.

.DESCRIPTION
    This is the door. Everything else is a playbook.

      1. Ensure PowerShell 7+ (winget / brew / apt / dnf). Re-exec under pwsh if
         we started in Windows PowerShell 5.1.
      2. Fetch AitherZero into -InstallPath (default ~/.aitherzero) as a zip -
         git is NOT a prerequisite; installing git is one of the playbook's jobs.
      3. build.ps1 -> Import-Module AitherZero (into the caller's session).
      4. Invoke-AitherPlaybook -Name <Playbook>   (default: dev-workstation)

    It runs on Windows PowerShell 5.1 AND pwsh 7, so it must stay free of
    PS7-only syntax (no ?:, ??, ?., &&, $IsWindows).

.PARAMETER Playbook
    Playbook to run after install. Default 'dev-workstation'. Pass 'none' to
    only install + import the framework.

.PARAMETER Variables
    Hashtable forwarded to Invoke-AitherPlaybook -Variables.

.PARAMETER InstallPath
    Where AitherZero lives. Default: $HOME/.aitherzero.

.PARAMETER Ref
    Git ref (branch or tag) of Aitherium/AitherZero to fetch. Default 'main'.

.PARAMETER Update
    Re-download AitherZero even if -InstallPath already has it.

.PARAMETER DryRun
    Install + import, then show the playbook plan without running it.

.PARAMETER NonInteractive
    Never prompt; auto-approve feature toggles; skip login-type steps.

.EXAMPLE
    # Blank Windows machine - one paste in any PowerShell window:
    irm https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex

.EXAMPLE
    # With parameters (the pipe-to-iex form cannot take them):
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1))) -Playbook node-onboard -Variables @{ Token = 'x' }

.EXAMPLE
    # Env-var form, for the pipe-to-iex one-liner:
    $env:AITHERZERO_PLAYBOOK = 'none'; irm .../bootstrap.ps1 | iex

.EXAMPLE
    # From a checkout:
    ./bootstrap.ps1 -Playbook dev-workstation -DryRun
#>
[CmdletBinding()]
param(
    [string]$Playbook = $(if ($env:AITHERZERO_PLAYBOOK) { $env:AITHERZERO_PLAYBOOK } else { 'dev-workstation' }),
    [hashtable]$Variables = @{},
    [string]$InstallPath = $(if ($env:AITHERZERO_ROOT) { $env:AITHERZERO_ROOT } else { Join-Path $HOME '.aitherzero' }),
    [string]$Ref = $(if ($env:AITHERZERO_REF) { $env:AITHERZERO_REF } else { 'main' }),
    [switch]$Update,
    [switch]$DryRun,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$Repo = 'Aitherium/AitherZero'

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    $m" -ForegroundColor Yellow }
function Test-Cmd   { param([string]$n) return [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# $IsWindows does not exist on 5.1; Desktop edition is Windows by definition.
$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($PSVersionTable.PSEdition -eq 'Core' -and [Environment]::OSVersion.Platform -eq 'Win32NT')
$onMac     = (-not $onWindows) -and (Test-Path '/System/Library/CoreServices')
$onLinux   = (-not $onWindows) -and (-not $onMac)

if ($NonInteractive) { $env:AITHERZERO_NONINTERACTIVE = '1' }

# Refresh this process's PATH from the persisted values so a tool installed
# a moment ago (pwsh) resolves without a new terminal. Windows-only concept.
function Update-SessionPath {
    if (-not $onWindows) { return }
    $m = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($m, $u, $env:PATH) | Where-Object { $_ }) -join ';'
}

# -- 1. PowerShell 7 --
Write-Step "PowerShell 7+"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Ok "running pwsh $($PSVersionTable.PSVersion)"
}
else {
    Update-SessionPath
    if (-not (Test-Cmd pwsh)) {
        if ($onWindows) {
            if (-not (Test-Cmd winget)) {
                throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."
            }
            Write-Warn "installing PowerShell 7 via winget (a UAC prompt may appear)"
            & winget install -e --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements
            Update-SessionPath
        }
        elseif ($onMac) {
            if (-not (Test-Cmd brew)) { throw "Homebrew not found. Install it from https://brew.sh, then re-run." }
            & brew install --cask powershell
        }
        else {
            throw "pwsh not found. Use bootstrap.sh on Linux - it installs PowerShell 7 for your distro and then runs this script."
        }
    }
    if (-not (Test-Cmd pwsh)) {
        throw "PowerShell 7 was installed but 'pwsh' is not on PATH yet. Open a new terminal and re-run."
    }
    Write-Ok "pwsh installed; re-launching under it"
    # Re-exec THIS script under pwsh. When run via `irm | iex` there is no
    # file, and $MyInvocation.MyCommand.ScriptBlock is NOT the full script
    # (measured 2026-09-12: pwsh -File on that dump failed with "terminator
    # '#>' is missing"). Fetch the canonical file for -Ref instead - the
    # session that got here just proved it can reach GitHub.
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) {
        $self = Join-Path ([IO.Path]::GetTempPath()) 'aitherzero-bootstrap.ps1'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/$Ref/bootstrap.ps1" -OutFile $self
    }
    $fwd = @('-Playbook', $Playbook, '-InstallPath', $InstallPath, '-Ref', $Ref)
    if ($Update)         { $fwd += '-Update' }
    if ($DryRun)         { $fwd += '-DryRun' }
    if ($NonInteractive) { $fwd += '-NonInteractive' }
    if ($Variables.Count -gt 0) {
        # Hashtables do not survive a process boundary; pass as JSON via env.
        $env:AITHERZERO_VARIABLES_JSON = ($Variables | ConvertTo-Json -Compress)
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $self @fwd
    exit $LASTEXITCODE
}

if ($env:AITHERZERO_VARIABLES_JSON -and $Variables.Count -eq 0) {
    $obj = $env:AITHERZERO_VARIABLES_JSON | ConvertFrom-Json
    $Variables = @{}
    foreach ($p in $obj.PSObject.Properties) { $Variables[$p.Name] = $p.Value }
    Remove-Item Env:\AITHERZERO_VARIABLES_JSON -ErrorAction SilentlyContinue
}

# -- 2. Fetch AitherZero --
Write-Step "AitherZero -> $InstallPath"
$manifest = Join-Path $InstallPath 'AitherZero.psd1'
$buildScript = Join-Path $InstallPath 'build.ps1'
$haveCheckout = Test-Path $buildScript

if ($haveCheckout -and -not $Update) {
    Write-Ok "already present (pass -Update to refresh)"
}
else {
    if (Test-Path (Join-Path $InstallPath '.git')) {
        if (-not (Test-Cmd git)) { throw "$InstallPath is a git checkout but git is not on PATH; cannot -Update it. Use git yourself, or delete it and re-run." }
        Write-Ok "git checkout detected; pulling $Ref"
        & git -C $InstallPath fetch --depth 1 origin $Ref
        & git -C $InstallPath checkout -q FETCH_HEAD
    }
    else {
        # Zip, not clone: git is not a prerequisite of the framework that installs git.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $zipUrl = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("aitherzero-" + [Guid]::NewGuid().ToString('N') + ".zip")
        Write-Ok "downloading $zipUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $tmp
        $stage = "$tmp.d"
        Expand-Archive -Path $tmp -DestinationPath $stage -Force
        $inner = Get-ChildItem -Path $stage -Directory | Select-Object -First 1
        if (Test-Path $InstallPath) { Remove-Item -Recurse -Force $InstallPath }
        New-Item -ItemType Directory -Force -Path (Split-Path $InstallPath -Parent) | Out-Null
        Move-Item -Path $inner.FullName -Destination $InstallPath
        Remove-Item -Recurse -Force $stage, $tmp -ErrorAction SilentlyContinue
        Write-Ok "unpacked $Ref"
    }
}

# -- 3. Build + import --
Write-Step "build + import module"
Push-Location $InstallPath
try {
    # build.ps1 narrates every file via Write-Host (stream 6); keep the door quiet.
    & $buildScript 6>$null | Out-Null
}
finally { Pop-Location }
if (-not (Test-Path $manifest)) { throw "build.ps1 did not produce $manifest" }
$env:AITHERZERO_ROOT = $InstallPath
Import-Module $manifest -Force -Global
Write-Ok "AitherZero $((Get-Module AitherZero).Version) imported"

# -- 4. Playbook --
if ($Playbook -eq 'none' -or [string]::IsNullOrWhiteSpace($Playbook)) {
    Write-Step "no playbook requested"
    Write-Ok "try: Invoke-AitherPlaybook dev-workstation   then   Invoke-AitherPlaybook connect   (Get-AitherPlaybook lists the rest)"
    return
}

Write-Step "playbook: $Playbook"
$pbArgs = @{ Name = $Playbook }
if ($Variables.Count -gt 0) { $pbArgs.Variables = $Variables }
if ($DryRun) { $pbArgs.DryRun = $true }
$result = Invoke-AitherPlaybook @pbArgs
if ($result -and $result.PSObject.Properties['Failed'] -and $result.Failed -gt 0) {
    exit 1
}
