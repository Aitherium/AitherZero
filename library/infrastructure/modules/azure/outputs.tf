# =============================================================================
# Azure Module — Outputs
# =============================================================================

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.aither.name
}

output "container_groups" {
  description = "Deployed container group details"
  value = { for k, v in azurerm_container_group.services : k => {
    id         = v.id
    ip_address = v.ip_address
    fqdn       = v.fqdn
  }}
}

output "vnet_id" {
  description = "Virtual network ID"
  value       = azurerm_virtual_network.aither.id
}

output "acr_login_server" {
  description = "ACR login server URL"
  value       = var.create_acr ? azurerm_container_registry.aither[0].login_server : ""
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID"
  value       = azurerm_log_analytics_workspace.aither.id
}
