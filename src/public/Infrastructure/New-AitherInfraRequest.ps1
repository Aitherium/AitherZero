#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Submit an infrastructure deployment request to Genesis for approval.

.DESCRIPTION
    New-AitherInfraRequest creates an infrastructure request in Genesis's approval
    workflow. The request specifies what to deploy (services, provider, environment)
    and enters a pending state until an infrastructure admin approves it.

    Flow:
    1. Developer runs New-AitherInfraRequest → creates pending request
    2. Admin reviews via Get-AitherInfraApproval → approves or rejects
    3. System runs tofu plan + apply automatically
    4. Developer tracks via Invoke-AitherInfra -Action Status

.PARAMETER Name
    Human-readable name for the deployment.

.PARAMETER Provider
    Target infrastructure provider.

.PARAMETER Environment
    Target environment: dev, staging, prod.

.PARAMETER Profile
    Sizing profile: minimal, demo, full.

.PARAMETER Region
    Cloud region (e.g. us-east-1, eastus, us-central1).

.PARAMETER Services
    Array of service specifications as hashtables with keys:
    name, image, ports, env, cpu, memory, replicas, health_path, gpu_enabled.

.PARAMETER Variables
    Additional OpenTofu variables as a hashtable.

.PARAMETER Justification
    Explanation of why this infrastructure is needed (shown to approvers).

.PARAMETER AutoDestroyHours
    Auto-destroy the infrastructure after N hours (cost control).

.PARAMETER Template
    Use a pre-built template instead of specifying services manually.

.PARAMETER GenesisUrl
    Genesis API URL. Defaults to AITHER_GENESIS_URL or http://localhost:8001.

.PARAMETER PassThru
    Return the API response object.

.EXAMPLE
    # Request a single container on Docker
    New-AitherInfraRequest -Name 'my-api' -Provider docker -Services @(
        @{ name = 'api'; image = 'myorg/api:latest'; ports = @(8080); health_path = '/health' }
    )

.EXAMPLE
    # Request AitherOS core stack on AWS
    New-AitherInfraRequest -Name 'prod-stack' -Provider aws -Environment staging -Profile demo `
        -Region 'us-east-1' -Justification 'Staging environment for Q2 release testing' `
        -Template 'aitheros-core-aws'

