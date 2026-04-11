# =============================================================================
# AWS Module — Outputs
# =============================================================================

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.aither.id
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.aither.name
}

output "service_arns" {
  description = "ARNs of deployed ECS services"
  value       = { for k, v in aws_ecs_service.services : k => v.id }
}

output "security_group_id" {
  description = "Security group ID for the AitherOS services"
  value       = aws_security_group.aither.id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "public_subnets" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}
