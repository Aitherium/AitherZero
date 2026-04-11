#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Ingest cloud provider OpenAPI/SDK specs — zero abstraction lag.

.DESCRIPTION
    Import-ProviderSpec ingests native OpenAPI specifications and SDK documentation
    directly from cloud providers (AWS, Azure, GCP). Instead of maintaining manual
    abstraction layers per provider (the Terraform/Pulumi model), IDI reads the
    provider's own spec and generates resource type support automatically.

    If a provider has an OpenAPI spec, it's supported. Period.

    This eliminates "abstraction lag" — the months-long wait for a Terraform provider
    to support a new AWS service that launched yesterday. IDI reads the spec directly.

    Spec sources:
    - AWS:   CloudFormation Resource Specification + Boto3 service model
    - Azure: Azure REST API specs (github.com/Azure/azure-rest-api-specs)
    - GCP:   Google Discovery API (discovery.googleapis.com)
    - K8s:   Kubernetes OpenAPI v3 spec from the cluster API server

    The imported spec is cached locally and used by ConvertTo-IntentGraph to validate
    resource types, required properties, and valid configurations — without hardcoding
    any provider-specific knowledge.

.PARAMETER Provider
    Cloud provider to import specs for.

.PARAMETER SpecPath
    Path to a local OpenAPI/spec file. If omitted, fetches from the provider's public spec URL.

.PARAMETER SpecUrl
    Custom URL to fetch the spec from. Overrides the default per-provider URL.

.PARAMETER OutputDir
    Directory to store imported specs. Defaults to ~/.aitherzero/provider-specs.

.PARAMETER ResourceTypes
    Only import specific resource types (e.g., 'AWS::EC2::Instance').
    If omitted, imports all resource types from the spec.

.PARAMETER Force
    Re-import even if a cached spec exists and is not expired.

.PARAMETER CacheTTLDays
    Number of days before a cached spec expires. Default: 7.

.PARAMETER Summary
    Print a summary of imported resource types without storing the full spec.

.EXAMPLE
    # Import AWS resource specs
    Import-ProviderSpec -Provider aws

.EXAMPLE
    # Import from a local spec file
    Import-ProviderSpec -Provider aws -SpecPath ./aws-cfn-spec.json

.EXAMPLE
    # Import only EC2 and RDS types
    Import-ProviderSpec -Provider aws -ResourceTypes @('ec2', 'rds')

.EXAMPLE
    # Import Kubernetes API spec from a running cluster
    Import-ProviderSpec -Provider kubernetes

