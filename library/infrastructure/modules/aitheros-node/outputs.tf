# AitherOS Node — Outputs

output "vm_name" {
  value       = hyperv_machine_instance.node.name
  description = "The name of the created VM"
}

output "vm_id" {
  value       = hyperv_machine_instance.node.id
  description = "Hyper-V VM resource ID"
}

output "system_vhd_path" {
  value       = hyperv_vhd.system.path
  description = "Path to the system VHD"
}

output "data_vhd_path" {
  value       = var.enable_data_disk ? hyperv_vhd.data[0].path : null
  description = "Path to the data VHD (null if not enabled)"
}

output "node_profile" {
  value       = var.node_profile
  description = "AitherOS deployment profile assigned to this node"
}

output "failover_priority" {
  value       = var.failover_priority
  description = "Mesh failover priority"
}

output "mesh_role" {
  value       = var.mesh_role
  description = "Initial mesh role"
}
