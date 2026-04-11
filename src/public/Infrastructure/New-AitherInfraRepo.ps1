#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Scaffold and initialise a Git-managed Infrastructure-as-Code repository.

.DESCRIPTION
    New-AitherInfraRepo creates a fully-structured OpenTofu IaC repository with:

    - Provider-specific modules (docker-host, aws, azure, gcp, kubernetes, aitheros-node)
    - Per-environment directories (dev, staging, prod) with tfvars
    - CI/CD workflow (GitHub Actions: validate → plan → apply)
    - Git-ops backend config (S3/Azure Blob/local for remote state)
    - Pre-commit hooks (tofu validate, tflint, checkov)
    - README, .gitignore, CODEOWNERS

    The repository integrates with:
    - AitherZero IDI pipeline: receives HCL from ConvertTo-OpenTofuConfig
    - Invoke-AitherInfra: executes plan/apply against workspace directories
    - Genesis /infra/requests: approval workflow for staging/prod
    - Sync-InfraState: pushes state back to repo after apply

    If -RegisterSubmodule is set, the repo is registered in library/infrastructure/
    as a Git submodule and config.psd1 is updated.

.PARAMETER Name
    Repository name. Defaults to 'aitheros-infra'.

.PARAMETER Path
    Directory to create the repository in. Defaults to current directory.

.PARAMETER Provider
    Primary provider for this infra repo: aws, azure, gcp, docker, kubernetes, multi.

.PARAMETER Environments
    Environments to scaffold. Default: dev, staging, prod.

.PARAMETER Backend
    State backend type: local, s3, azurerm, gcs. Default: local.

.PARAMETER BackendConfig
    Hashtable of backend-specific config (bucket, region, key, etc.).

.PARAMETER GitRemote
    Git remote URL to add as origin.

.PARAMETER RegisterSubmodule
    Register the new repo as a submodule under library/infrastructure/.

.PARAMETER IncludeCI
    Generate GitHub Actions workflow. Default: true.

.PARAMETER IncludePreCommit
    Generate pre-commit hook config. Default: true.

.PARAMETER Template
    Scaffold template: Standard (full modules + environments), Minimal (single flat workspace).

.PARAMETER PassThru
    Return the repo manifest object.

