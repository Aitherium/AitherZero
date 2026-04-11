# =============================================================================
# Docker Host Module — Outputs
# =============================================================================

output "container_id" {
  description = "Docker container ID"
  value       = docker_container.service.id
}

output "container_name" {
  description = "Docker container name"
  value       = docker_container.service.name
}

output "container_ip" {
  description = "Container IP address (first network)"
  value       = try(docker_container.service.network_data[0].ip_address, "")
}

output "image_id" {
  description = "Pulled/built image ID"
  value       = docker_image.service.id
}

output "ports" {
  description = "Published port mappings"
  value = [for p in docker_container.service.ports : {
    internal = p.internal
    external = p.external
    protocol = p.protocol
  }]
}

output "network_name" {
  description = "Network the container is attached to"
  value       = var.create_network ? docker_network.service[0].name : ""
}
