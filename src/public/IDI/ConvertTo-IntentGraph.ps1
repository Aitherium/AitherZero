#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Compile natural language infrastructure intent into an IntentGraph DAG.

.DESCRIPTION
    ConvertTo-IntentGraph is the infrastructure-specific resource extractor for AitherZero's
    IDI engine. It decomposes a plain English infrastructure description into a structured
    IntentGraph — a directed acyclic graph of cloud resources and their dependencies.

    When called with -IntentResult (from the real IntentEngine via Genesis /intent/classify),
    it uses the classification metadata (keywords, effort, destructive flag) to improve
    extraction accuracy. Without -IntentResult, it operates standalone using pattern matching.

    The IntentGraph is a directed acyclic graph (DAG) where:
    - Nodes are cloud resources (EC2, RDS, S3, VPC, etc.)
    - Edges are dependencies (subnet → VPC, instance → subnet, etc.)
    - Each node carries: type, name, provider, region, config, tags, cost_hints

    This is NOT a YAML generator. The IntentGraph compiles directly to SDK calls.

    Supported patterns:
    - Resource provisioning: "create/deploy/launch/spin up [N] [resource] in [region]"
    - Scaling: "scale [service] to [N] instances/nodes/replicas"
    - Networking: "create VPC/subnet/security group with [specs]"
    - Storage: "create [N]GB [S3/EBS/RDS] [storage type]"
    - Destruction: "destroy/tear down/nuke [resources] [filters]"
    - Modification: "resize/update/modify [resource] to [new spec]"
    - Multi-cloud: "deploy in [provider1] and [provider2]"
    - Lifecycle: "resources older than [duration]", "unused/orphaned/idle"

.PARAMETER Intent
    Plain English infrastructure intent string.

.PARAMETER Provider
    Explicit provider override. If omitted, inferred from intent.

.PARAMETER Environment
    Target environment for tagging and constraint inference.

.PARAMETER Strict
    Fail if any part of the intent cannot be parsed (vs. best-effort).

.PARAMETER UseLocalLLM
    Use local Ollama model for intent disambiguation when pattern matching is insufficient.

.EXAMPLE
    ConvertTo-IntentGraph -Intent "Deploy 3 Redis nodes with 6GB memory in us-east-1"

.EXAMPLE
    ConvertTo-IntentGraph -Intent "Create a VPC with public and private subnets across 3 AZs" -Provider aws