.EXAMPLE
    New-AitherInfraRepo -Name 'prod-aws-infra' -Provider aws -Backend s3 `
        -BackendConfig @{ bucket = 'aither-tf-state'; region = 'us-east-1' }

.EXAMPLE
    New-AitherInfraRepo -Provider docker -Template Minimal -Path ./my-docker-infra

.NOTES
    Part of AitherZero Infrastructure pipeline.
    Copyright © 2025-2026 Aitherium Corporation.
#>
function New-AitherInfraRepo {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [string]$Name = 'aitheros-infra',

        [string]$Path = '.',

        [ValidateSet('aws', 'azure', 'gcp', 'docker', 'kubernetes', 'multi')]
        [string]$Provider = 'docker',

        [string[]]$Environments = @('dev', 'staging', 'prod'),

        [ValidateSet('local', 's3', 'azurerm', 'gcs')]
        [string]$Backend = 'local',

        [hashtable]$BackendConfig = @{},

        [string]$GitRemote,

        [switch]$RegisterSubmodule,

        [bool]$IncludeCI = $true,

        [bool]$IncludePreCommit = $true,

        [ValidateSet('Standard', 'Minimal')]
        [string]$Template = 'Standard',

        [switch]$PassThru
    )

    $RepoRoot = Join-Path (Resolve-Path $Path) $Name
    $Created = @()

    Write-Host "`n  🏗️  Scaffolding Infrastructure Repository" -ForegroundColor Cyan
    Write-Host "  Name:     $Name" -ForegroundColor Gray
    Write-Host "  Provider: $Provider" -ForegroundColor Gray
    Write-Host "  Backend:  $Backend" -ForegroundColor Gray
    Write-Host "  Template: $Template" -ForegroundColor Gray
    Write-Host ""

    if (-not $PSCmdlet.ShouldProcess($RepoRoot, "Create infrastructure repository")) {
        return
    }

    # ── 1. Directory structure ────────────────────────────────────────────
    $Dirs = @($RepoRoot)

    if ($Template -eq 'Standard') {
        $Dirs += @(
            (Join-Path $RepoRoot 'modules')
            (Join-Path $RepoRoot 'modules' 'shared')
        )

        # Provider-specific module directories
        $ProviderModules = _Get-ProviderModules -Provider $Provider
        foreach ($mod in $ProviderModules) {
            $Dirs += Join-Path $RepoRoot 'modules' $mod
        }

        # Per-environment directories
        foreach ($env in $Environments) {
            $Dirs += Join-Path $RepoRoot 'environments' $env
        }

        $Dirs += @(
            (Join-Path $RepoRoot 'policies')
            (Join-Path $RepoRoot 'scripts')
            (Join-Path $RepoRoot '.state')
        )

        if ($IncludeCI) {
            $Dirs += Join-Path $RepoRoot '.github' 'workflows'
        }
    }

    foreach ($dir in $Dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $Created += $dir
        }
    }

    # ── 2. Root files ─────────────────────────────────────────────────────
    _Write-RootFiles -RepoRoot $RepoRoot -Name $Name -Provider $Provider -Backend $Backend `
        -BackendConfig $BackendConfig -Template $Template

    # ── 3. Provider modules ───────────────────────────────────────────────
    if ($Template -eq 'Standard') {
        _Write-ProviderModules -RepoRoot $RepoRoot -Provider $Provider

        # Shared module (tags, naming conventions)
        _Write-SharedModule -RepoRoot $RepoRoot

        # Per-environment configs
        foreach ($env in $Environments) {
            _Write-EnvironmentConfig -RepoRoot $RepoRoot -EnvName $env -Provider $Provider `
                -Backend $Backend -BackendConfig $BackendConfig
        }

        # Policies
        _Write-Policies -RepoRoot $RepoRoot
    } else {
        # Minimal: single flat workspace
        _Write-MinimalWorkspace -RepoRoot $RepoRoot -Provider $Provider -Backend $Backend `
            -BackendConfig $BackendConfig
    }

    # ── 4. CI/CD ──────────────────────────────────────────────────────────
    if ($IncludeCI -and $Template -eq 'Standard') {
        _Write-CIWorkflow -RepoRoot $RepoRoot -Provider $Provider -Environments $Environments
    }

    # ── 5. Pre-commit hooks ───────────────────────────────────────────────
    if ($IncludePreCommit) {
        _Write-PreCommitConfig -RepoRoot $RepoRoot
    }

    # ── 6. Git init ───────────────────────────────────────────────────────
    if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
        Push-Location $RepoRoot
        try {
            git init --initial-branch=main 2>&1 | Out-Null
            git add -A 2>&1 | Out-Null
            git commit -m "feat: scaffold $Name infrastructure repository" --allow-empty 2>&1 | Out-Null

            if ($GitRemote) {
                git remote add origin $GitRemote 2>&1 | Out-Null
                Write-Host "  📡 Remote added: $GitRemote" -ForegroundColor Green
            }
        } finally {
            Pop-Location
        }
        Write-Host "  ✅ Git repository initialized" -ForegroundColor Green
    }

    # ── 7. Register as submodule ──────────────────────────────────────────
    if ($RegisterSubmodule) {
        $InfraLibPath = Join-Path $PSScriptRoot '..\..\..\..\library\infrastructure' -Resolve -ErrorAction SilentlyContinue
        if ($InfraLibPath -and (Test-Path $InfraLibPath)) {
            $SubmodulePath = Join-Path $InfraLibPath $Name
            if (-not (Test-Path $SubmodulePath)) {
                if ($GitRemote) {
                    Push-Location (Split-Path $InfraLibPath -Parent | Split-Path -Parent)
                    try {
                        git submodule add $GitRemote "library/infrastructure/$Name" 2>&1 | Out-Null
                    } finally {
                        Pop-Location
                    }
                } else {
                    # Symlink for local repos
                    New-Item -ItemType SymbolicLink -Path $SubmodulePath -Target $RepoRoot -Force | Out-Null
                }
                Write-Host "  📦 Registered under library/infrastructure/$Name" -ForegroundColor Green
            }
        }
    }

    # ── Manifest ──────────────────────────────────────────────────────────
    $Manifest = [PSCustomObject]@{
        name          = $Name
        path          = $RepoRoot
        provider      = $Provider
        template      = $Template
        backend       = $Backend
        environments  = $Environments
        modules       = if ($Template -eq 'Standard') { _Get-ProviderModules -Provider $Provider } else { @('workspace') }
        ci            = $IncludeCI
        pre_commit    = $IncludePreCommit
        git_remote    = $GitRemote
        created_at    = [DateTime]::UtcNow.ToString('o')
        files_created = $Created.Count
    }

    # Save manifest
    $ManifestPath = Join-Path $RepoRoot '.aither-infra.json'
    $Manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $ManifestPath -Encoding UTF8

    Write-Host "`n  ✅ Infrastructure repository '$Name' created at $RepoRoot" -ForegroundColor Green
    Write-Host "  📁 Files: $($Created.Count) directories | Provider: $Provider | Backend: $Backend" -ForegroundColor Gray

    if ($PassThru) { return $Manifest }
}


