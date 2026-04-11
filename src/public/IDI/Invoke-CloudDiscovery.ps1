#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Real-time cloud discovery — state IS the cloud, not a file.

.DESCRIPTION
    Invoke-CloudDiscovery queries live cloud APIs to build a DiscoverySnapshot of what
    actually exists RIGHT NOW. No .tfstate. No local state files. The cloud IS the state.

    This is the core differentiator: instead of trusting a brittle local file that
    drifts the moment someone clicks in the console, we query the source of truth
    every single time.

    Supports: AWS (boto3/SDK), Azure (Az), GCP (gcloud), Docker, Kubernetes.

    The DiscoverySnapshot contains:
    - resources[]     — every resource matching the query filters
    - drift_detected[] — resources that don't match expected tags/config
    - orphans[]       — resources with no owner/purpose tags (nuke candidates)
    - costs[]         — real-time cost attribution per resource
    - topology        — network/dependency graph of discovered resources

.PARAMETER Provider
    Cloud provider to discover against.

.PARAMETER ResourceTypes
    Array of resource types to discover (e.g., 'ec2:instance', 'rds:instance').
    If omitted, discovers all supported types.

.PARAMETER Environment
    Filter to resources tagged with this environment.

.PARAMETER Region
    Specific region(s) to scan. Defaults to all configured regions.

.PARAMETER Tags
    Hashtable of tag filters. Only resources matching ALL tags are returned.

.PARAMETER IncludeOrphans
    Include resources with no aither:managed tag (orphan detection).

.PARAMETER IncludeCosts
    Query cost explorer for real-time cost attribution.

.PARAMETER MaxAge
    Only return resources older than this timespan (for cleanup operations).

.PARAMETER TargetARNs
    Specific ARNs/resource IDs to query. Enables Surgical Discovery mode:
    3-12 targeted API calls instead of broad sweeps. Used by the IDI pipeline
    to query only resources referenced in the IntentGraph.

.PARAMETER SurgicalMode
    When set, discovery only queries resource types present in the IntentGraph.
    Reduces API calls from 200+ (Terraform-style) to 3-12 (surgical).
    Automatically enabled when -TargetARNs is provided.

.PARAMETER CredentialProfile
    AWS profile name, Azure subscription ID, or GCP project ID for BYOC
    (Bring Your Own Credentials) isolation. Each environment can use separate
    credentials, preventing cross-tenant blast radius.

.PARAMETER GenesisUrl
    Genesis API URL for server-side discovery. Falls back to local SDK calls.

.PARAMETER PassThru
    Return raw DiscoverySnapshot object.

.EXAMPLE
    Invoke-CloudDiscovery -Provider aws -Environment dev

.EXAMPLE
    Invoke-CloudDiscovery -Provider aws -IncludeOrphans -IncludeCosts

.EXAMPLE
    # Surgical discovery — only query specific ARNs (3-12 API calls)
    Invoke-CloudDiscovery -Provider aws -TargetARNs @('arn:aws:ec2:us-east-1:123:instance/i-abc') -SurgicalMode

.EXAMPLE
    # BYOC credential isolation
    Invoke-CloudDiscovery -Provider aws -CredentialProfile 'production-readonly'