.EXAMPLE
    # Force refresh of all Azure specs
    Import-ProviderSpec -Provider azure -Force

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    "If the provider has a spec, it's supported."
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Import-ProviderSpec {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('aws', 'azure', 'gcp', 'kubernetes')]
        [string]$Provider,

        [string]$SpecPath,

        [string]$SpecUrl,

        [string]$OutputDir,

        [string[]]$ResourceTypes,

        [switch]$Force,

        [int]$CacheTTLDays = 7,

        [switch]$Summary
    )

    process {
        # ── Resolve output directory ──────────────────────────────────
        if (-not $OutputDir) {
            $OutputDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.aitherzero' 'provider-specs'
        }
        if (-not (Test-Path $OutputDir)) {
            New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
        }

        $SpecFile = Join-Path $OutputDir "$Provider-spec.json"
        $MetaFile = Join-Path $OutputDir "$Provider-spec.meta.json"

        # ── Check cache ───────────────────────────────────────────────
        if (-not $Force -and (Test-Path $MetaFile)) {
            $Meta = Get-Content -Path $MetaFile -Raw | ConvertFrom-Json
            $CacheAge = [DateTime]::UtcNow - [DateTime]::Parse($Meta.imported_at)
            if ($CacheAge.TotalDays -lt $CacheTTLDays) {
                Write-Host "  ✅ Using cached $Provider spec ($([math]::Round($CacheAge.TotalHours, 1))h old, TTL: ${CacheTTLDays}d)" -ForegroundColor Green
                $Spec = Get-Content -Path $SpecFile -Raw | ConvertFrom-Json
                return Format-ProviderSpec -Spec $Spec -Provider $Provider -Meta $Meta -Summary:$Summary
            }
            Write-Verbose "Cache expired ($([math]::Round($CacheAge.TotalDays, 1))d old) — re-importing"
        }

        # ── Fetch or load spec ────────────────────────────────────────
        Write-Host "  📥 Importing $Provider spec..." -ForegroundColor Cyan
        $Timer = [System.Diagnostics.Stopwatch]::StartNew()

        $RawSpec = $null
        if ($SpecPath -and (Test-Path $SpecPath)) {
            $RawSpec = Get-Content -Path $SpecPath -Raw | ConvertFrom-Json
            Write-Verbose "Loaded spec from local file: $SpecPath"
        } else {
            # Provider-specific spec URLs
            $DefaultUrls = @{
                aws        = 'https://d1uauaxba7bl26.cloudfront.net/latest/gzip/CloudFormationResourceSpecification.json'
                azure      = 'https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/common-types/resource-management/v5/types.json'
                gcp        = 'https://discovery.googleapis.com/discovery/v1/apis'
                kubernetes = $null  # Uses kubectl to fetch from cluster
            }

            $FetchUrl = $SpecUrl ?? $DefaultUrls[$Provider]

            switch ($Provider) {
                'kubernetes' {
                    # Fetch OpenAPI spec directly from the cluster
                    try {
                        $RawSpec = (kubectl get --raw /openapi/v3 2>$null) | ConvertFrom-Json
                        Write-Verbose "Fetched K8s OpenAPI spec from cluster API server"
                    } catch {
                        # Fallback: list API resources
                        try {
                            $apiResources = (kubectl api-resources -o wide --no-headers 2>$null) -split "`n"
                            $resources = @()
                            foreach ($line in $apiResources) {
                                $parts = $line -split '\s+' | Where-Object { $_ }
                                if ($parts.Count -ge 4) {
                                    $resources += @{
                                        name       = $parts[0]
                                        apiGroup   = if ($parts.Count -ge 5) { $parts[2] } else { '' }
                                        kind       = if ($parts.Count -ge 5) { $parts[4] } else { $parts[3] }
                                        namespaced = ($parts[1] -eq 'true')
                                        verbs      = @()
                                    }
                                }
                            }
                            $RawSpec = [PSCustomObject]@{ apiResources = $resources }
                        } catch {
                            Write-Warning "Cannot fetch K8s API spec. Ensure kubectl is configured."
                            return $null
                        }
                    }
                }
                default {
                    if ($FetchUrl) {
                        try {
                            $RawSpec = Invoke-RestMethod -Uri $FetchUrl -TimeoutSec 30 -ErrorAction Stop
                            Write-Verbose "Fetched spec from $FetchUrl"
                        } catch {
                            Write-Warning "Failed to fetch $Provider spec from $FetchUrl`: $_"
                            return $null
                        }
                    }
                }
            }
        }

        if (-not $RawSpec) {
            Write-Warning "No spec available for $Provider"
            return $null
        }

        # ── Parse spec into IDI resource type catalog ─────────────────
        $ResourceCatalog = switch ($Provider) {
            'aws' { ConvertFrom-AWSSpec -Spec $RawSpec -ResourceTypes $ResourceTypes }
            'azure' { ConvertFrom-AzureSpec -Spec $RawSpec -ResourceTypes $ResourceTypes }
            'gcp' { ConvertFrom-GCPSpec -Spec $RawSpec -ResourceTypes $ResourceTypes }
            'kubernetes' { ConvertFrom-K8sSpec -Spec $RawSpec -ResourceTypes $ResourceTypes }
        }

        $Timer.Stop()

        # ── Build IDI-compatible spec ─────────────────────────────────
        $IDISpec = [PSCustomObject]@{
            provider       = $Provider
            version        = '1.0'
            resource_types = $ResourceCatalog
            total_types    = $ResourceCatalog.Count
            imported_at    = [DateTime]::UtcNow.ToString('o')
            source         = if ($SpecPath) { 'local-file' } elseif ($Provider -eq 'kubernetes') { 'cluster-api' } else { 'remote-spec' }
            import_duration_ms = $Timer.ElapsedMilliseconds
        }

        # ── Cache ─────────────────────────────────────────────────────
        $IDISpec | ConvertTo-Json -Depth 20 | Set-Content -Path $SpecFile -Encoding UTF8
        @{
            provider    = $Provider
            imported_at = [DateTime]::UtcNow.ToString('o')
            total_types = $ResourceCatalog.Count
            source      = $IDISpec.source
            spec_file   = $SpecFile
        } | ConvertTo-Json | Set-Content -Path $MetaFile -Encoding UTF8

        Write-Host "  ✅ Imported $($ResourceCatalog.Count) resource types for $Provider ($($Timer.ElapsedMilliseconds)ms)" -ForegroundColor Green

        return Format-ProviderSpec -Spec $IDISpec -Provider $Provider -Meta $null -Summary:$Summary
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# AWS CloudFormation Spec → IDI Resource Catalog
# ═══════════════════════════════════════════════════════════════════════════
function ConvertFrom-AWSSpec {
    param([PSCustomObject]$Spec, [string[]]$ResourceTypes)

    $Catalog = @()
    $resourceTypeMap = $Spec.ResourceTypes ?? $Spec.ResourceType ?? @{}

    # Handle the CFN spec format: { ResourceTypes: { "AWS::EC2::Instance": { ... } } }
    $types = if ($resourceTypeMap -is [PSCustomObject]) {
        $resourceTypeMap.PSObject.Properties
    } else { @() }

    foreach ($rt in $types) {
        $cfnType = $rt.Name   # e.g. "AWS::EC2::Instance"
        $rtDef = $rt.Value

        # Filter if specific types requested
        if ($ResourceTypes) {
            $match = $false
            foreach ($filter in $ResourceTypes) {
                if ($cfnType -match $filter) { $match = $true; break }
            }
            if (-not $match) { continue }
        }

        # Convert CFN type to IDI type: "AWS::EC2::Instance" → "ec2:instance"
        $parts = $cfnType -split '::'
        $idiType = if ($parts.Count -ge 3) {
            "$($parts[1].ToLower()):$($parts[2].ToLower())"
        } else { $cfnType.ToLower() }

        # Extract properties
        $props = @()
        if ($rtDef.Properties) {
            foreach ($p in $rtDef.Properties.PSObject.Properties) {
                $props += @{
                    name     = $p.Name
                    type     = $p.Value.PrimitiveType ?? $p.Value.Type ?? 'String'
                    required = $p.Value.Required -eq $true
                }
            }
        }

        $Catalog += [PSCustomObject]@{
            cfn_type    = $cfnType
            idi_type    = $idiType
            service     = $parts[1] ?? 'unknown'
            resource    = $parts[2] ?? 'unknown'
            properties  = $props
            property_count = $props.Count
            required_props = ($props | Where-Object { $_.required }).Count
        }
    }

    return $Catalog
}

# ═══════════════════════════════════════════════════════════════════════════
# Azure Spec → IDI Resource Catalog
# ═══════════════════════════════════════════════════════════════════════════
function ConvertFrom-AzureSpec {
    param([PSCustomObject]$Spec, [string[]]$ResourceTypes)

    $Catalog = @()

    # Azure specs are per-service; common-types gives us the base schema
    # For full support, each service spec would be fetched individually
    $definitions = $Spec.definitions ?? @{}
    if ($definitions -is [PSCustomObject]) {
        foreach ($def in $definitions.PSObject.Properties) {
            $name = $def.Name
            if ($ResourceTypes) {
                $match = $false
                foreach ($filter in $ResourceTypes) {
                    if ($name -match $filter) { $match = $true; break }
                }
                if (-not $match) { continue }
            }

            $props = @()
            if ($def.Value.properties) {
                foreach ($p in $def.Value.properties.PSObject.Properties) {
                    $props += @{ name = $p.Name; type = $p.Value.type ?? 'object'; required = $false }
                }
            }

            $Catalog += [PSCustomObject]@{
                cfn_type    = "azure:$name"
                idi_type    = "azure:$($name.ToLower())"
                service     = ($name -split '/' | Select-Object -First 1)
                resource    = ($name -split '/' | Select-Object -Last 1)
                properties  = $props
                property_count = $props.Count
                required_props = 0
            }
        }
    }

    return $Catalog
}

# ═══════════════════════════════════════════════════════════════════════════
# GCP Discovery API → IDI Resource Catalog
# ═══════════════════════════════════════════════════════════════════════════
function ConvertFrom-GCPSpec {
    param([PSCustomObject]$Spec, [string[]]$ResourceTypes)

    $Catalog = @()

    # GCP Discovery API returns a list of available APIs
    $items = $Spec.items ?? @()
    foreach ($api in $items) {
        $name = $api.name ?? ''
        if ($ResourceTypes) {
            $match = $false
            foreach ($filter in $ResourceTypes) {
                if ($name -match $filter) { $match = $true; break }
            }
            if (-not $match) { continue }
        }

        $Catalog += [PSCustomObject]@{
            cfn_type       = "gcp:$name"
            idi_type       = "gcp:$($name.ToLower())"
            service        = $name
            resource       = $api.title ?? $name
            api_version    = $api.version ?? 'unknown'
            description    = $api.description ?? ''
            discovery_link = $api.discoveryRestUrl ?? ''
            properties     = @()
            property_count = 0
            required_props = 0
        }
    }

    return $Catalog
}

# ═══════════════════════════════════════════════════════════════════════════
# Kubernetes API → IDI Resource Catalog
# ═══════════════════════════════════════════════════════════════════════════
function ConvertFrom-K8sSpec {
    param([PSCustomObject]$Spec, [string[]]$ResourceTypes)

    $Catalog = @()

    $apiResources = $Spec.apiResources ?? @()
    foreach ($res in $apiResources) {
        $name = $res.name ?? ''
        if ($ResourceTypes) {
            $match = $false
            foreach ($filter in $ResourceTypes) {
                if ($name -match $filter -or ($res.kind ?? '') -match $filter) { $match = $true; break }
            }
            if (-not $match) { continue }
        }

        $Catalog += [PSCustomObject]@{
            cfn_type    = "k8s:$($res.kind ?? $name)"
            idi_type    = "k8s:$($name.ToLower())"
            service     = $res.apiGroup ?? 'core'
            resource    = $res.kind ?? $name
            namespaced  = $res.namespaced ?? $true
            properties  = @()
            property_count = 0
            required_props = 0
        }
    }

    return $Catalog
}

# ═══════════════════════════════════════════════════════════════════════════
# Format spec output
# ═══════════════════════════════════════════════════════════════════════════
function Format-ProviderSpec {
    param(
        [PSCustomObject]$Spec,
        [string]$Provider,
        [PSCustomObject]$Meta,
        [switch]$Summary
    )

    if ($Summary) {
        Write-Host "`n  📋 $Provider Resource Type Catalog" -ForegroundColor Cyan
        Write-Host "  ═══════════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host "  Total types: $($Spec.total_types)" -ForegroundColor White
        Write-Host "  Source:      $($Spec.source)" -ForegroundColor Gray
        Write-Host "  Imported:    $($Spec.imported_at)" -ForegroundColor Gray
        Write-Host ""

        # Group by service
        $groups = $Spec.resource_types | Group-Object -Property service | Sort-Object -Property Count -Descending
        foreach ($group in $groups | Select-Object -First 20) {
            Write-Host "  $($group.Name.PadRight(25)) $($group.Count) types" -ForegroundColor DarkGray
        }
        if ($groups.Count -gt 20) {
            Write-Host "  ... and $($groups.Count - 20) more services" -ForegroundColor DarkGray
        }
        Write-Host "  ═══════════════════════════════════════`n" -ForegroundColor DarkCyan
    }

    return $Spec
}

# ═══════════════════════════════════════════════════════════════════════════
# Get-ProviderResourceTypes — query cached specs for resource type validation
# ═══════════════════════════════════════════════════════════════════════════
function Get-ProviderResourceTypes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('aws', 'azure', 'gcp', 'kubernetes')]
        [string]$Provider,

        [string]$Filter,

        [string]$SpecDir
    )

    if (-not $SpecDir) {
        $SpecDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.aitherzero' 'provider-specs'
    }

    $SpecFile = Join-Path $SpecDir "$Provider-spec.json"
    if (-not (Test-Path $SpecFile)) {
        Write-Warning "No cached spec for $Provider. Run: Import-ProviderSpec -Provider $Provider"
        return @()
    }

    $Spec = Get-Content -Path $SpecFile -Raw | ConvertFrom-Json
    $Types = $Spec.resource_types

    if ($Filter) {
        $Types = $Types | Where-Object { $_.idi_type -match $Filter -or $_.cfn_type -match $Filter -or $_.service -match $Filter }
    }

    return $Types
}
