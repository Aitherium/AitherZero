#Requires -Version 7.0

<#
.SYNOPSIS
    Install awnix (the Aither World's Linux) as a WSL2 distro via Windows Goodbye.
.DESCRIPTION
    On Windows 10/11 (x86_64), downloads the official MIT-licensed Windows Goodbye
    installer from https://goodbyewindows.sh/WindowsGoodbye.ps1 and imports `awnix`
    as a WSL2 distro from its SHA-256-verified release archive (no admin, no reboot,
    no boot changes).

    Idempotent: if the distro already exists (`wsl -l -q`), verifies it boots and
    skips re-importing. On Linux or macOS, logs a note and exits cleanly.
.PARAMETER DistroName
    WSL2 distro name to import (default: 'awnix').
.PARAMETER InstallDir
    Directory for the WSL2 virtual disk (default: Windows Goodbye default, `%LOCALAPPDATA%\awnix\wsl`).
.PARAMETER DryRun
    Print what would run (or run WindowsGoodbye.ps1 -DryRun) without importing.
.EXAMPLE
    ./3274_Install-Awnix.ps1
.EXAMPLE
    ./3274_Install-Awnix.ps1 -DryRun
.NOTES
    Stage: Onboarding
    Dependencies: None
    Tags: awnix, wsl2, windows-goodbye, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DistroName = 'awnix',
    [string]$InstallDir = '',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function Write-ScriptLog {
    param([string]$Message, [string]$Level = 'Information')
    $mapped = if ($Level -eq 'Success') { 'Information' } else { $Level }
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $mapped -Source '3274_Install-Awnix'
    } else {
        Write-Host "[$Level] $Message"
    }
}

$InstallerUrl = 'https://goodbyewindows.sh/WindowsGoodbye.ps1'

try {
    if (-not $IsWindows) {
        Write-ScriptLog "Host is not Windows — skipping WSL2 awnix import (awnix ISO/container is for Linux/bare-metal hosts)."
        return
    }

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) {
        throw "WSL is not installed. Run 'wsl --install --no-distribution' in an elevated PowerShell, reboot if prompted, then re-run."
    }

    # Check if distro already exists (wsl -l -q emits UTF-16LE with NULs on some builds).
    $rawList = (& $wsl.Source -l -q 2>$null | Out-String) -replace "`0", ''
    $distros = @($rawList -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($distros -contains $DistroName) {
        Write-ScriptLog "WSL2 distro '$DistroName' is already installed — verifying boot..."
        if ($DryRun) {
            Write-ScriptLog "[DRY RUN] would verify: wsl -d $DistroName -- cat /etc/os-release"
            return
        }
        $osRel = (& $wsl.Source -d $DistroName -- cat /etc/os-release 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "WSL2 distro '$DistroName' exists but failed to start: $osRel"
        }
        $pretty = (($osRel -split "`r?`n" | Where-Object { $_ -match '^PRETTY_NAME=' } | Select-Object -First 1) -replace '^PRETTY_NAME=', '').Trim('"')
        Write-ScriptLog "awnix verified: $pretty (wsl -d $DistroName)" -Level Success
        return
    }

    if ($DryRun) {
        Write-ScriptLog "[DRY RUN] would download $InstallerUrl and run WindowsGoodbye.ps1 -DistroName $DistroName -NoLaunch"
        return
    }

    if ($PSCmdlet.ShouldProcess($DistroName, "import awnix via Windows Goodbye ($InstallerUrl)")) {
        $tmpScript = Join-Path ([IO.Path]::GetTempPath()) ("WindowsGoodbye-" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ".ps1")
        try {
            Write-ScriptLog "Downloading Windows Goodbye installer from $InstallerUrl..."
            Invoke-RestMethod -Uri $InstallerUrl -OutFile $tmpScript
            $wgArgs = @('-DistroName', $DistroName, '-NoLaunch')
            if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
                $wgArgs += @('-InstallDir', $InstallDir)
            }
            Write-ScriptLog "Running WindowsGoodbye.ps1 $($wgArgs -join ' ')..."
            & $tmpScript @wgArgs
            if ($LASTEXITCODE -ne 0) {
                throw "WindowsGoodbye.ps1 exited with code $LASTEXITCODE"
            }
        } finally {
            if (Test-Path $tmpScript) { Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue }
        }

        # Re-assert: prove the imported distro boots and reports /etc/os-release.
        $osRel = (& $wsl.Source -d $DistroName -- cat /etc/os-release 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw "awnix imported as '$DistroName' but failed to start: $osRel"
        }
        $pretty = (($osRel -split "`r?`n" | Where-Object { $_ -match '^PRETTY_NAME=' } | Select-Object -First 1) -replace '^PRETTY_NAME=', '').Trim('"')
        Write-ScriptLog "awnix installed and verified: $pretty (open with: wsl -d $DistroName)" -Level Success
    }
}
catch {
    Write-ScriptLog "awnix installation failed: $_" -Level Error
    throw
}