# ══════════════════════════════════════════════════════════════════════════════
# Internal helpers
# ══════════════════════════════════════════════════════════════════════════════

function _Get-ProviderModules {
    param([string]$Provider)
    switch ($Provider) {
        'aws'        { @('compute', 'networking', 'storage', 'database', 'monitoring') }
        'azure'      { @('compute', 'networking', 'storage', 'database', 'monitoring') }
        'gcp'        { @('compute', 'networking', 'storage', 'database', 'monitoring') }
        'docker'     { @('containers', 'networking', 'volumes') }
        'kubernetes' { @('deployments', 'services', 'storage', 'ingress') }
        'multi'      { @('aws', 'azure', 'gcp', 'shared') }
    }
}

function _Write-RootFiles {
    param($RepoRoot, $Name, $Provider, $Backend, $BackendConfig, $Template)

    # README.md
    @"
# $Name — Infrastructure as Code

> Managed by AitherZero IDI pipeline · OpenTofu · Git-Ops

## Quick start

```bash
# Initialise dev environment
cd environments/dev && tofu init && tofu plan

# Apply (dev auto-approved)
tofu apply -auto-approve

# Plan staging (requires approval via Genesis)
cd ../staging && tofu init && tofu plan
```

## Structure

| Path | Purpose |
|------|---------|
| ``modules/`` | Reusable OpenTofu modules per concern |
| ``environments/`` | Per-env root configs (dev/staging/prod) |
| ``policies/`` | OPA/Sentinel/checkov policies |
| ``scripts/`` | Helper scripts for CI and local dev |
| ``.github/workflows/`` | CI/CD pipeline |

## Provider: ``$Provider``

Backend: ``$Backend``

## AitherZero Integration

- **IDI Pipeline**: ``Invoke-AitherIntent`` → ``ConvertTo-OpenTofuConfig`` → commits here
- **Plan/Apply**: ``Invoke-AitherInfra -WorkspacePath ./environments/<env>``
- **Approval**: Genesis ``/infra/requests`` for staging/prod
- **State Sync**: ``Sync-InfraState`` pushes state back after apply
- **Drift Watch**: ``Invoke-IDIDriftWatch`` monitors for configuration drift
"@ | Set-Content -Path (Join-Path $RepoRoot 'README.md') -Encoding UTF8

    # .gitignore
    @"
# OpenTofu / Terraform
*.tfstate
*.tfstate.backup
*.tfstate.lock.info
.terraform/
.tofu/
*.tfplan
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Secrets — never commit
*.auto.tfvars
secret.tfvars
credentials.tfvars
.env
*.pem
*.key

# AitherZero state cache
.state/
.aither-cache/

# IDE
.idea/
.vscode/
*.swp
*.swo
"@ | Set-Content -Path (Join-Path $RepoRoot '.gitignore') -Encoding UTF8

    # CODEOWNERS
    @"
# Infrastructure CODEOWNERS
# Require review for production changes
environments/prod/ @aitherium/infra-admins
policies/          @aitherium/security
*.tf               @aitherium/infra-team
"@ | Set-Content -Path (Join-Path $RepoRoot 'CODEOWNERS') -Encoding UTF8

    # versions.tf — root version constraints
    $ProviderBlock = switch ($Provider) {
        'aws'   { '    aws = { source = "hashicorp/aws"; version = "~> 5.0" }' }
        'azure' { '    azurerm = { source = "hashicorp/azurerm"; version = "~> 4.0" }' }
        'gcp'   { '    google = { source = "hashicorp/google"; version = "~> 6.0" }' }
        'docker' { '    docker = { source = "kreuzwerker/docker"; version = "~> 3.0" }' }
        'kubernetes' { '    kubernetes = { source = "hashicorp/kubernetes"; version = "~> 2.0" }' }
        'multi' {
            @'
    aws        = { source = "hashicorp/aws";        version = "~> 5.0" }
    azurerm    = { source = "hashicorp/azurerm";     version = "~> 4.0" }
    google     = { source = "hashicorp/google";      version = "~> 6.0" }
'@
        }
    }

    @"
terraform {
  required_version = ">= 1.6"
  required_providers {
$ProviderBlock
  }
}
"@ | Set-Content -Path (Join-Path $RepoRoot 'versions.tf') -Encoding UTF8
}