.EXAMPLE
    # Request with auto-destroy (ephemeral dev environment)
    New-AitherInfraRequest -Name 'feature-test' -Provider docker -AutoDestroyHours 8 `
        -Services @(@{ name = 'test-svc'; image = 'python:3.12'; ports = @(8000) })
#>
function New-AitherInfraRequest {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('docker', 'aws', 'azure', 'gcp', 'hyperv', 'kubernetes')]
        [string]$Provider,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [ValidateSet('minimal', 'demo', 'full')]
        [string]$Profile = 'minimal',

        [string]$Region,

        [hashtable[]]$Services = @(),

        [hashtable]$Variables = @{},

        [string]$Justification = '',

        [int]$AutoDestroyHours,

        [string]$Template,

        [hashtable]$Tags = @{},

        [string]$GenesisUrl,

        [switch]$PassThru
    )

    # ── Resolve Genesis URL ──────────────────────────────────────────────
    $BaseUrl = if ($GenesisUrl) { $GenesisUrl }
    elseif ($env:AITHER_GENESIS_URL) { $env:AITHER_GENESIS_URL }
    else { 'http://localhost:8001' }

    # ── If template specified, fetch it first ────────────────────────────
    if ($Template) {
        Write-Host "📦 Loading template '$Template'..." -ForegroundColor Cyan
        try {
            $templates = Invoke-RestMethod -Uri "$BaseUrl/infra/templates" -Method Get -ErrorAction Stop
            $tmpl = $templates.templates | Where-Object { $_.id -eq $Template }

            if (-not $tmpl) {
                $available = ($templates.templates | ForEach-Object { $_.id }) -join ', '
                Write-Error "Template '$Template' not found. Available: $available"
                return
            }

            # Merge template defaults
            if (-not $Region -and $tmpl.region) { $Region = $tmpl.region }
            if ($Services.Count -eq 0 -and $tmpl.services) {
                $Services = $tmpl.services | ForEach-Object {
                    @{
                        name        = $_.name
                        image       = $_.image
                        ports       = @($_.ports)
                        health_path = $_.health_path
                    }
                }
            }
            if ($tmpl.variables -and $Variables.Count -eq 0) {
                $Variables = $tmpl.variables
            }
            if ($tmpl.auto_destroy_hours -and -not $PSBoundParameters.ContainsKey('AutoDestroyHours')) {
                $AutoDestroyHours = $tmpl.auto_destroy_hours
            }
        } catch {
            Write-Warning "Could not load template from Genesis: $($_.Exception.Message). Proceeding without template."
        }
    }

    # ── Validate services ────────────────────────────────────────────────
    if ($Services.Count -eq 0 -and $Provider -ne 'hyperv') {
        Write-Error "At least one service is required (use -Services or -Template)"
        return
    }

    $ServiceSpecs = $Services | ForEach-Object {
        @{
            name        = $_.name
            image       = $_.image ?? ''
            ports       = @($_.ports ?? @())
            env         = $_.env ?? @{}
            cpu         = $_.cpu
            memory      = $_.memory
            replicas    = $_.replicas ?? 1
            health_path = $_.health_path
            gpu_enabled = [bool]($_.gpu_enabled)
            volumes     = @($_.volumes ?? @())
        }
    }

    # ── Build request body ───────────────────────────────────────────────
    $Body = @{
        name               = $Name
        provider           = $Provider
        environment        = $Environment
        profile            = $Profile
        services           = @($ServiceSpecs)
        variables          = $Variables
        justification      = $Justification
        tags               = $Tags
    }

    if ($Region) { $Body.region = $Region }
    if ($AutoDestroyHours -gt 0) { $Body.auto_destroy_hours = $AutoDestroyHours }

    $JsonBody = $Body | ConvertTo-Json -Depth 10

    # ── Submit request ───────────────────────────────────────────────────
    Write-Host "📤 Submitting infrastructure request to Genesis..." -ForegroundColor Cyan
    Write-Host "   Name:        $Name" -ForegroundColor White
    Write-Host "   Provider:    $Provider" -ForegroundColor White
    Write-Host "   Environment: $Environment" -ForegroundColor White
    Write-Host "   Profile:     $Profile" -ForegroundColor White
    Write-Host "   Services:    $($ServiceSpecs.Count)" -ForegroundColor White

    if ($PSCmdlet.ShouldProcess("Genesis ($BaseUrl)", "Submit infrastructure request '$Name'")) {
        try {
            $Response = Invoke-RestMethod -Uri "$BaseUrl/infra/requests" `
                -Method Post `
                -Body $JsonBody `
                -ContentType 'application/json' `
                -ErrorAction Stop

            $statusColor = if ($Response.status -eq 'approved') { 'Green' }
            elseif ($Response.status -eq 'pending') { 'Yellow' }
            else { 'White' }

            Write-Host ""
            Write-Host "✅ Request submitted successfully" -ForegroundColor Green
            Write-Host "   Request ID: $($Response.request_id)" -ForegroundColor Cyan
            Write-Host "   Status:     $($Response.status)" -ForegroundColor $statusColor
            Write-Host "   Message:    $($Response.message)" -ForegroundColor White
            Write-Host ""

            if ($Response.status -eq 'pending') {
                Write-Host "⏳ Waiting for approval. Track with:" -ForegroundColor Yellow
                Write-Host "   Invoke-AitherInfra -Action Status -RequestId '$($Response.request_id)'" -ForegroundColor DarkGray
            } elseif ($Response.status -eq 'approved') {
                Write-Host "🚀 Auto-approved! Planning has started. Track with:" -ForegroundColor Green
                Write-Host "   Invoke-AitherInfra -Action Status -RequestId '$($Response.request_id)'" -ForegroundColor DarkGray
            }

            if ($PassThru) {
                return $Response
            }

        } catch {
            $errorMsg = $_.Exception.Message
            if ($_.ErrorDetails.Message) {
                try {
                    $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json
                    $errorMsg = $errorBody.detail ?? $errorBody.message ?? $errorMsg
                } catch { }
            }
            Write-Error "Failed to submit request: $errorMsg"
        }
    }
}

Export-ModuleMember -Function New-AitherInfraRequest