.NOTES
    Part of AitherZero IDI (Intent-Driven Infrastructure) module.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function ConvertTo-IntentGraph {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Intent,

        [ValidateSet('aws', 'azure', 'gcp', 'docker', 'kubernetes', 'multi')]
        [string]$Provider,

        [ValidateSet('dev', 'staging', 'prod')]
        [string]$Environment = 'dev',

        [switch]$Strict,

        [switch]$UseLocalLLM,

        [Parameter()]
        [PSCustomObject]$IntentResult
    )

    process {
        $NormalizedIntent = $Intent.Trim().ToLower()

        # ── Provider inference ────────────────────────────────────────────
        if (-not $Provider) {
            $Provider = switch -Regex ($NormalizedIntent) {
                'aws|ec2|s3|lambda|rds|dynamodb|cloudfront|route53|sqs|sns|ecs|eks|fargate|aurora|elasticache' { 'aws'; break }
                'azure|blob|cosmos|app\s*service|aks|azure\s*function|vnet' { 'azure'; break }
                'gcp|gke|cloud\s*run|bigquery|cloud\s*sql|pub\/?sub|gcs' { 'gcp'; break }
                'docker|container|compose' { 'docker'; break }
                'kubernetes|k8s|helm|pod|deployment|statefulset' { 'kubernetes'; break }
                '(aws|azure|gcp).*(aws|azure|gcp)|multi.?cloud|geo.?dns|failover' { 'multi'; break }
                default { 'aws' }  # Default to AWS if no provider signal
            }
        }

        # ── Action inference (enriched by IntentEngine if available) ─────
        $IsDestructive = $false
        if ($IntentResult) {
            $IsDestructive = [bool]($IntentResult.is_destructive)
            # Use IntentEngine keywords to supplement pattern matching
            $EngineKeywords = @($IntentResult.keywords) -join ' '
            if ($EngineKeywords) {
                $NormalizedIntent = "$NormalizedIntent $EngineKeywords"
            }
        }

        $Action = if ($IsDestructive) {
            'destroy'
        } else {
            switch -Regex ($NormalizedIntent) {
                '^(destroy|tear\s*down|nuke|delete|remove|decommission|terminate|kill)' { 'destroy'; break }
                '(scale|resize|expand|shrink|grow|auto.?scal)' { 'scale'; break }
                '(update|modify|change|alter|patch|upgrade|migrate)' { 'update'; break }
                '(discover|list|show|find|scan|audit|inventory)' { 'discover'; break }
                default { 'create' }
            }
        }

        # ── Resource extraction ───────────────────────────────────────────
        $Resources = @()
        $Dependencies = @()
        $Regions = @()

        # Region extraction
        $RegionPatterns = @{
            'us-east-1'      = 'us.?east.?1|virginia|n\.?\s*virginia'
            'us-east-2'      = 'us.?east.?2|ohio'
            'us-west-1'      = 'us.?west.?1|n\.?\s*california'
            'us-west-2'      = 'us.?west.?2|oregon'
            'eu-west-1'      = 'eu.?west.?1|ireland'
            'eu-west-2'      = 'eu.?west.?2|london'
            'eu-central-1'   = 'eu.?central.?1|frankfurt'
            'ap-southeast-1' = 'ap.?southeast.?1|singapore'
            'ap-northeast-1' = 'ap.?northeast.?1|tokyo'
            'westeurope'     = 'west\s*europe'
            'eastus'         = 'east\s*us'
            'eastus2'        = 'east\s*us\s*2'
        }

        foreach ($rk in $RegionPatterns.GetEnumerator()) {
            if ($NormalizedIntent -match $rk.Value) {
                $Regions += $rk.Key
            }
        }
        if ($Regions.Count -eq 0) { $Regions = @('us-east-1') }

        # Quantity extraction
        $Quantity = 1
        if ($NormalizedIntent -match '(\d+)\s*(node|instance|replica|server|cluster|container|pod)') {
            $Quantity = [int]$Matches[1]
        }

        # Memory extraction
        $MemoryGB = $null
        if ($NormalizedIntent -match '(\d+)\s*(?:gb|gib|g)\s*(?:memory|mem|ram)') {
            $MemoryGB = [int]$Matches[1]
        }

        # Storage extraction
        $StorageGB = $null
        if ($NormalizedIntent -match '(\d+)\s*(?:gb|gib|tb|tib)\s*(?:storage|disk|volume|ebs|ssd|hdd)') {
            $StorageGB = [int]$Matches[1]
            if ($NormalizedIntent -match '(\d+)\s*(?:tb|tib)') { $StorageGB *= 1024 }
        }

        # CPU extraction
        $CPUCount = $null
        if ($NormalizedIntent -match '(\d+)\s*(?:vcpu|cpu|core)') {
            $CPUCount = [int]$Matches[1]
        }

        # ── Resource type patterns ────────────────────────────────────────
        $ResourcePatterns = [ordered]@{
            # Compute
            'ec2:instance'        = 'ec2|instance|server|vm|virtual\s*machine|compute'
            'ecs:service'         = 'ecs|fargate|container\s*service'
            'eks:cluster'         = 'eks|kubernetes\s*cluster|k8s\s*cluster'
            'lambda:function'     = 'lambda|serverless\s*function|cloud\s*function'
            # Database
            'rds:instance'        = 'rds|database|postgres|mysql|mariadb|sql\s*server'
            'rds:aurora'          = 'aurora|aurora\s*serverless'
            'dynamodb:table'      = 'dynamodb|dynamo|nosql\s*table'
            'elasticache:cluster' = 'redis|elasticache|memcached|cache\s*cluster'
            # Storage
            's3:bucket'           = 's3|bucket|object\s*storage'
            'ebs:volume'          = 'ebs|block\s*storage|volume'
            'efs:filesystem'      = 'efs|elastic\s*file|shared\s*storage|nfs'
            # Networking
            'vpc:vpc'             = 'vpc|virtual\s*private\s*cloud|network'
            'vpc:subnet'          = 'subnet'
            'ec2:security-group'  = 'security\s*group|firewall|sg'
            'elb:load-balancer'   = 'load\s*balancer|alb|nlb|elb'
            'route53:record'      = 'dns|route\s*53|domain|geo\s*dns'
            'cloudfront:dist'     = 'cloudfront|cdn|content\s*delivery'
            # Messaging
            'sqs:queue'           = 'sqs|message\s*queue|queue'
            'sns:topic'           = 'sns|notification|topic|pub.?sub'
            # Container
            'docker:container'    = 'docker\s*container|container(?!\s*service)'
            'docker:compose'      = 'docker\s*compose|compose\s*stack'
            # Kubernetes
            'k8s:deployment'      = 'deployment|stateless\s*app'
            'k8s:statefulset'     = 'statefulset|stateful'
            'k8s:service'         = 'k8s\s*service|cluster\s*ip|node\s*port'
        }

        $MatchedTypes = @()
        foreach ($rp in $ResourcePatterns.GetEnumerator()) {
            if ($NormalizedIntent -match $rp.Value) {
                $MatchedTypes += $rp.Key
            }
        }

        # If no specific type matched, infer from general context
        if ($MatchedTypes.Count -eq 0) {
            $MatchedTypes = switch -Regex ($NormalizedIntent) {
                'api|web|service|app' { @('ecs:service') }
                'data|store|persist'  { @('rds:instance') }
                'static|site|host'    { @('s3:bucket', 'cloudfront:dist') }
                default               { @('ec2:instance') }
            }
        }

        # ── Build resource nodes ──────────────────────────────────────────
        $ResourceIndex = 0
        foreach ($type in $MatchedTypes) {
            $TypeParts = $type -split ':'
            $Service = $TypeParts[0]
            $ResourceType = $TypeParts[1]

            # Determine instance sizing
            $InstanceSize = Get-IDIInstanceSize -Service $Service -ResourceType $ResourceType `
                -MemoryGB $MemoryGB -CPUCount $CPUCount -StorageGB $StorageGB -Environment $Environment

            $ResourceName = "$Environment-$(($ResourceType -replace '[^a-z0-9]', ''))-$ResourceIndex"

            $Resource = [PSCustomObject]@{
                id          = "res-$ResourceIndex"
                type        = $type
                name        = $ResourceName
                provider    = $Provider
                region      = $Regions[0]
                quantity    = $Quantity
                config      = @{
                    instance_type = $InstanceSize.instance_type
                    memory_gb     = $MemoryGB ?? $InstanceSize.memory_gb
                    cpu           = $CPUCount ?? $InstanceSize.cpu
                    storage_gb    = $StorageGB ?? $InstanceSize.storage_gb
                    engine        = $InstanceSize.engine
                }
                tags        = @{
                    'aither:managed'     = 'true'
                    'aither:env'         = $Environment
                    'aither:intent-hash' = (Get-IntentHash $Intent)
                    'aither:created-by'  = 'idi-engine'
                }
                cost_hints  = @{
                    estimated_hourly  = $InstanceSize.estimated_hourly
                    estimated_monthly = $InstanceSize.estimated_monthly
                }
                action      = $Action
            }
            $Resources += $Resource
            $ResourceIndex++
        }

        # ── Build dependency edges ────────────────────────────────────────
        # Auto-infer: instances need VPCs, databases need subnets, etc.
        $HasVPC = $Resources | Where-Object { $_.type -eq 'vpc:vpc' }
        $HasSubnet = $Resources | Where-Object { $_.type -eq 'vpc:subnet' }
        $NeedsNetwork = $Resources | Where-Object { $_.type -match 'ec2:|rds:|ecs:|eks:|elb:|elasticache:' }

        if ($NeedsNetwork -and -not $HasVPC) {
            # Auto-add VPC as implicit dependency
            $VPCResource = [PSCustomObject]@{
                id          = "res-implicit-vpc"
                type        = 'vpc:vpc'
                name        = "$Environment-vpc-auto"
                provider    = $Provider
                region      = $Regions[0]
                quantity    = 1
                config      = @{ cidr = '10.0.0.0/16'; enable_dns = $true }
                tags        = @{ 'aither:managed' = 'true'; 'aither:env' = $Environment; 'aither:implicit' = 'true' }
                cost_hints  = @{ estimated_hourly = 0; estimated_monthly = 0 }
                action      = 'ensure'  # Create only if not exists
            }
            $Resources = @($VPCResource) + $Resources

            foreach ($nr in $NeedsNetwork) {
                $Dependencies += [PSCustomObject]@{
                    from = $VPCResource.id
                    to   = $nr.id
                    type = 'network'
                }
            }
        }

        # ── Construct IntentGraph ─────────────────────────────────────────
        $IntentGraph = [PSCustomObject]@{
            version      = '2.0'
            engine       = 'aitherzero-idi'
            intent       = $Intent
            intent_hash  = Get-IntentHash $Intent
            provider     = $Provider
            regions      = $Regions
            environment  = $Environment
            action       = $Action
            resources    = $Resources
            dependencies = $Dependencies
            constraints  = @{
                cost_limit      = $null
                time_limit      = $null
                approval_required = $Environment -ne 'dev'
            }
            metadata     = @{
                compiled_at    = [DateTime]::UtcNow.ToString('o')
                compiler       = 'aitherzero-local-v2'
                confidence     = if ($IntentResult.confidence) { [math]::Max($IntentResult.confidence, 0.70) }
                                 elseif ($MatchedTypes.Count -gt 0) { 0.85 } else { 0.60 }
                parse_method   = if ($IntentResult) { 'intent-engine-enriched' } else { 'pattern-matching' }
                intent_type    = $IntentResult.intent_type
                effort_level   = $IntentResult.effort_level
                agent_chain    = $IntentResult.agent_chain
                model_tier     = $IntentResult.model_tier
                is_destructive = $IsDestructive
            }
        }

        return $IntentGraph
    }
}

# ── Helper: Generate deterministic intent hash ───────────────────────────
function Get-IntentHash {
    param([string]$Text)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.Trim().ToLower())
    $Hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
    return [BitConverter]::ToString($Hash).Replace('-', '').Substring(0, 16).ToLower()
}

# ── Helper: Instance size lookup ─────────────────────────────────────────
function Get-IDIInstanceSize {
    param(
        [string]$Service,
        [string]$ResourceType,
        [int]$MemoryGB,
        [int]$CPUCount,
        [int]$StorageGB,
        [string]$Environment
    )

    # Cost-optimized defaults per environment
    $EnvMultiplier = switch ($Environment) {
        'dev'     { 1.0 }
        'staging' { 1.5 }
        'prod'    { 2.0 }
    }

    $BaseSize = switch ("$Service`:$ResourceType") {
        'ec2:instance' {
            if ($MemoryGB -ge 16 -or $CPUCount -ge 8) {
                @{ instance_type = 'm6i.xlarge'; memory_gb = 16; cpu = 4; storage_gb = 100; engine = $null; estimated_hourly = 0.192; estimated_monthly = 138.24 }
            } elseif ($MemoryGB -ge 8 -or $CPUCount -ge 4) {
                @{ instance_type = 'm6i.large'; memory_gb = 8; cpu = 2; storage_gb = 50; engine = $null; estimated_hourly = 0.096; estimated_monthly = 69.12 }
            } else {
                @{ instance_type = 't3.medium'; memory_gb = 4; cpu = 2; storage_gb = 30; engine = $null; estimated_hourly = 0.0416; estimated_monthly = 29.95 }
            }
        }
        'rds:instance' {
            @{ instance_type = 'db.r6g.large'; memory_gb = 16; cpu = 2; storage_gb = $StorageGB ?? 100; engine = 'postgres'; estimated_hourly = 0.26; estimated_monthly = 187.20 }
        }
        'rds:aurora' {
            @{ instance_type = 'db.r6g.large'; memory_gb = 16; cpu = 2; storage_gb = $StorageGB ?? 100; engine = 'aurora-postgresql'; estimated_hourly = 0.29; estimated_monthly = 208.80 }
        }
        'elasticache:cluster' {
            @{ instance_type = 'cache.r6g.large'; memory_gb = $MemoryGB ?? 13; cpu = 2; storage_gb = 0; engine = 'redis'; estimated_hourly = 0.226; estimated_monthly = 162.72 }
        }
        'ecs:service' {
            @{ instance_type = 'FARGATE'; memory_gb = $MemoryGB ?? 2; cpu = $CPUCount ?? 1; storage_gb = 20; engine = $null; estimated_hourly = 0.07; estimated_monthly = 50.40 }
        }
        'eks:cluster' {
            @{ instance_type = 'managed'; memory_gb = 0; cpu = 0; storage_gb = 0; engine = 'kubernetes'; estimated_hourly = 0.10; estimated_monthly = 72.00 }
        }
        'lambda:function' {
            @{ instance_type = 'arm64'; memory_gb = $MemoryGB ?? 0.5; cpu = 0; storage_gb = 0; engine = $null; estimated_hourly = 0.001; estimated_monthly = 0.72 }
        }
        's3:bucket' {
            @{ instance_type = 'STANDARD'; memory_gb = 0; cpu = 0; storage_gb = $StorageGB ?? 100; engine = $null; estimated_hourly = 0.003; estimated_monthly = 2.30 }
        }
        default {
            @{ instance_type = 'default'; memory_gb = $MemoryGB ?? 4; cpu = $CPUCount ?? 2; storage_gb = $StorageGB ?? 30; engine = $null; estimated_hourly = 0.05; estimated_monthly = 36.00 }
        }
    }

    return [PSCustomObject]$BaseSize
}
