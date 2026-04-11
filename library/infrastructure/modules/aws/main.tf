# =============================================================================
# AitherOS AWS Infrastructure Module
# =============================================================================
# Deploy AitherOS services to AWS using ECS Fargate, EC2, or EKS.
# Supports minimal/demo/full profiles with optional GPU instances.
#
# Usage:
#   cd AitherZero/library/infrastructure/environments/aws
#   tofu init
#   tofu plan -var-file="profiles/demo.tfvars"
#   tofu apply -var-file="profiles/demo.tfvars"
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = local.common_tags
  }
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------
locals {
  common_tags = merge(var.tags, {
    managed_by  = "opentofu"
    environment = var.environment
    project     = "aitheros"
  })

  # Profile-based sizing
  profiles = {
    minimal = {
      ecs_cpu          = 256
      ecs_memory       = 512
      ec2_type         = "t3.medium"
      desired_count    = 1
      enable_gpu       = false
      enable_eks       = false
      enable_rds       = false
      enable_elasticache = false
    }
    demo = {
      ecs_cpu          = 1024
      ecs_memory       = 2048
      ec2_type         = "t3.xlarge"
      desired_count    = 2
      enable_gpu       = false
      enable_eks       = false
      enable_rds       = true
      enable_elasticache = true
    }
    full = {
      ecs_cpu          = 4096
      ecs_memory       = 8192
      ec2_type         = "g5.xlarge"
      desired_count    = 3
      enable_gpu       = true
      enable_eks       = true
      enable_rds       = true
      enable_elasticache = true
    }
  }

  profile = local.profiles[var.deployment_profile]
}

# ---------------------------------------------------------------------------
# Networking — VPC + Subnets
# ---------------------------------------------------------------------------
resource "aws_vpc" "aither" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "aitheros-${var.environment}" }
}

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.aither.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "aitheros-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.aither.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "aitheros-private-${count.index}" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.aither.id
  tags   = { Name = "aitheros-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.aither.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "aitheros-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security Group
# ---------------------------------------------------------------------------
resource "aws_security_group" "aither" {
  name_prefix = "aitheros-"
  vpc_id      = aws_vpc.aither.id

  # Ingress — only allow configured ports
  dynamic "ingress" {
    for_each = var.allowed_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidrs
    }
  }

  # Internal — full mesh between services
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "aitheros-sg" }
}

# ---------------------------------------------------------------------------
# ECS Cluster + Fargate
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "aither" {
  name = "aitheros-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "fargate" {
  cluster_name       = aws_ecs_cluster.aither.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 1
    capacity_provider = "FARGATE"
  }
}

# ---------------------------------------------------------------------------
# ECS Task Definitions — one per AitherOS service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "services" {
  for_each = var.services

  family                   = "aitheros-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = lookup(each.value, "cpu", local.profile.ecs_cpu)
  memory                   = lookup(each.value, "memory", local.profile.ecs_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = each.key
    image = each.value.image
    portMappings = [for p in lookup(each.value, "ports", []) : {
      containerPort = p
      hostPort      = p
      protocol      = "tcp"
    }]
    environment = [for k, v in merge(var.common_env, lookup(each.value, "env", {})) : {
      name  = k
      value = v
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/aitheros-${each.key}"
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
    healthCheck = lookup(each.value, "health_path", null) != null ? {
      command     = ["CMD-SHELL", "curl -f http://localhost:${each.value.ports[0]}${each.value.health_path} || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 60
    } : null
  }])
}

# ---------------------------------------------------------------------------
# ECS Services
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "services" {
  for_each = var.services

  name            = each.key
  cluster         = aws_ecs_cluster.aither.id
  task_definition = aws_ecs_task_definition.services[each.key].arn
  desired_count   = lookup(each.value, "replicas", local.profile.desired_count)
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.aither.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

# ---------------------------------------------------------------------------
# IAM Roles
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution" {
  name = "aitheros-ecs-execution-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "aitheros-ecs-task-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "services" {
  for_each          = var.services
  name              = "/ecs/aitheros-${each.key}"
  retention_in_days = var.log_retention_days
}