function _Write-SharedModule {
    param($RepoRoot)

    $SharedDir = Join-Path $RepoRoot 'modules' 'shared'

    # Shared tagging module
    @"
# Shared tagging module — consistent labels across all resources
variable "environment" {
  type    = string
  default = "dev"
}

variable "project" {
  type    = string
  default = "aitheros"
}

variable "managed_by" {
  type    = string
  default = "opentofu"
}

variable "extra_tags" {
  type    = map(string)
  default = {}
}

locals {
  common_tags = merge({
    environment = var.environment
    project     = var.project
    managed_by  = var.managed_by
    created_at  = timestamp()
  }, var.extra_tags)
}

output "tags" {
  value = local.common_tags
}
"@ | Set-Content -Path (Join-Path $SharedDir 'main.tf') -Encoding UTF8
}


function _Write-ProviderModules {
    param($RepoRoot, $Provider)

    $Modules = _Get-ProviderModules -Provider $Provider

    foreach ($mod in $Modules) {
        $ModDir = Join-Path $RepoRoot 'modules' $mod

        # main.tf
        $MainContent = switch ("$Provider/$mod") {
            # ── AWS modules ──
            'aws/compute' {
                @'
# AitherOS Compute Module — ECS Fargate / EC2
variable "services" { type = map(any); default = {} }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "environment" { type = string; default = "dev" }
variable "cluster_name" { type = string; default = "aitheros" }

resource "aws_ecs_cluster" "main" {
  name = "${var.cluster_name}-${var.environment}"
  setting { name = "containerInsights"; value = "enabled" }
}

resource "aws_ecs_task_definition" "service" {
  for_each = var.services
  family                   = "${var.environment}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = lookup(each.value, "cpu", 256)
  memory                   = lookup(each.value, "memory", 512)

  container_definitions = jsonencode([{
    name      = each.key
    image     = each.value.image
    essential = true
    portMappings = [for p in lookup(each.value, "ports", []) : {
      containerPort = p; hostPort = p; protocol = "tcp"
    }]
    environment = [for k, v in merge(lookup(each.value, "env", {}), { AITHER_DOCKER_MODE = "true" }) : {
      name = k; value = v
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options   = { "awslogs-group" = "/aitheros/${var.environment}/${each.key}"; "awslogs-region" = data.aws_region.current.name; "awslogs-stream-prefix" = "ecs" }
    }
  }])
}

resource "aws_ecs_service" "service" {
  for_each        = var.services
  name            = each.key
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service[each.key].arn
  desired_count   = lookup(each.value, "replicas", 1)
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.ecs[each.key].id]
  }
}

resource "aws_security_group" "ecs" {
  for_each = var.services
  name     = "${var.environment}-${each.key}-sg"
  vpc_id   = var.vpc_id

  dynamic "ingress" {
    for_each = lookup(each.value, "ports", [])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/8"]
    }
  }
  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_region" "current" {}

output "cluster_arn" { value = aws_ecs_cluster.main.arn }
output "service_arns" { value = { for k, v in aws_ecs_service.service : k => v.id } }
'@
            }
            'aws/networking' {
                @'
# AitherOS Networking Module — VPC + Subnets
variable "environment" { type = string; default = "dev" }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
variable "azs" { type = list(string); default = ["us-east-1a", "us-east-1b"] }
variable "enable_nat" { type = bool; default = false }

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "aitheros-${var.environment}" }
}

resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "aitheros-${var.environment}-pub-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = length(var.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone = var.azs[count.index]
  tags              = { Name = "aitheros-${var.environment}-prv-${count.index}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "aitheros-${var.environment}-igw" }
}

output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
'@
            }
            'aws/storage' {
                @'
# AitherOS Storage Module — S3 + EFS
variable "environment" { type = string; default = "dev" }
variable "buckets" { type = map(any); default = {} }

resource "aws_s3_bucket" "bucket" {
  for_each = var.buckets
  bucket   = "${var.environment}-${each.key}"
  tags     = { managed_by = "opentofu"; environment = var.environment }
}

resource "aws_s3_bucket_versioning" "bucket" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.bucket[each.key].id
  versioning_configuration { status = lookup(each.value, "versioning", false) ? "Enabled" : "Suspended" }
}

