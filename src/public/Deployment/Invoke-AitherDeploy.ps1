#Requires -Version 7.0

<#
.SYNOPSIS
    Deploy AitherOS with a single command.

.DESCRIPTION
    Public cmdlet that wraps the deploy-aitheros playbook for seamless deployment.
    This is the PowerShell-native way to deploy AitherOS from within a session.

    Equivalent to running:
      ./Deploy-AitherOS.ps1
      Invoke-AitherPlaybook deploy-aitheros

    But as a proper PowerShell cmdlet with pipeline support and
    rich output objects.

.PARAMETER Mode
    Deployment mode: source, pull, or hybrid.

.PARAMETER Profile
    Service profile: minimal, core, full, headless, gpu, agents.

.PARAMETER Environment
    Target environment: development or production.

.PARAMETER SkipModels
    Skip AI model provisioning.

.PARAMETER SkipBuild
    Skip Docker image builds.

.PARAMETER SkipDependencies
    Skip dependency installation.

.PARAMETER Force
    Force clean rebuild.

.PARAMETER DryRun
    Preview without executing.

.PARAMETER PassThru
    Return deployment result object instead of just console output.

.INPUTS
    None

.OUTPUTS
    PSCustomObject — Deployment result with status, duration, service health.

.EXAMPLE
    Invoke-AitherDeploy

.EXAMPLE
    Invoke-AitherDeploy -Profile minimal -SkipModels -PassThru

.EXAMPLE
    Invoke-AitherDeploy -Mode pull -Environment production

.NOTES
    Part of AitherZero module — Deployment category.
#>
function Invoke-AitherDeploy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet("source", "pull", "hybrid")]
        [string]$Mode = "source",

        [ValidateSet("minimal", "core", "full", "headless", "gpu", "agents")]
        [string]$Profile = "core",

        [ValidateSet("development", "production")]
        [string]$Environment = "development",

        [switch]$SkipModels,
        [switch]$SkipBuild,
        [switch]$SkipDependencies,
        [switch]$Force,
        [switch]$DryRun,
        [switch]$PassThru
    )

    begin {
        $startTime = Get-Date
        $projectRoot = $null

        # Find project root
        $searchDir = $PSScriptRoot
        while ($searchDir) {
            if (Test-Path (Join-Path $searchDir "AitherZero" "AitherZero.psd1")) {
                $projectRoot = $searchDir
                break
            }
            $parent = Split-Path $searchDir -Parent
            if ($parent -eq $searchDir) { break }
            $searchDir = $parent
        }

        if (-not $projectRoot -and $env:AITHERZERO_ROOT) {
            $projectRoot = $env:AITHERZERO_ROOT
        }

        if (-not $projectRoot) {
            throw "Cannot locate AitherZero project root. Set `$env:AITHERZERO_ROOT or run from within the project."
        }
    }

    process {
        if (-not $PSCmdlet.ShouldProcess("AitherOS ($Profile profile)", "Deploy")) {
            return
        }

        # ── Try playbook-based deployment ──────────────────────
        $playbookFile = Join-Path $projectRoot "AitherZero" "library" "playbooks" "deploy-aitheros.psd1"

        if ((Test-Path $playbookFile) -and (Get-Command Invoke-AitherPlaybook -ErrorAction SilentlyContinue)) {
            Write-Verbose "Using playbook engine for deployment"

            $vars = @{
                DeployMode      = $Mode
                Profile         = $Profile
                Environment     = $Environment
                InstallDeps     = -not [bool]$SkipDependencies
                BuildImages     = -not [bool]$SkipBuild
                ProvisionModels = -not [bool]$SkipModels
                Force           = [bool]$Force
                NonInteractive  = [bool]($env:CI -eq 'true')
            }

            $result = if ($DryRun) {
                Invoke-AitherPlaybook -Name "deploy-aitheros" -Variables $vars -DryRun
            }
            else {
                Invoke-AitherPlaybook -Name "deploy-aitheros" -Variables $vars
            }

            if ($PassThru) {
                return [PSCustomObject]@{
                    PSTypeName  = 'AitherOS.DeploymentResult'
                    Status      = if ($result.Failed -eq 0) { 'Success' } else { 'PartialFailure' }
                    Mode        = $Mode
                    Profile     = $Profile
                    Environment = $Environment
                    Duration    = (Get-Date) - $startTime
                    Completed   = $result.Completed
                    Failed      = $result.Failed
                    Total       = $result.Total
                    DashboardUrl = 'http://localhost:3000'
                    GenesisUrl  = 'http://localhost:8001'
                    Results     = $result.Results
                }
            }
        }
        else {
            # ── Direct script fallback ─────────────────────────
            Write-Verbose "Falling back to direct script execution"

            $deployScript = Join-Path $projectRoot "AitherZero" "library" "automation-scripts" "30-deploy" "3020_Deploy-OneClick.ps1"

            if (-not (Test-Path $deployScript)) {
                throw "Deploy script not found: $deployScript"
            }

            $params = @{
                Mode             = $Mode
                Profile          = $Profile
                Environment      = $Environment
                SkipDependencies = [bool]$SkipDependencies
                SkipModels       = [bool]$SkipModels
                SkipBuild        = [bool]$SkipBuild
                DryRun           = [bool]$DryRun
                Force            = [bool]$Force
                NonInteractive   = [bool]($env:CI -eq 'true')
            }

            & $deployScript @params

            if ($PassThru) {
                return [PSCustomObject]@{
                    PSTypeName  = 'AitherOS.DeploymentResult'
                    Status      = if ($LASTEXITCODE -eq 0) { 'Success' } else { 'Failed' }
                    Mode        = $Mode
                    Profile     = $Profile
                    Environment = $Environment
                    Duration    = (Get-Date) - $startTime
                    ExitCode    = $LASTEXITCODE
                    DashboardUrl = 'http://localhost:3000'
                    GenesisUrl  = 'http://localhost:8001'
                }
            }
        }
    }
}