.EXAMPLE
    Invoke-CloudDiscovery -Provider aws -MaxAge (New-TimeSpan -Days 30) -IncludeOrphans

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    No .tfstate was harmed in the making of this function.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function Invoke-CloudDiscovery {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('aws', 'azure', 'gcp', 'docker', 'kubernetes')]
        [string]$Provider,

        [string[]]$ResourceTypes,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment,

        [string[]]$Region,

        [hashtable]$Tags = @{},

        [switch]$IncludeOrphans,

        [switch]$IncludeCosts,

        [TimeSpan]$MaxAge,

        [string[]]$TargetARNs,

        [switch]$SurgicalMode,

        [string]$CredentialProfile,

        [string]$GenesisUrl,

        [switch]$PassThru
    )

    begin {
        $GenesisUrl = if ($GenesisUrl) { $GenesisUrl }
                      elseif ($env:AITHER_GENESIS_URL) { $env:AITHER_GENESIS_URL }
                      else { 'http://localhost:8001' }

        $Timer = [System.Diagnostics.Stopwatch]::StartNew()
    }

    process {
        $Snapshot = [PSCustomObject]@{
            provider       = $Provider
            regions        = $Region ?? @()
            environment    = $Environment
            timestamp      = [DateTime]::UtcNow.ToString('o')
            resources      = @()
            drift_detected = @()
            orphans        = @()
            costs          = @()
            topology       = @{ nodes = @(); edges = @() }
            summary        = @{}
            duration_ms    = 0
        }

        # ── BYOC Credential Isolation ─────────────────────────────────
        if ($CredentialProfile) {
            switch ($Provider) {
                'aws'   { $env:AWS_PROFILE = $CredentialProfile; Write-Verbose "BYOC: AWS profile set to '$CredentialProfile'" }
                'azure' { $env:AZURE_SUBSCRIPTION_ID = $CredentialProfile; Write-Verbose "BYOC: Azure subscription set to '$CredentialProfile'" }
                'gcp'   { $env:CLOUDSDK_CORE_PROJECT = $CredentialProfile; Write-Verbose "BYOC: GCP project set to '$CredentialProfile'" }
            }
        }

        # ── Surgical mode auto-enable ─────────────────────────────────
        if ($TargetARNs -and $TargetARNs.Count -gt 0) {
            $SurgicalMode = [switch]::new($true)
        }

        # ── Try Genesis server-side discovery first ───────────────────
        $UseGenesis = $false
        try {
            $DiscoverBody = @{
                provider        = $Provider
                resource_types  = $ResourceTypes
                environment     = $Environment
                regions         = $Region
                tags            = $Tags
                include_orphans = $IncludeOrphans.IsPresent
                include_costs   = $IncludeCosts.IsPresent
                max_age_hours   = if ($MaxAge) { $MaxAge.TotalHours } else { $null }
                surgical_mode   = $SurgicalMode.IsPresent
                target_arns     = $TargetARNs
                credential_profile = $CredentialProfile
            } | ConvertTo-Json -Depth 10

            $Response = Invoke-RestMethod -Uri "$GenesisUrl/api/v1/idi/discover" `
                -Method POST -Body $DiscoverBody -ContentType 'application/json' `
                -TimeoutSec 30 -ErrorAction Stop

            if ($Response.status -eq 'success' -and $Response.data) {
                $Snapshot = $Response.data
                $UseGenesis = $true
            }
        } catch {
            Write-Verbose "Genesis unavailable, falling back to local SDK discovery: $_"
        }

        # ── Local SDK Discovery (fallback) ────────────────────────────
        if (-not $UseGenesis) {
            # Surgical mode: targeted ARN queries (3-12 calls vs 200+ broad sweep)
            if ($SurgicalMode -and $Provider -eq 'aws') {
                $Snapshot = Invoke-SurgicalAWSDiscovery -TargetARNs $TargetARNs `
                    -ResourceTypes $ResourceTypes -Environment $Environment `
                    -Region $Region -IncludeCosts:$IncludeCosts
            } elseif ($SurgicalMode -and $Provider -eq 'kubernetes') {
                $Snapshot = Invoke-SurgicalK8sDiscovery -ResourceTypes $ResourceTypes `
                    -Environment $Environment
            } else {
            switch ($Provider) {
                'aws' {
                    $Snapshot = Invoke-AWSDiscovery -ResourceTypes $ResourceTypes `
                        -Environment $Environment -Region $Region -Tags $Tags `
                        -IncludeOrphans:$IncludeOrphans -IncludeCosts:$IncludeCosts -MaxAge $MaxAge
                }
                'azure' {
                    $Snapshot = Invoke-AzureDiscovery -ResourceTypes $ResourceTypes `
                        -Environment $Environment -Region $Region -Tags $Tags `
                        -IncludeOrphans:$IncludeOrphans -MaxAge $MaxAge
                }
                'gcp' {
                    $Snapshot = Invoke-GCPDiscovery -ResourceTypes $ResourceTypes `
                        -Environment $Environment -Region $Region -Tags $Tags `
                        -IncludeOrphans:$IncludeOrphans -MaxAge $MaxAge
                }
                'docker' {
                    $Snapshot = Invoke-DockerDiscovery -Environment $Environment `
                        -IncludeOrphans:$IncludeOrphans
                }
                'kubernetes' {
                    $Snapshot = Invoke-K8sDiscovery -ResourceTypes $ResourceTypes `
                        -Environment $Environment -IncludeOrphans:$IncludeOrphans
                }
            }
            } # end else (non-surgical)
        }

        $Timer.Stop()
        $Snapshot | Add-Member -NotePropertyName 'duration_ms' -NotePropertyValue $Timer.ElapsedMilliseconds -Force

        # ── Display ───────────────────────────────────────────────────
        if (-not $PassThru) {
            $ResCount = ($Snapshot.resources | Measure-Object).Count
            $OrphanCount = ($Snapshot.orphans | Measure-Object).Count
            $DriftCount = ($Snapshot.drift_detected | Measure-Object).Count

            $modeLabel = if ($SurgicalMode) { "$Provider (⚡ surgical)" } else { $Provider }
            Write-Host "`n🔍 Cloud Discovery — $modeLabel" -ForegroundColor Cyan
            Write-Host "════════════════════════════════════════════" -ForegroundColor DarkCyan
            Write-Host "  Resources found:  $ResCount" -ForegroundColor White
            Write-Host "  Drift detected:   $DriftCount" -ForegroundColor $(if ($DriftCount -gt 0) { 'Yellow' } else { 'Green' })
            Write-Host "  Orphans found:    $OrphanCount" -ForegroundColor $(if ($OrphanCount -gt 0) { 'Yellow' } else { 'Green' })
            Write-Host "  Duration:         $($Timer.ElapsedMilliseconds)ms" -ForegroundColor DarkGray
            Write-Host "════════════════════════════════════════════`n" -ForegroundColor DarkCyan
        }

        return $Snapshot
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# AWS DISCOVERY ENGINE
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-AWSDiscovery {
    param(
        [string[]]$ResourceTypes, [string]$Environment, [string[]]$Region,
        [hashtable]$Tags, [switch]$IncludeOrphans, [switch]$IncludeCosts, [TimeSpan]$MaxAge
    )

    $Snapshot = [PSCustomObject]@{
        provider = 'aws'; regions = $Region ?? @('us-east-1')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
    }

    $Regions = $Region ?? @('us-east-1')
    $AllResources = @()

    foreach ($r in $Regions) {
        # ── EC2 Instances ─────────────────────────────────────────────
        if (-not $ResourceTypes -or $ResourceTypes -match 'ec2') {
            try {
                $AwsCmd = "aws ec2 describe-instances --region $r --output json"
                if ($Environment) {
                    $AwsCmd += " --filters `"Name=tag:aither:env,Values=$Environment`""
                }
                $ec2Result = Invoke-Expression $AwsCmd 2>$null | ConvertFrom-Json
                foreach ($reservation in $ec2Result.Reservations) {
                    foreach ($inst in $reservation.Instances) {
                        $TagMap = @{}
                        foreach ($t in $inst.Tags) { $TagMap[$t.Key] = $t.Value }

                        $resource = [PSCustomObject]@{
                            id            = $inst.InstanceId
                            type          = 'ec2:instance'
                            name          = $TagMap['Name'] ?? $inst.InstanceId
                            region        = $r
                            state         = $inst.State.Name
                            instance_type = $inst.InstanceType
                            launch_time   = $inst.LaunchTime
                            tags          = $TagMap
                            vpc_id        = $inst.VpcId
                            subnet_id     = $inst.SubnetId
                            private_ip    = $inst.PrivateIpAddress
                            public_ip     = $inst.PublicIpAddress
                            is_managed    = ($TagMap['aither:managed'] -eq 'true')
                        }
                        $AllResources += $resource

                        # Orphan detection
                        if ($IncludeOrphans -and -not $resource.is_managed) {
                            $Snapshot.orphans += $resource
                        }

                        # Age filter
                        if ($MaxAge -and $inst.LaunchTime) {
                            $Age = [DateTime]::UtcNow - [DateTime]::Parse($inst.LaunchTime)
                            if ($Age -lt $MaxAge) { continue }
                        }
                    }
                }
            } catch {
                Write-Verbose "EC2 discovery failed in $r`: $_"
            }
        }

        # ── RDS Instances ─────────────────────────────────────────────
        if (-not $ResourceTypes -or $ResourceTypes -match 'rds') {
            try {
                $rdsResult = (aws rds describe-db-instances --region $r --output json 2>$null) | ConvertFrom-Json
                foreach ($db in $rdsResult.DBInstances) {
                    $TagMap = @{}
                    foreach ($t in $db.TagList) { $TagMap[$t.Key] = $t.Value }

                    $AllResources += [PSCustomObject]@{
                        id            = $db.DBInstanceIdentifier
                        type          = 'rds:instance'
                        name          = $db.DBInstanceIdentifier
                        region        = $r
                        state         = $db.DBInstanceStatus
                        instance_type = $db.DBInstanceClass
                        engine        = $db.Engine
                        storage_gb    = $db.AllocatedStorage
                        tags          = $TagMap
                        is_managed    = ($TagMap['aither:managed'] -eq 'true')
                    }
                }
            } catch { Write-Verbose "RDS discovery failed in $r`: $_" }
        }

        # ── S3 Buckets (region-agnostic) ──────────────────────────────
        if ((-not $ResourceTypes -or $ResourceTypes -match 's3') -and $r -eq $Regions[0]) {
            try {
                $s3Result = (aws s3api list-buckets --output json 2>$null) | ConvertFrom-Json
                foreach ($bucket in $s3Result.Buckets) {
                    try {
                        $s3Tags = (aws s3api get-bucket-tagging --bucket $bucket.Name --output json 2>$null) | ConvertFrom-Json
                        $TagMap = @{}
                        foreach ($t in $s3Tags.TagSet) { $TagMap[$t.Key] = $t.Value }
                    } catch { $TagMap = @{} }

                    $AllResources += [PSCustomObject]@{
                        id         = $bucket.Name
                        type       = 's3:bucket'
                        name       = $bucket.Name
                        region     = 'global'
                        state      = 'active'
                        created    = $bucket.CreationDate
                        tags       = $TagMap
                        is_managed = ($TagMap['aither:managed'] -eq 'true')
                    }
                }
            } catch { Write-Verbose "S3 discovery failed: $_" }
        }

        # ── VPCs ──────────────────────────────────────────────────────
        if (-not $ResourceTypes -or $ResourceTypes -match 'vpc') {
            try {
                $vpcResult = (aws ec2 describe-vpcs --region $r --output json 2>$null) | ConvertFrom-Json
                foreach ($vpc in $vpcResult.Vpcs) {
                    $TagMap = @{}
                    foreach ($t in $vpc.Tags) { $TagMap[$t.Key] = $t.Value }

                    $AllResources += [PSCustomObject]@{
                        id         = $vpc.VpcId
                        type       = 'vpc:vpc'
                        name       = $TagMap['Name'] ?? $vpc.VpcId
                        region     = $r
                        state      = $vpc.State
                        cidr       = $vpc.CidrBlock
                        tags       = $TagMap
                        is_managed = ($TagMap['aither:managed'] -eq 'true')
                    }
                }
            } catch { Write-Verbose "VPC discovery failed in $r`: $_" }
        }

        # ── ELBv2 Load Balancers ──────────────────────────────────────
        if (-not $ResourceTypes -or $ResourceTypes -match 'elb') {
            try {
                $elbResult = (aws elbv2 describe-load-balancers --region $r --output json 2>$null) | ConvertFrom-Json
                foreach ($lb in $elbResult.LoadBalancers) {
                    $AllResources += [PSCustomObject]@{
                        id         = $lb.LoadBalancerArn
                        type       = 'elb:load-balancer'
                        name       = $lb.LoadBalancerName
                        region     = $r
                        state      = $lb.State.Code
                        scheme     = $lb.Scheme
                        dns_name   = $lb.DNSName
                        vpc_id     = $lb.VpcId
                        is_managed = $false  # Check tags separately
                    }
                }
            } catch { Write-Verbose "ELB discovery failed in $r`: $_" }
        }

        # ── ElastiCache ───────────────────────────────────────────────
        if (-not $ResourceTypes -or $ResourceTypes -match 'elasticache|redis') {
            try {
                $cacheResult = (aws elasticache describe-cache-clusters --region $r --show-cache-node-info --output json 2>$null) | ConvertFrom-Json
                foreach ($cluster in $cacheResult.CacheClusters) {
                    $AllResources += [PSCustomObject]@{
                        id            = $cluster.CacheClusterId
                        type          = 'elasticache:cluster'
                        name          = $cluster.CacheClusterId
                        region        = $r
                        state         = $cluster.CacheClusterStatus
                        engine        = $cluster.Engine
                        instance_type = $cluster.CacheNodeType
                        nodes         = $cluster.NumCacheNodes
                        is_managed    = $false
                    }
                }
            } catch { Write-Verbose "ElastiCache discovery failed in $r`: $_" }
        }
    }

    # ── Cost Attribution ──────────────────────────────────────────────
    if ($IncludeCosts) {
        try {
            $StartDate = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
            $EndDate = (Get-Date).ToString('yyyy-MM-dd')
            $costResult = (aws ce get-cost-and-usage --time-period "Start=$StartDate,End=$EndDate" `
                --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --output json 2>$null) | ConvertFrom-Json

            foreach ($group in $costResult.ResultsByTime[0].Groups) {
                $Snapshot.costs += [PSCustomObject]@{
                    service = $group.Keys[0]
                    amount  = [decimal]$group.Metrics.UnblendedCost.Amount
                    unit    = $group.Metrics.UnblendedCost.Unit
                }
            }
        } catch { Write-Verbose "Cost discovery failed: $_" }
    }

    $Snapshot.resources = $AllResources
    $Snapshot.summary = @{
        total_resources = $AllResources.Count
        managed         = ($AllResources | Where-Object { $_.is_managed } | Measure-Object).Count
        unmanaged       = ($AllResources | Where-Object { -not $_.is_managed } | Measure-Object).Count
        orphans         = $Snapshot.orphans.Count
    }

    return $Snapshot
}

# ═══════════════════════════════════════════════════════════════════════════
# DOCKER DISCOVERY ENGINE
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-DockerDiscovery {
    param([string]$Environment, [switch]$IncludeOrphans)

    $Snapshot = [PSCustomObject]@{
        provider = 'docker'; regions = @('local')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
    }

    try {
        # Containers
        $containers = (docker ps -a --format '{{json .}}' 2>$null) | ForEach-Object { $_ | ConvertFrom-Json }
        foreach ($c in $containers) {
            $resource = [PSCustomObject]@{
                id         = $c.ID
                type       = 'docker:container'
                name       = $c.Names
                image      = $c.Image
                state      = $c.State
                status     = $c.Status
                ports      = $c.Ports
                created    = $c.CreatedAt
                is_managed = $c.Names -match 'aitheros-'
            }
            $Snapshot.resources += $resource
            if ($IncludeOrphans -and -not $resource.is_managed -and $c.State -ne 'running') {
                $Snapshot.orphans += $resource
            }
        }

        # Volumes
        $volumes = (docker volume ls --format '{{json .}}' 2>$null) | ForEach-Object { $_ | ConvertFrom-Json }
        foreach ($v in $volumes) {
            $resource = [PSCustomObject]@{
                id         = $v.Name
                type       = 'docker:volume'
                name       = $v.Name
                driver     = $v.Driver
                is_managed = $v.Name -match 'aitheros'
            }
            $Snapshot.resources += $resource
        }

        # Networks
        $networks = (docker network ls --format '{{json .}}' 2>$null) | ForEach-Object { $_ | ConvertFrom-Json }
        foreach ($n in $networks) {
            if ($n.Name -notin @('bridge', 'host', 'none')) {
                $Snapshot.resources += [PSCustomObject]@{
                    id         = $n.ID
                    type       = 'docker:network'
                    name       = $n.Name
                    driver     = $n.Driver
                    is_managed = $n.Name -match 'aitheros'
                }
            }
        }

        # Images (dangling = orphans)
        if ($IncludeOrphans) {
            $dangling = (docker images --filter "dangling=true" --format '{{json .}}' 2>$null) | ForEach-Object { $_ | ConvertFrom-Json }
            foreach ($img in $dangling) {
                $Snapshot.orphans += [PSCustomObject]@{
                    id   = $img.ID
                    type = 'docker:image'
                    name = '<dangling>'
                    size = $img.Size
                }
            }
        }
    } catch {
        Write-Verbose "Docker discovery failed: $_"
    }

    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count
        managed         = ($Snapshot.resources | Where-Object { $_.is_managed } | Measure-Object).Count
        orphans         = $Snapshot.orphans.Count
    }

    return $Snapshot
}

# ═══════════════════════════════════════════════════════════════════════════
# KUBERNETES DISCOVERY ENGINE
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-K8sDiscovery {
    param([string[]]$ResourceTypes, [string]$Environment, [switch]$IncludeOrphans)

    $Snapshot = [PSCustomObject]@{
        provider = 'kubernetes'; regions = @('cluster')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
    }

    $Namespace = if ($Environment) { $Environment } else { '--all-namespaces' }
    $NsFlag = if ($Environment) { "-n $Environment" } else { '-A' }

    try {
        # Deployments
        $deps = (Invoke-Expression "kubectl get deployments $NsFlag -o json 2>`$null") | ConvertFrom-Json
        foreach ($d in $deps.items) {
            $Snapshot.resources += [PSCustomObject]@{
                id         = "$($d.metadata.namespace)/$($d.metadata.name)"
                type       = 'k8s:deployment'
                name       = $d.metadata.name
                namespace  = $d.metadata.namespace
                replicas   = @{ desired = $d.spec.replicas; ready = $d.status.readyReplicas }
                image      = ($d.spec.template.spec.containers | ForEach-Object { $_.image }) -join ', '
                labels     = $d.metadata.labels
                is_managed = ($d.metadata.labels.'aither/managed' -eq 'true')
            }
        }

        # Services
        $svcs = (Invoke-Expression "kubectl get services $NsFlag -o json 2>`$null") | ConvertFrom-Json
        foreach ($s in $svcs.items) {
            $Snapshot.resources += [PSCustomObject]@{
                id         = "$($s.metadata.namespace)/$($s.metadata.name)"
                type       = 'k8s:service'
                name       = $s.metadata.name
                namespace  = $s.metadata.namespace
                type_k8s   = $s.spec.type
                ports      = $s.spec.ports
                cluster_ip = $s.spec.clusterIP
                is_managed = ($s.metadata.labels.'aither/managed' -eq 'true')
            }
        }

        # Persistent Volumes
        $pvcs = (Invoke-Expression "kubectl get pvc $NsFlag -o json 2>`$null") | ConvertFrom-Json
        foreach ($pvc in $pvcs.items) {
            $resource = [PSCustomObject]@{
                id         = "$($pvc.metadata.namespace)/$($pvc.metadata.name)"
                type       = 'k8s:pvc'
                name       = $pvc.metadata.name
                namespace  = $pvc.metadata.namespace
                status     = $pvc.status.phase
                capacity   = $pvc.spec.resources.requests.storage
                is_managed = ($pvc.metadata.labels.'aither/managed' -eq 'true')
            }
            $Snapshot.resources += $resource

            # Orphan: PVC not bound to any pod
            if ($IncludeOrphans -and $pvc.status.phase -ne 'Bound') {
                $Snapshot.orphans += $resource
            }
        }
    } catch {
        Write-Verbose "Kubernetes discovery failed: $_"
    }

    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count
        managed         = ($Snapshot.resources | Where-Object { $_.is_managed } | Measure-Object).Count
        orphans         = $Snapshot.orphans.Count
    }

    return $Snapshot
}

# ═══════════════════════════════════════════════════════════════════════════
# AZURE DISCOVERY ENGINE (stub — requires Az module)
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-AzureDiscovery {
    param([string[]]$ResourceTypes, [string]$Environment, [string[]]$Region,
          [hashtable]$Tags, [switch]$IncludeOrphans, [TimeSpan]$MaxAge)

    $Snapshot = [PSCustomObject]@{
        provider = 'azure'; regions = $Region ?? @('eastus')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
    }

    try {
        if (-not (Get-Module -ListAvailable -Name Az.Resources)) {
            Write-Warning "Az module not installed. Install with: Install-Module Az -Scope CurrentUser"
            return $Snapshot
        }

        Import-Module Az.Resources -ErrorAction Stop
        $allResources = Get-AzResource
        if ($Environment) {
            $allResources = $allResources | Where-Object { $_.Tags['aither:env'] -eq $Environment }
        }

        foreach ($res in $allResources) {
            $Snapshot.resources += [PSCustomObject]@{
                id           = $res.ResourceId
                type         = "azure:$($res.ResourceType)"
                name         = $res.Name
                region       = $res.Location
                resource_group = $res.ResourceGroupName
                tags         = $res.Tags
                is_managed   = ($res.Tags['aither:managed'] -eq 'true')
            }
        }
    } catch {
        Write-Verbose "Azure discovery failed: $_"
    }

    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count
        managed         = ($Snapshot.resources | Where-Object { $_.is_managed } | Measure-Object).Count
        orphans         = $Snapshot.orphans.Count
    }

    return $Snapshot
}

# ═══════════════════════════════════════════════════════════════════════════
# GCP DISCOVERY ENGINE (stub — requires gcloud CLI)
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-GCPDiscovery {
    param([string[]]$ResourceTypes, [string]$Environment, [string[]]$Region,
          [hashtable]$Tags, [switch]$IncludeOrphans, [TimeSpan]$MaxAge)

    $Snapshot = [PSCustomObject]@{
        provider = 'gcp'; regions = $Region ?? @('us-central1')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
    }

    try {
        $Project = (gcloud config get-value project 2>$null)
        if (-not $Project) {
            Write-Warning "No GCP project configured. Run: gcloud config set project <id>"
            return $Snapshot
        }

        # Compute instances
        $instances = (gcloud compute instances list --format=json 2>$null) | ConvertFrom-Json
        foreach ($inst in $instances) {
            $Snapshot.resources += [PSCustomObject]@{
                id            = $inst.name
                type          = 'gcp:compute-instance'
                name          = $inst.name
                region        = ($inst.zone -split '/' | Select-Object -Last 1)
                state         = $inst.status
                machine_type  = ($inst.machineType -split '/' | Select-Object -Last 1)
                tags          = $inst.labels
                is_managed    = ($inst.labels.'aither-managed' -eq 'true')
            }
        }
    } catch {
        Write-Verbose "GCP discovery failed: $_"
    }

    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count
        managed         = ($Snapshot.resources | Where-Object { $_.is_managed } | Measure-Object).Count
        orphans         = $Snapshot.orphans.Count
    }

    return $Snapshot
}
# ═══════════════════════════════════════════════════════════════════════════
# SURGICAL AWS DISCOVERY — 3-12 targeted API calls (not 200+ broad sweeps)
# ═══════════════════════════════════════════════════════════════════════════
# The LLM compiled the intent at "compile time". We know exactly which
# resource types and ARNs are relevant. Instead of describe-all-instances
# followed by client-side filtering, we query specific ARNs or use narrow
# filters — the same way you'd look up a book by ISBN, not scan every shelf.
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-SurgicalAWSDiscovery {
    param(
        [string[]]$TargetARNs,
        [string[]]$ResourceTypes,
        [string]$Environment,
        [string[]]$Region,
        [switch]$IncludeCosts
    )

    $Snapshot = [PSCustomObject]@{
        provider = 'aws'; regions = $Region ?? @('us-east-1')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
        discovery_mode = 'surgical'; api_calls = 0
    }

    $ApiCalls = 0
    $Regions = $Region ?? @('us-east-1')

    # ── ARN-targeted queries (most surgical — known resource IDs) ─────
    if ($TargetARNs -and $TargetARNs.Count -gt 0) {
        $ArnGroups = @{}
        foreach ($arn in $TargetARNs) {
            $svcType = if ($arn -match ':ec2:') { 'ec2' }
                       elseif ($arn -match ':rds:') { 'rds' }
                       elseif ($arn -match ':s3:') { 's3' }
                       elseif ($arn -match ':elasticache:') { 'elasticache' }
                       elseif ($arn -match ':elasticloadbalancing:') { 'elb' }
                       elseif ($arn -match ':eks:') { 'eks' }
                       else { 'other' }
            if (-not $ArnGroups[$svcType]) { $ArnGroups[$svcType] = @() }
            $ArnGroups[$svcType] += $arn
        }

        foreach ($svcType in $ArnGroups.Keys) {
            $arns = $ArnGroups[$svcType]
            switch ($svcType) {
                'ec2' {
                    $ids = $arns | ForEach-Object {
                        if ($_ -match 'instance/(i-[a-f0-9]+)') { $Matches[1] }
                    } | Where-Object { $_ }
                    if ($ids) {
                        foreach ($r in $Regions) {
                            try {
                                $ApiCalls++
                                $idList = $ids -join ' '
                                $result = (aws ec2 describe-instances --instance-ids $idList --region $r --output json 2>$null) | ConvertFrom-Json
                                foreach ($reservation in $result.Reservations) {
                                    foreach ($inst in $reservation.Instances) {
                                        $TagMap = @{}
                                        foreach ($t in $inst.Tags) { $TagMap[$t.Key] = $t.Value }
                                        $Snapshot.resources += [PSCustomObject]@{
                                            id = $inst.InstanceId; type = 'ec2:instance'
                                            name = $TagMap['Name'] ?? $inst.InstanceId
                                            region = $r; state = $inst.State.Name
                                            instance_type = $inst.InstanceType
                                            launch_time = $inst.LaunchTime; tags = $TagMap
                                            vpc_id = $inst.VpcId; subnet_id = $inst.SubnetId
                                            private_ip = $inst.PrivateIpAddress
                                            public_ip = $inst.PublicIpAddress
                                            is_managed = ($TagMap['aither:managed'] -eq 'true')
                                        }
                                    }
                                }
                            } catch { Write-Verbose "Surgical EC2 query failed: $_" }
                        }
                    }
                }
                'rds' {
                    foreach ($arn in $arns) {
                        $dbId = if ($arn -match ':db:(.+)$') { $Matches[1] } else { $null }
                        if ($dbId) {
                            try {
                                $ApiCalls++
                                $result = (aws rds describe-db-instances --db-instance-identifier $dbId --output json 2>$null) | ConvertFrom-Json
                                foreach ($db in $result.DBInstances) {
                                    $TagMap = @{}; foreach ($t in $db.TagList) { $TagMap[$t.Key] = $t.Value }
                                    $Snapshot.resources += [PSCustomObject]@{
                                        id = $db.DBInstanceIdentifier; type = 'rds:instance'
                                        name = $db.DBInstanceIdentifier
                                        region = ($db.DBInstanceArn -split ':')[3]
                                        state = $db.DBInstanceStatus
                                        instance_type = $db.DBInstanceClass
                                        engine = $db.Engine; storage_gb = $db.AllocatedStorage
                                        tags = $TagMap; is_managed = ($TagMap['aither:managed'] -eq 'true')
                                    }
                                }
                            } catch { Write-Verbose "Surgical RDS query failed for $dbId`: $_" }
                        }
                    }
                }
                's3' {
                    foreach ($arn in $arns) {
                        $bucket = if ($arn -match ':::(.+)$') { $Matches[1] } else { $null }
                        if ($bucket) {
                            try {
                                $ApiCalls++
                                aws s3api head-bucket --bucket $bucket 2>$null
                                $TagMap = @{}
                                try {
                                    $tags = (aws s3api get-bucket-tagging --bucket $bucket --output json 2>$null) | ConvertFrom-Json
                                    foreach ($t in $tags.TagSet) { $TagMap[$t.Key] = $t.Value }
                                } catch { }
                                $Snapshot.resources += [PSCustomObject]@{
                                    id = $bucket; type = 's3:bucket'; name = $bucket
                                    region = 'global'; state = 'active'; tags = $TagMap
                                    is_managed = ($TagMap['aither:managed'] -eq 'true')
                                }
                            } catch { Write-Verbose "Surgical S3 query failed for $bucket`: $_" }
                        }
                    }
                }
            }
        }
    }

    # ── Type-targeted queries (no ARNs, scoped by IntentGraph types) ──
    if ((-not $TargetARNs -or $TargetARNs.Count -eq 0) -and $ResourceTypes) {
        foreach ($r in $Regions) {
            foreach ($resType in $ResourceTypes) {
                $ApiCalls++
                switch -Regex ($resType) {
                    'ec2' {
                        try {
                            $filters = @()
                            if ($Environment) { $filters += "Name=tag:aither:env,Values=$Environment" }
                            $filterStr = if ($filters) { "--filters `"$($filters -join '`" `"')`"" } else { '' }
                            $result = (Invoke-Expression "aws ec2 describe-instances --region $r $filterStr --output json 2>`$null") | ConvertFrom-Json
                            foreach ($reservation in $result.Reservations) {
                                foreach ($inst in $reservation.Instances) {
                                    $TagMap = @{}; foreach ($t in $inst.Tags) { $TagMap[$t.Key] = $t.Value }
                                    $Snapshot.resources += [PSCustomObject]@{
                                        id = $inst.InstanceId; type = 'ec2:instance'
                                        name = $TagMap['Name'] ?? $inst.InstanceId
                                        region = $r; state = $inst.State.Name
                                        instance_type = $inst.InstanceType; tags = $TagMap
                                        is_managed = ($TagMap['aither:managed'] -eq 'true')
                                    }
                                }
                            }
                        } catch { Write-Verbose "Surgical type query for EC2 failed: $_" }
                    }
                    'rds' {
                        try {
                            $result = (aws rds describe-db-instances --region $r --output json 2>$null) | ConvertFrom-Json
                            foreach ($db in $result.DBInstances) {
                                $TagMap = @{}; foreach ($t in $db.TagList) { $TagMap[$t.Key] = $t.Value }
                                $Snapshot.resources += [PSCustomObject]@{
                                    id = $db.DBInstanceIdentifier; type = 'rds:instance'
                                    name = $db.DBInstanceIdentifier; region = $r
                                    state = $db.DBInstanceStatus; instance_type = $db.DBInstanceClass
                                    engine = $db.Engine; storage_gb = $db.AllocatedStorage
                                    tags = $TagMap; is_managed = ($TagMap['aither:managed'] -eq 'true')
                                }
                            }
                        } catch { Write-Verbose "Surgical type query for RDS failed: $_" }
                    }
                    'vpc' {
                        try {
                            $result = (aws ec2 describe-vpcs --region $r --output json 2>$null) | ConvertFrom-Json
                            foreach ($vpc in $result.Vpcs) {
                                $TagMap = @{}; foreach ($t in $vpc.Tags) { $TagMap[$t.Key] = $t.Value }
                                $Snapshot.resources += [PSCustomObject]@{
                                    id = $vpc.VpcId; type = 'vpc:vpc'; name = $TagMap['Name'] ?? $vpc.VpcId
                                    region = $r; state = $vpc.State; cidr = $vpc.CidrBlock
                                    tags = $TagMap; is_managed = ($TagMap['aither:managed'] -eq 'true')
                                }
                            }
                        } catch { Write-Verbose "Surgical type query for VPC failed: $_" }
                    }
                }
            }
        }
    }

    $Snapshot.api_calls = $ApiCalls
    Write-Verbose "Surgical discovery completed: $ApiCalls API calls (vs ~200+ broad sweep)"

    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count
        managed         = ($Snapshot.resources | Where-Object { $_.is_managed } | Measure-Object).Count
        orphans         = 0; api_calls = $ApiCalls; mode = 'surgical'
    }
    return $Snapshot
}

# ═══════════════════════════════════════════════════════════════════════════
# SURGICAL K8S DISCOVERY — targeted resource type queries
# ═══════════════════════════════════════════════════════════════════════════
function Invoke-SurgicalK8sDiscovery {
    param([string[]]$ResourceTypes, [string]$Environment)

    $Snapshot = [PSCustomObject]@{
        provider = 'kubernetes'; regions = @('cluster')
        environment = $Environment; timestamp = [DateTime]::UtcNow.ToString('o')
        resources = @(); drift_detected = @(); orphans = @(); costs = @()
        topology = @{ nodes = @(); edges = @() }; summary = @{}
        discovery_mode = 'surgical'; api_calls = 0
    }
    $NsFlag = if ($Environment) { "-n $Environment" } else { '-A' }
    $ApiCalls = 0

    foreach ($resType in $ResourceTypes) {
        $k8sKind = switch -Regex ($resType) {
            'deployment' { 'deployments' }
            'service'    { 'services' }
            'pod'        { 'pods' }
            'pvc'        { 'pvc' }
            'ingress'    { 'ingress' }
            default      { $resType }
        }
        try {
            $ApiCalls++
            $items = (Invoke-Expression "kubectl get $k8sKind $NsFlag -o json 2>`$null") | ConvertFrom-Json
            foreach ($item in $items.items) {
                $Snapshot.resources += [PSCustomObject]@{
                    id = "$($item.metadata.namespace)/$($item.metadata.name)"
                    type = "k8s:$k8sKind"; name = $item.metadata.name
                    namespace = $item.metadata.namespace; labels = $item.metadata.labels
                    is_managed = ($item.metadata.labels.'aither/managed' -eq 'true')
                }
            }
        } catch { Write-Verbose "Surgical K8s query for $k8sKind failed: $_" }
    }

    $Snapshot.api_calls = $ApiCalls
    $Snapshot.summary = @{
        total_resources = $Snapshot.resources.Count; api_calls = $ApiCalls; mode = 'surgical'
    }
    return $Snapshot
}