output "bucket_arns" { value = { for k, v in aws_s3_bucket.bucket : k => v.arn } }
'@
            }
            'aws/database' {
                @'
# AitherOS Database Module — RDS / ElastiCache
variable "environment" { type = string; default = "dev" }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "engine" { type = string; default = "postgres" }
variable "instance_class" { type = string; default = "db.t3.medium" }
variable "allocated_storage" { type = number; default = 20 }

resource "aws_db_subnet_group" "main" {
  name       = "aitheros-${var.environment}"
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "main" {
  identifier           = "aitheros-${var.environment}"
  engine               = var.engine
  instance_class       = var.instance_class
  allocated_storage    = var.allocated_storage
  db_name              = "aitheros"
  username             = "aither_admin"
  manage_master_user_password = true
  db_subnet_group_name = aws_db_subnet_group.main.name
  skip_final_snapshot  = var.environment == "dev"
  tags                 = { managed_by = "opentofu"; environment = var.environment }
}

output "db_endpoint" { value = aws_db_instance.main.endpoint }
output "db_arn" { value = aws_db_instance.main.arn }
'@
            }
            'aws/monitoring' {
                @'
# AitherOS Monitoring Module — CloudWatch
variable "environment" { type = string; default = "dev" }
variable "services" { type = list(string); default = [] }
variable "retention_days" { type = number; default = 30 }

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(var.services)
  name              = "/aitheros/${var.environment}/${each.value}"
  retention_in_days = var.retention_days
  tags              = { managed_by = "opentofu"; environment = var.environment }
}

output "log_group_arns" { value = { for k, v in aws_cloudwatch_log_group.service : k => v.arn } }
'@
            }
            # ── Docker modules ──
            'docker/containers' {
                @'
# AitherOS Docker Container Module
variable "containers" { type = map(any); default = {} }
variable "docker_host" { type = string; default = "unix:///var/run/docker.sock" }
variable "project_label" { type = string; default = "aitheros" }

terraform {
  required_providers {
    docker = { source = "kreuzwerker/docker"; version = "~> 3.0" }
  }
}

provider "docker" { host = var.docker_host }

resource "docker_image" "service" {
  for_each     = var.containers
  name         = each.value.image
  keep_locally = true
}

resource "docker_container" "service" {
  for_each = var.containers
  name     = "${var.project_label}-${each.key}"
  image    = docker_image.service[each.key].image_id
  restart  = lookup(each.value, "restart", "unless-stopped")

  dynamic "ports" {
    for_each = lookup(each.value, "ports", [])
    content {
      internal = ports.value.internal
      external = ports.value.external
    }
  }

  env = [for k, v in lookup(each.value, "env", {}) : "${k}=${v}"]

  labels {
    label = "managed_by"; value = "opentofu"
  }
  labels {
    label = "aither.project"; value = var.project_label
  }
}

output "container_ids" { value = { for k, v in docker_container.service : k => v.id } }
'@
            }
            'docker/networking' {
                @'
# AitherOS Docker Networking Module
variable "networks" { type = map(any); default = {} }

terraform {
  required_providers {
    docker = { source = "kreuzwerker/docker"; version = "~> 3.0" }
  }
}

resource "docker_network" "net" {
  for_each = var.networks
  name     = each.key
  driver   = lookup(each.value, "driver", "bridge")
  labels { label = "managed_by"; value = "opentofu" }
}

output "network_ids" { value = { for k, v in docker_network.net : k => v.id } }
'@
            }
            'docker/volumes' {
                @'
# AitherOS Docker Volumes Module
variable "volumes" { type = map(any); default = {} }

terraform {
  required_providers {
    docker = { source = "kreuzwerker/docker"; version = "~> 3.0" }
  }
}

resource "docker_volume" "vol" {
  for_each = var.volumes
  name     = each.key
  labels { label = "managed_by"; value = "opentofu" }
}

output "volume_names" { value = { for k, v in docker_volume.vol : k => v.name } }
'@
            }
            # ── Kubernetes modules ──
            'kubernetes/deployments' {
                @'
# AitherOS K8s Deployment Module
variable "namespace" { type = string; default = "aitheros" }
variable "deployments" { type = map(any); default = {} }

resource "kubernetes_namespace" "ns" {
  metadata { name = var.namespace; labels = { managed_by = "opentofu" } }
}

resource "kubernetes_deployment" "svc" {
  for_each = var.deployments
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.ns.metadata[0].name
    labels    = { app = each.key; managed_by = "opentofu" }
  }
  spec {
    replicas = lookup(each.value, "replicas", 1)
    selector { match_labels = { app = each.key } }
    template {
      metadata { labels = { app = each.key } }
      spec {
        container {
          name  = each.key
          image = each.value.image
          dynamic "port" {
            for_each = lookup(each.value, "ports", [])
            content { container_port = port.value }
          }
          dynamic "env" {
            for_each = lookup(each.value, "env", {})
            content { name = env.key; value = env.value }
          }
          resources {
            requests = { cpu = lookup(each.value, "cpu_request", "100m"); memory = lookup(each.value, "mem_request", "128Mi") }
            limits   = { cpu = lookup(each.value, "cpu_limit", "500m"); memory = lookup(each.value, "mem_limit", "512Mi") }
          }
        }
      }
    }
  }
}

