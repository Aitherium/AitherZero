#Requires -Version 7.0

<#
.SYNOPSIS
    Build the awnix image - the Linux underneath the Aither World - from its Containerfile.
.DESCRIPTION
    Clones github.com/Aitherium/awnix (or updates an existing checkout) and
    runs `podman build -t awnix:<Tag> -f Containerfile .` - docker is used
    when podman is absent. Optionally turns the image into a bootable disk
    with bootc-image-builder (-Bootable iso|qcow2|ami|vmdk|raw; needs a
    Linux host or a Linux podman machine, privileged).
.PARAMETER Path
    Checkout location. Default: ~/.aitherzero/awnix
.PARAMETER Tag
    Image tag. Default 'latest'.
.PARAMETER Bootable
    Also run bootc-image-builder for this output type. Default: none.
.PARAMETER DryRun
    Print the commands.
.EXAMPLE
    ./3223_Build-Awnix.ps1
.EXAMPLE
    ./3223_Build-Awnix.ps1 -Bootable qcow2
.NOTES
    Stage: Onboarding
    Dependencies: podman or docker, git
    Tags: awnix, bootc, podman, image, onboarding
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Path = (Join-Path $HOME '.aitherzero' 'awnix'),
    [string]$Tag = 'latest',
    [ValidateSet('', 'iso', 'qcow2', 'ami', 'vmdk', 'raw')]
    [string]$Bootable = '',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

Update-AitherSessionPath
$engine = Get-Command podman, docker -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $engine) { throw "Neither podman nor docker found. Windows: winget install RedHat.Podman-Desktop (or Docker Desktop); Linux: apt/dnf install podman." }
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw "git not found. Run 10-devtools/1002_Install-Git first." }

$cmds = @()
if (Test-Path (Join-Path $Path '.git')) { $cmds += "git -C `"$Path`" pull --ff-only" }
else { $cmds += "git clone --depth 1 https://github.com/Aitherium/awnix `"$Path`"" }
$cmds += "$($engine.Name) build -t awnix:$Tag -f Containerfile ."
if ($Bootable) {
    $cmds += "$($engine.Name) run --rm -it --privileged -v /var/lib/containers/storage:/var/lib/containers/storage -v `"$Path/output`":/output quay.io/centos-bootc/bootc-image-builder:latest --type $Bootable --local awnix:$Tag"
}

if ($DryRun) { $cmds | ForEach-Object { Write-Host "[DRY RUN] $_" }; return }

if (Test-Path (Join-Path $Path '.git')) {
    if ($PSCmdlet.ShouldProcess($Path, "git pull")) { & $git.Source -C $Path pull --ff-only; if ($LASTEXITCODE) { throw "git pull failed" } }
} else {
    if ($PSCmdlet.ShouldProcess($Path, "git clone awnix")) { & $git.Source clone --depth 1 https://github.com/Aitherium/awnix $Path; if ($LASTEXITCODE) { throw "git clone failed" } }
}

Push-Location $Path
try {
    if ($PSCmdlet.ShouldProcess("awnix:$Tag", "$($engine.Name) build")) {
        & $engine.Source build -t "awnix:$Tag" -f Containerfile .
        if ($LASTEXITCODE) { throw "$($engine.Name) build exited with code $LASTEXITCODE" }
    }
    if ($Bootable -and $PSCmdlet.ShouldProcess("awnix:$Tag", "bootc-image-builder --type $Bootable")) {
        New-Item -ItemType Directory -Force (Join-Path $Path 'output') | Out-Null
        & $engine.Source run --rm -it --privileged -v /var/lib/containers/storage:/var/lib/containers/storage -v "$Path/output:/output" quay.io/centos-bootc/bootc-image-builder:latest --type $Bootable --local "awnix:$Tag"
        if ($LASTEXITCODE) { throw "bootc-image-builder exited with code $LASTEXITCODE" }
    }
}
finally { Pop-Location }

$img = (& $engine.Source images --format '{{.Repository}}:{{.Tag}} {{.Size}}' awnix 2>&1 | Out-String).Trim()
if (-not $img) { throw "build finished but 'awnix:$Tag' is not in $($engine.Name) images" }
Write-Host "awnix image: $img" -ForegroundColor Green
Write-Host "Next: layer an agent on it - FROM awnix:$Tag / RUN pip3 install awdk (see the awnix README)."
