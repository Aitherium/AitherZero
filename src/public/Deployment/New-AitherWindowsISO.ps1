#Requires -Version 7.0

<#
.SYNOPSIS
    Build a custom Windows Server ISO and deploy AitherOS nodes via OpenTofu + Hyper-V.

.DESCRIPTION
    End-to-end pipeline that:
      1. Builds a custom Windows Server 2025 Core ISO (via 3105_Build-WindowsISO.ps1)
      2. Provisions Hyper-V VMs using OpenTofu (modules/aitheros-node)
      3. Waits for VMs to install and WinRM to become available
      4. Triggers post-install configuration via the Elysium pipeline
      5. Joins nodes to the AitherMesh

    This is the single command to go from stock ISO → running AitherOS node.

.PARAMETER SourceISO
    Path to the stock Windows Server 2025 ISO. Required if -SkipISOBuild is not set.

.PARAMETER ISOPath
    Path to a pre-built custom AitherOS ISO. If provided, skips ISO build.

.PARAMETER NodeName
    Name(s) for the VM(s) to create. Default: aither-node-01

.PARAMETER NodeCount
    Number of identical nodes to create (alternative to NodeName array).

.PARAMETER Profile
    AitherOS deployment profile. Default: Core

.PARAMETER CpuCount
    Virtual CPUs per node. Default: 4

.PARAMETER MemoryGB
    Startup memory in GB. Default: 4

.PARAMETER DiskGB
    System disk size in GB. Default: 80

.PARAMETER SwitchName
    Hyper-V virtual switch name. Default: AitherSwitch

.PARAMETER SwitchType
    Virtual switch type (Internal, External, Private). Default: Internal

.PARAMETER VhdPath
    Directory for VHD storage. Default: C:\VMs\AitherOS

.PARAMETER AdminPassword
    Administrator password for the nodes. Auto-generated if omitted.

.PARAMETER MeshCoreUrl
    MeshCore endpoint for auto-join. Default: http://192.168.1.100:8125

.PARAMETER SkipISOBuild
    Skip ISO build (use existing ISO at -ISOPath).

.PARAMETER SkipTofuApply
    Skip OpenTofu apply (just build ISO and generate configs).

.PARAMETER SkipPostInstall
    Skip waiting for WinRM and post-install configuration.

.PARAMETER TofuAutoApprove
    Auto-approve OpenTofu apply without interactive confirmation.

.PARAMETER WaitTimeoutMinutes
    Minutes to wait for VM installation to complete. Default: 20

.PARAMETER DryRun
    Show what would happen without executing.

.PARAMETER Force
    Overwrite existing ISO, destroy existing VMs.

.PARAMETER PassThru
    Return pipeline result object instead of formatted output.

.EXAMPLE
    New-AitherWindowsISO -SourceISO 'C:\ISOs\Server2025.iso'

    Builds ISO, creates one VM, waits for install, configures node.

.EXAMPLE
    New-AitherWindowsISO -SourceISO 'D:\ISOs\26100.iso' -NodeCount 2 -Profile Full -TofuAutoApprove

    Builds ISO and deploys 2 Full-profile nodes without confirmation prompts.

.EXAMPLE
    New-AitherWindowsISO -ISOPath 'C:\ISOs\AitherOS-Server2025-Core.iso' -SkipISOBuild -NodeName 'gpu-node-01' -CpuCount 8 -MemoryGB 16

    Uses pre-built ISO to deploy a high-spec GPU node.

.OUTPUTS
    PSCustomObject with pipeline results (if -PassThru), or formatted console output.

.NOTES
    Prerequisites:
      - Windows ADK (oscdimg.exe) — for ISO build
      - OpenTofu >= 1.6.0 — for VM provisioning
      - Hyper-V role enabled on the host
      - Administrator privileges