output "deployment_names" { value = keys(kubernetes_deployment.svc) }
'@
            }
            'kubernetes/services' {
                @'
# AitherOS K8s Service Module
variable "namespace" { type = string; default = "aitheros" }
variable "services" { type = map(any); default = {} }

resource "kubernetes_service" "svc" {
  for_each = var.services
  metadata {
    name      = each.key
    namespace = var.namespace
    labels    = { app = each.key; managed_by = "opentofu" }
  }
  spec {
    selector = { app = each.key }
    type     = lookup(each.value, "type", "ClusterIP")
    dynamic "port" {
      for_each = lookup(each.value, "ports", [{ port = 80, target_port = 8080 }])
      content {
        port        = port.value.port
        target_port = port.value.target_port
        protocol    = lookup(port.value, "protocol", "TCP")
      }
    }
  }
}

output "service_endpoints" { value = { for k, v in kubernetes_service.svc : k => v.spec[0].cluster_ip } }
'@
            }
            'kubernetes/storage' {
                @'
# AitherOS K8s Storage Module
variable "namespace" { type = string; default = "aitheros" }
variable "pvcs" { type = map(any); default = {} }

resource "kubernetes_persistent_volume_claim" "pvc" {
  for_each = var.pvcs
  metadata {
    name      = each.key
    namespace = var.namespace
  }
  spec {
    access_modes       = lookup(each.value, "access_modes", ["ReadWriteOnce"])
    storage_class_name = lookup(each.value, "storage_class", "standard")
    resources { requests = { storage = lookup(each.value, "size", "10Gi") } }
  }
}
'@
            }
            'kubernetes/ingress' {
                @'
# AitherOS K8s Ingress Module
variable "namespace" { type = string; default = "aitheros" }
variable "ingresses" { type = map(any); default = {} }

resource "kubernetes_ingress_v1" "ing" {
  for_each = var.ingresses
  metadata {
    name        = each.key
    namespace   = var.namespace
    annotations = lookup(each.value, "annotations", {})
  }
  spec {
    ingress_class_name = lookup(each.value, "class", "nginx")
    dynamic "rule" {
      for_each = lookup(each.value, "rules", [])
      content {
        host = rule.value.host
        http {
          path {
            path      = lookup(rule.value, "path", "/")
            path_type = "Prefix"
            backend {
              service {
                name = rule.value.service
                port { number = rule.value.port }
              }
            }
          }
        }
      }
    }
  }
}
'@
            }
            default {
                @"
# $mod module — extend as needed
# Provider: $Provider
"@
            }
        }

        Set-Content -Path (Join-Path $ModDir 'main.tf') -Value $MainContent -Encoding UTF8

        # Variables file for each module
        @"
# Variables for $mod module
# Auto-generated by New-AitherInfraRepo
"@ | Set-Content -Path (Join-Path $ModDir 'variables.tf') -Encoding UTF8

        # Outputs file
        @"
# Outputs for $mod module
# Auto-generated by New-AitherInfraRepo
"@ | Set-Content -Path (Join-Path $ModDir 'outputs.tf') -Encoding UTF8
    }
}


function _Write-EnvironmentConfig {
    param($RepoRoot, $EnvName, $Provider, $Backend, $BackendConfig)

    $EnvDir = Join-Path $RepoRoot 'environments' $EnvName

    # Backend config
    $BackendBlock = switch ($Backend) {
        'local' {
            @"
  backend "local" {
    path = "../../.state/$EnvName/terraform.tfstate"
  }
"@
        }
        's3' {
            $Bucket = $BackendConfig.bucket ?? 'aither-tf-state'
            $Region = $BackendConfig.region ?? 'us-east-1'
            @"
  backend "s3" {
    bucket         = "$Bucket"
    key            = "$EnvName/terraform.tfstate"
    region         = "$Region"
    encrypt        = true
    dynamodb_table = "aither-tf-locks"
  }
"@
        }
        'azurerm' {
            @"
  backend "azurerm" {
    resource_group_name  = "$($BackendConfig.resource_group ?? 'aitheros-tfstate')"
    storage_account_name = "$($BackendConfig.storage_account ?? 'aitherstate')"
    container_name       = "$($BackendConfig.container ?? 'tfstate')"
    key                  = "$EnvName/terraform.tfstate"
  }
"@
        }
        'gcs' {
            @"
  backend "gcs" {
    bucket = "$($BackendConfig.bucket ?? 'aither-tf-state')"
    prefix = "$EnvName"
  }
"@
        }
    }

    # main.tf for environment
    @"
# =============================================================================
# AitherOS — $($EnvName.ToUpper()) Environment
# =============================================================================
# This is the root configuration for the $EnvName environment.
# Module sources reference ../../modules/<module_name>
# Variables are loaded from terraform.tfvars
# =============================================================================

terraform {
  required_version = ">= 1.6"
$BackendBlock
}

# Load shared tags
module "tags" {
  source      = "../../modules/shared"
  environment = "$EnvName"
  project     = "aitheros"
}

# Add module references below — example:
# module "networking" {
#   source      = "../../modules/networking"
#   environment = "$EnvName"
# }
"@ | Set-Content -Path (Join-Path $EnvDir 'main.tf') -Encoding UTF8

    # terraform.tfvars
    $AutoApprove = if ($EnvName -eq 'dev') { 'true' } else { 'false' }
    @"
# $($EnvName.ToUpper()) environment variables
# Modify these for your environment
environment    = "$EnvName"
auto_approve   = $AutoApprove
"@ | Set-Content -Path (Join-Path $EnvDir 'terraform.tfvars') -Encoding UTF8

    # variables.tf
    @"
variable "environment" {
  type    = string
  default = "$EnvName"
}

variable "auto_approve" {
  type    = bool
  default = $($AutoApprove.ToLower())
}
"@ | Set-Content -Path (Join-Path $EnvDir 'variables.tf') -Encoding UTF8

    # outputs.tf
    @"
# Outputs for $EnvName environment
output "environment" { value = var.environment }
"@ | Set-Content -Path (Join-Path $EnvDir 'outputs.tf') -Encoding UTF8
}