#>
function New-AitherWindowsISO {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'BuildISO')]
        [string]$SourceISO,

        [string]$ISOPath,

        [string[]]$NodeName = @('aither-node-01'),

        [int]$NodeCount = 0,

        [ValidateSet('Full', 'Core', 'Minimal', 'GPU', 'Edge')]
        [string]$Profile = 'Core',

        [int]$CpuCount = 4,

        [int]$MemoryGB = 4,

        [int]$DiskGB = 80,

        [string]$SwitchName = 'AitherSwitch',

        [ValidateSet('Internal', 'External', 'Private')]
        [string]$SwitchType = 'Internal',

        [string]$VhdPath = 'C:\VMs\AitherOS',

        [securestring]$AdminPassword,

        [string]$MeshCoreUrl = 'http://192.168.1.100:8125',

        [switch]$SkipISOBuild,

        [switch]$SkipTofuApply,

        [switch]$SkipPostInstall,

        [switch]$TofuAutoApprove,

        [int]$WaitTimeoutMinutes = 20,

        [switch]$DryRun,

        [switch]$Force,

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $moduleRoot = if (Get-Command Get-AitherModuleRoot -ErrorAction SilentlyContinue) {
        Get-AitherModuleRoot
    }
    else {
        (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    }

    $azRoot = Join-Path $moduleRoot 'AitherZero'
    $scriptsDir = Join-Path $azRoot 'library\automation-scripts\31-remote'
    $infraDir = Join-Path $azRoot 'library\infrastructure\environments\local-hyperv'

    # Build node list
    if ($NodeCount -gt 0) {
        $NodeName = 1..$NodeCount | ForEach-Object { "aither-node-$('{0:D2}' -f $_)" }
    }

    $result = [PSCustomObject]@{
        PSTypeName     = 'AitherOS.ISODeployPipeline'
        Timestamp      = Get-Date -Format 'o'
        SourceISO      = $SourceISO
        CustomISO      = $ISOPath
        Nodes          = $NodeName
        Profile        = $Profile
        Phases         = [ordered]@{}
        OverallStatus  = 'NotStarted'
    }

    Write-Host "`n╔════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  AitherOS ISO → Deploy Pipeline            ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "  Nodes:    $($NodeName -join ', ')"
    Write-Host "  Profile:  $Profile"
    Write-Host "  Switch:   $SwitchName ($SwitchType)"
    Write-Host "  Specs:    ${CpuCount}vCPU, ${MemoryGB}GB RAM, ${DiskGB}GB disk"
    Write-Host ""

    # ═══════════════════════════════════════════
    # Phase 0: Auto-Resolve Prerequisites
    # ═══════════════════════════════════════════
    Write-Host "━━━ Phase 0: Prerequisite Resolution ━━━" -ForegroundColor Yellow

    $prereqScope = if ($SkipISOBuild -and $SkipTofuApply) { 'Validate' }
                   elseif ($SkipISOBuild) { 'Deploy' }
                   elseif ($SkipTofuApply) { 'ISO' }
                   else { 'All' }

    if (Get-Command Resolve-AitherInfraPrereqs -ErrorAction SilentlyContinue) {
        $prereqResult = Resolve-AitherInfraPrereqs -Scope $prereqScope -AutoInstall $true -PassThru
        $result.Phases['Prerequisites'] = @{
            Status         = if ($prereqResult.AllSatisfied) { 'Success' } elseif ($prereqResult.RebootRequired) { 'RebootRequired' } else { 'PartialFailure' }
            Results        = $prereqResult.Results
            RebootRequired = $prereqResult.RebootRequired
        }

        if ($prereqResult.RebootRequired -and -not $SkipTofuApply) {
            Write-Warning "Hyper-V requires a reboot before VMs can be created."
            Write-Host "  You can build the ISO now and deploy after reboot:" -ForegroundColor Cyan
            Write-Host "  New-AitherWindowsISO -ISOPath <path> -SkipISOBuild" -ForegroundColor Cyan
            if (-not $SkipISOBuild) {
                Write-Host "  Continuing with ISO build only..." -ForegroundColor Yellow
                $SkipTofuApply = $true
                $SkipPostInstall = $true
            }
            else {
                $result.OverallStatus = 'RebootRequired'
                if ($PassThru) { return $result }
                return
            }
        }
    }
    else {
        # Fallback: lightweight inline prereq checks
        Write-Host "  (Resolve-AitherInfraPrereqs not loaded — running inline checks)" -ForegroundColor Gray
        $infraScriptsDir = Join-Path $azRoot 'library\automation-scripts\01-infrastructure'

        # Check ADK
        if (-not $SkipISOBuild) {
            $oscdimgFound = $env:OSCDIMG_PATH -and (Test-Path $env:OSCDIMG_PATH)
            if (-not $oscdimgFound) {
                $adkPaths = @(
                    "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
                    "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
                )
                foreach ($p in $adkPaths) { if (Test-Path $p) { $oscdimgFound = $true; break } }
            }
            if (-not $oscdimgFound) {
                $adkScript = Join-Path $infraScriptsDir '0101_Install-WindowsADK.ps1'
                if (Test-Path $adkScript) {
                    Write-Host "  Installing Windows ADK..." -ForegroundColor Yellow
                    try { & $adkScript -ErrorAction Stop } catch { Write-Warning "ADK install failed: $($_.Exception.Message)" }
                }
            }
        }

        # Check OpenTofu
        if (-not $SkipTofuApply -and -not (Get-Command tofu -ErrorAction SilentlyContinue) -and -not (Get-Command terraform -ErrorAction SilentlyContinue)) {
            $tofuScript = Join-Path $infraScriptsDir '0102_Install-OpenTofu.ps1'
            if (Test-Path $tofuScript) {
                Write-Host "  Installing OpenTofu..." -ForegroundColor Yellow
                try { & $tofuScript -IncludeHyperVProvider -ErrorAction Stop } catch { Write-Warning "OpenTofu install failed: $($_.Exception.Message)" }
            }
        }

        # Check Hyper-V
        if (-not $SkipTofuApply) {
            $hvScript = Join-Path $infraScriptsDir '0105_Enable-HyperV.ps1'
            if (Test-Path $hvScript) {
                try {
                    & $hvScript -SkipRebootCheck -ErrorAction Stop
                    if ($LASTEXITCODE -eq 200) {
                        Write-Warning "Hyper-V enabled but reboot required. ISO build will continue."
                        $SkipTofuApply = $true
                        $SkipPostInstall = $true
                    }
                }
                catch { Write-Warning "Hyper-V check failed: $($_.Exception.Message)" }
            }
        }

        $result.Phases['Prerequisites'] = @{ Status = 'InlineCheck' }
    }

    Write-Host ""

    if ($DryRun) {
        Write-Host "[DRY RUN] Pipeline steps:" -ForegroundColor Yellow
        Write-Host "  0. Auto-resolve prerequisites (ADK, OpenTofu, Hyper-V)"
        if (-not $SkipISOBuild) { Write-Host "  1. Build custom ISO from $SourceISO" }
        Write-Host "  2. Generate OpenTofu config for $($NodeName.Count) node(s)"
        if (-not $SkipTofuApply) { Write-Host "  3. tofu init + apply → create Hyper-V VMs" }
        if (-not $SkipPostInstall) { Write-Host "  4. Wait for WinRM ($WaitTimeoutMinutes min timeout)" }
        if (-not $SkipPostInstall) { Write-Host "  5. Post-install: Docker, mesh join, services" }
        $result.OverallStatus = 'DryRun'
        if ($PassThru) { return $result }
        return
    }

    # ═══════════════════════════════════════════
    # Phase 1: Build Custom ISO
    # ═══════════════════════════════════════════
    if (-not $SkipISOBuild) {
        Write-Host "`n━━━ Phase 1: Build Custom ISO ━━━" -ForegroundColor Yellow

        if (-not $SourceISO) {
            throw "SourceISO is required when not using -SkipISOBuild. Provide a stock Windows Server 2025 ISO path."
        }

        $isoScript = Join-Path $scriptsDir '3105_Build-WindowsISO.ps1'
        if (-not (Test-Path $isoScript)) {
            throw "ISO builder script not found: $isoScript"
        }

        $isoArgs = @{
            SourceISO     = $SourceISO
            ComputerName  = $NodeName[0]  # First node name as template
            NodeProfile   = $Profile
            MeshCoreUrl   = $MeshCoreUrl
        }
        if ($AdminPassword) { $isoArgs.AdminPassword = $AdminPassword }
        if ($Force) { $isoArgs.Force = $true }

        try {
            & $isoScript @isoArgs
            # Detect the output ISO
            $outputDir = 'C:\ISOs'  # Default from script
            $ISOPath = Join-Path $outputDir 'AitherOS-Server2025-Core.iso'
            if (-not (Test-Path $ISOPath)) {
                throw "ISO build completed but output not found at $ISOPath"
            }
            $result.CustomISO = $ISOPath
            $result.Phases['ISOBuild'] = @{ Status = 'Success'; Path = $ISOPath }
            Write-Host "  ISO ready: $ISOPath" -ForegroundColor Green
        }
        catch {
            $result.Phases['ISOBuild'] = @{ Status = 'Failed'; Error = $_.Exception.Message }
            $result.OverallStatus = 'Failed'
            throw "ISO build failed: $($_.Exception.Message)"
        }
    }
    else {
        if (-not $ISOPath -or -not (Test-Path $ISOPath)) {
            throw "ISOPath '$ISOPath' not found. Either provide a valid path or remove -SkipISOBuild."
        }
        $result.Phases['ISOBuild'] = @{ Status = 'Skipped'; Path = $ISOPath }
        Write-Host "  Using existing ISO: $ISOPath" -ForegroundColor Gray
    }

    # ═══════════════════════════════════════════
    # Phase 2: Generate OpenTofu Configuration
    # ═══════════════════════════════════════════
    Write-Host "`n━━━ Phase 2: Generate OpenTofu Config ━━━" -ForegroundColor Yellow

    # Ensure infrastructure directory exists
    if (-not (Test-Path $infraDir)) {
        New-Item -Path $infraDir -ItemType Directory -Force | Out-Null
    }

    # Generate terraform.tfvars dynamically
    $nodesDef = $NodeName | ForEach-Object -Begin { $i = 0 } -Process {
        $i++
        @"
  {
    name              = "$_"
    profile           = "$Profile"
    cpu_count         = $CpuCount
    memory_gb         = $MemoryGB
    disk_gb           = $DiskGB
    failover_priority = $($i * 5)
    mesh_role         = "standby"
  },
"@
    }

    $tfvarsContent = @"
# Auto-generated by New-AitherWindowsISO — $(Get-Date -Format 'o')

iso_path = "$($ISOPath -replace '\\','/')"

hyperv_host = "localhost"
hyperv_port = 5985
hyperv_https = false

switch_name = "$SwitchName"
switch_type = "$SwitchType"

vhd_path = "$($VhdPath -replace '\\','/')"

default_cpu_count     = $CpuCount
default_memory_gb     = $MemoryGB
default_memory_min_gb = 2
default_memory_max_gb = $([Math]::Max($MemoryGB * 2, 8))
default_disk_gb       = $DiskGB

nodes = [
$($nodesDef -join "`n")
]
"@

    $tfvarsPath = Join-Path $infraDir 'terraform.tfvars'
    $tfvarsContent | Set-Content $tfvarsPath -Encoding UTF8
    Write-Host "  Generated: $tfvarsPath" -ForegroundColor Green

    $result.Phases['TofuConfig'] = @{ Status = 'Success'; Path = $tfvarsPath }

    if ($SkipTofuApply) {
        Write-Host "  Skipping tofu apply (--SkipTofuApply)" -ForegroundColor Gray
        $result.Phases['TofuApply'] = @{ Status = 'Skipped' }
        $result.OverallStatus = 'ConfigOnly'
        if ($PassThru) { return $result }
        return
    }

    # ═══════════════════════════════════════════
    # Phase 3: OpenTofu Init + Apply
    # ═══════════════════════════════════════════
    Write-Host "`n━━━ Phase 3: OpenTofu Apply ━━━" -ForegroundColor Yellow

    # Check for tofu/terraform
    $tofuCmd = if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' }
               elseif (Get-Command terraform -ErrorAction SilentlyContinue) { 'terraform' }
               else {
                   # Try auto-install as last resort
                   $tofuInstaller = Join-Path $azRoot 'library\automation-scripts\01-infrastructure\0102_Install-OpenTofu.ps1'
                   if (Test-Path $tofuInstaller) {
                       Write-Host "  OpenTofu not found — auto-installing..." -ForegroundColor Yellow
                       & $tofuInstaller -IncludeHyperVProvider -ErrorAction SilentlyContinue
                       # Refresh PATH
                       $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
                       $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
                       $env:PATH = "$machinePath;$userPath"
                   }
                   if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' }
                   elseif (Get-Command terraform -ErrorAction SilentlyContinue) { 'terraform' }
                   else { throw "Neither 'tofu' nor 'terraform' found in PATH after auto-install attempt. Run: .\01-infrastructure\0102_Install-OpenTofu.ps1" }
               }

    Push-Location $infraDir
    try {
        Write-Host "  Running $tofuCmd init..."
        $initOutput = & $tofuCmd init -no-color 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "tofu init failed:`n$initOutput" }
        Write-Host "  Init complete" -ForegroundColor Green

        Write-Host "  Running $tofuCmd plan..."
        $planOutput = & $tofuCmd plan -no-color 2>&1 | Out-String
        Write-Host $planOutput

        $applyArgs = @('apply', '-no-color')
        if ($TofuAutoApprove) { $applyArgs += '-auto-approve' }

        Write-Host "  Running $tofuCmd apply..."
        $applyOutput = & $tofuCmd @applyArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "tofu apply failed:`n$applyOutput" }

        Write-Host "  VMs provisioned!" -ForegroundColor Green
        $result.Phases['TofuApply'] = @{ Status = 'Success'; Output = $applyOutput }
    }
    catch {
        $result.Phases['TofuApply'] = @{ Status = 'Failed'; Error = $_.Exception.Message }
        $result.OverallStatus = 'Failed'
        throw
    }
    finally {
        Pop-Location
    }

    if ($SkipPostInstall) {
        $result.OverallStatus = 'VMsProvisioned'
        Write-Host "`n  VMs created. Skipping post-install (--SkipPostInstall)" -ForegroundColor Gray
        if ($PassThru) { return $result }
        return
    }

    # ═══════════════════════════════════════════
    # Phase 4: Wait for VM Installation
    # ═══════════════════════════════════════════
    Write-Host "`n━━━ Phase 4: Waiting for VMs to Install ━━━" -ForegroundColor Yellow
    Write-Host "  VMs are booting from ISO and installing Windows Server 2025 Core."
    Write-Host "  This typically takes 10-15 minutes. Timeout: $WaitTimeoutMinutes min."

    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    $readyNodes = @{}

    while ((Get-Date) -lt $deadline -and $readyNodes.Count -lt $NodeName.Count) {
        foreach ($node in $NodeName) {
            if ($readyNodes.ContainsKey($node)) { continue }

            # Try to detect the VM's IP via Hyper-V
            try {
                $vmNet = Get-VM -Name $node -ErrorAction SilentlyContinue |
                    Get-VMNetworkAdapter |
                    Where-Object { $_.IPAddresses.Count -gt 0 } |
                    Select-Object -First 1
                $ip = $vmNet.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

                if ($ip) {
                    # Test WinRM
                    $wsmanTest = Test-WSMan -ComputerName $ip -ErrorAction SilentlyContinue
                    if ($wsmanTest) {
                        $readyNodes[$node] = $ip
                        Write-Host "  $node ($ip) — WinRM ready!" -ForegroundColor Green
                    }
                }
            }
            catch {
                # Not ready yet, continue polling
            }
        }

        if ($readyNodes.Count -lt $NodeName.Count) {
            $remaining = $NodeName | Where-Object { -not $readyNodes.ContainsKey($_) }
            $timeLeft = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 1)
            Write-Host "  Waiting... ($($remaining.Count) node(s) pending, ${timeLeft}m remaining)" -ForegroundColor Gray
            Start-Sleep -Seconds 30
        }
    }

    if ($readyNodes.Count -eq 0) {
        Write-Warning "No nodes became available within $WaitTimeoutMinutes minutes."
        Write-Host "  VMs may still be installing. Check Hyper-V Manager." -ForegroundColor Yellow
        Write-Host "  When ready, run: Invoke-AitherNodeDeploy -ComputerName <IP> -Action Deploy -SkipBootstrap"
        $result.Phases['WaitForInstall'] = @{ Status = 'Timeout'; ReadyNodes = @{} }
        $result.OverallStatus = 'PartialTimeout'
        if ($PassThru) { return $result }
        return
    }

    $result.Phases['WaitForInstall'] = @{ Status = 'Success'; ReadyNodes = $readyNodes }

    # ═══════════════════════════════════════════
    # Phase 5: Post-Install Configuration
    # ═══════════════════════════════════════════
    Write-Host "`n━━━ Phase 5: Post-Install Configuration ━━━" -ForegroundColor Yellow

    $postResults = @{}
    foreach ($node in $readyNodes.GetEnumerator()) {
        Write-Host "  Configuring $($node.Key) at $($node.Value)..."
        try {
            # The first-boot script already did WinRM + Docker + mesh join.
            # Use Invoke-AitherNodeDeploy for service deployment.
            if (Get-Command Invoke-AitherNodeDeploy -ErrorAction SilentlyContinue) {
                Invoke-AitherNodeDeploy -ComputerName $node.Value -Action Deploy -SkipBootstrap -PassThru
            }
            else {
                # Fallback: call the deployment script directly
                $deployScript = Join-Path $scriptsDir '3101_Deploy-RemoteNode.ps1'
                if (Test-Path $deployScript) {
                    & $deployScript -ComputerName $node.Value -Profile $Profile
                }
            }
            $postResults[$node.Key] = 'Success'
            Write-Host "  $($node.Key) — configured" -ForegroundColor Green
        }
        catch {
            $postResults[$node.Key] = "Failed: $($_.Exception.Message)"
            Write-Warning "$($node.Key) post-install failed: $($_.Exception.Message)"
        }
    }

    $result.Phases['PostInstall'] = @{ Status = 'Success'; Results = $postResults }

    # ═══════════════════════════════════════════
    # Summary
    # ═══════════════════════════════════════════
    $allSuccess = ($postResults.Values | Where-Object { $_ -ne 'Success' }).Count -eq 0
    $result.OverallStatus = if ($allSuccess) { 'Complete' } else { 'PartialFailure' }

    Write-Host "`n╔════════════════════════════════════════════╗" -ForegroundColor ($allSuccess ? 'Green' : 'Yellow')
    Write-Host "║  Pipeline $($result.OverallStatus)$((' ' * (33 - $result.OverallStatus.Length)))║" -ForegroundColor ($allSuccess ? 'Green' : 'Yellow')
    Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor ($allSuccess ? 'Green' : 'Yellow')

    foreach ($node in $readyNodes.GetEnumerator()) {
        $status = $postResults[$node.Key]
        $icon = if ($status -eq 'Success') { '[OK]' } else { '[!!]' }
        Write-Host "  $icon $($node.Key) → $($node.Value) ($status)"
    }

    $notReady = $NodeName | Where-Object { -not $readyNodes.ContainsKey($_) }
    foreach ($n in $notReady) {
        Write-Host "  [--] $n → not ready (still installing)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Check mesh:  Get-AitherMeshStatus -Action Status" -ForegroundColor Cyan
    Write-Host "  Infra view:  Get-AitherInfraStatus -IncludeReplication -IncludeContainers" -ForegroundColor Cyan
    Write-Host ""

    if ($PassThru) { return $result }
}