function _Write-MinimalWorkspace {
    param($RepoRoot, $Provider, $Backend, $BackendConfig)

    $BackendLine = switch ($Backend) {
        'local'   { '  backend "local" { path = ".state/terraform.tfstate" }' }
        's3'      { "  backend `"s3`" { bucket = `"$($BackendConfig.bucket ?? 'aither-tf-state')`"; key = `"main/terraform.tfstate`"; region = `"$($BackendConfig.region ?? 'us-east-1')`" }" }
        'azurerm' { "  backend `"azurerm`" { resource_group_name = `"$($BackendConfig.resource_group ?? 'aitheros-tfstate')`"; storage_account_name = `"$($BackendConfig.storage_account ?? 'aitherstate')`"; container_name = `"tfstate`"; key = `"main`" }" }
        'gcs'     { "  backend `"gcs`" { bucket = `"$($BackendConfig.bucket ?? 'aither-tf-state')`"; prefix = `"main`" }" }
    }

    @"
terraform {
  required_version = ">= 1.6"
$BackendLine
}

# Add your resources here
"@ | Set-Content -Path (Join-Path $RepoRoot 'main.tf') -Encoding UTF8

    @"
variable "environment" { type = string; default = "dev" }
"@ | Set-Content -Path (Join-Path $RepoRoot 'variables.tf') -Encoding UTF8
}


function _Write-Policies {
    param($RepoRoot)

    $PoliciesDir = Join-Path $RepoRoot 'policies'

    # Checkov config
    @"
# Checkov — IaC security scanning
framework:
  - terraform
check:
  - CKV_AWS_18   # S3 logging
  - CKV_AWS_19   # S3 encryption
  - CKV_AWS_23   # SG no 0.0.0.0
  - CKV_AWS_145  # RDS encryption
  - CKV_AWS_79   # IMDSv2
skip-check:
  - CKV_AWS_144  # S3 cross-region (optional)
soft-fail: false
"@ | Set-Content -Path (Join-Path $PoliciesDir 'checkov.yaml') -Encoding UTF8

    # Cost guard policy
    @"
# AitherZero Cost Guard — max monthly spend per environment
# Enforced by Invoke-AitherInfraPipeline before apply
limits:
  dev:
    max_monthly_usd: 500
    warn_threshold: 0.8
  staging:
    max_monthly_usd: 2000
    warn_threshold: 0.7
  prod:
    max_monthly_usd: 10000
    warn_threshold: 0.6
    require_approval_above: 5000
"@ | Set-Content -Path (Join-Path $PoliciesDir 'cost-guard.yaml') -Encoding UTF8
}


function _Write-CIWorkflow {
    param($RepoRoot, $Provider, $Environments)

    $WorkflowDir = Join-Path $RepoRoot '.github' 'workflows'

    @"
name: Infrastructure CI/CD

on:
  push:
    branches: [main, staging, develop]
  pull_request:
    branches: [main, staging]

env:
  TOFU_VERSION: '1.8.0'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: `${{ env.TOFU_VERSION }} }
      - name: Validate all environments
        run: |
          for env_dir in environments/*/; do
            echo "::group::Validating `$env_dir"
            cd "`$env_dir"
            tofu init -backend=false
            tofu validate
            cd ../..
            echo "::endgroup::"
          done

  plan:
    needs: validate
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [$($Environments -join ', ')]
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: `${{ env.TOFU_VERSION }} }
      - name: Plan `${{ matrix.environment }}
        working-directory: environments/`${{ matrix.environment }}
        run: |
          tofu init
          tofu plan -no-color -input=false -out=plan.tfplan
      - name: Upload plan
        uses: actions/upload-artifact@v4
        with:
          name: plan-`${{ matrix.environment }}
          path: environments/`${{ matrix.environment }}/plan.tfplan

  apply-dev:
    needs: plan
    if: github.base_ref == 'develop' && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: `${{ env.TOFU_VERSION }} }
      - uses: actions/download-artifact@v4
        with: { name: plan-dev, path: environments/dev }
      - name: Apply dev
        working-directory: environments/dev
        run: |
          tofu init
          tofu apply -auto-approve plan.tfplan

  apply-staging:
    needs: plan
    if: github.base_ref == 'staging'
    runs-on: ubuntu-latest
    environment: staging
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: `${{ env.TOFU_VERSION }} }
      - uses: actions/download-artifact@v4
        with: { name: plan-staging, path: environments/staging }
      - name: Apply staging
        working-directory: environments/staging
        run: |
          tofu init
          tofu apply -auto-approve plan.tfplan

  apply-prod:
    needs: plan
    if: github.base_ref == 'main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@v1
        with: { tofu_version: `${{ env.TOFU_VERSION }} }
      - uses: actions/download-artifact@v4
        with: { name: plan-prod, path: environments/prod }
      - name: Apply production
        working-directory: environments/prod
        run: |
          tofu init
          tofu apply -auto-approve plan.tfplan
"@ | Set-Content -Path (Join-Path $WorkflowDir 'infra-ci.yml') -Encoding UTF8
}


function _Write-PreCommitConfig {
    param($RepoRoot)

    @"
repos:
  - repo: https://github.com/antonbabenko/pre-commit-tf
    rev: v1.92.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_checkov
        args: ['--config-file', 'policies/checkov.yaml']
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
"@ | Set-Content -Path (Join-Path $RepoRoot '.pre-commit-config.yaml') -Encoding UTF8
}

Export-ModuleMember -Function New-AitherInfraRepo
