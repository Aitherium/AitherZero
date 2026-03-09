# AitherOS Local Hyper-V — Outputs

output "nodes" {
  value = {
    for name, node in module.aitheros_nodes : name => {
      vm_name           = node.vm_name
      system_vhd        = node.system_vhd_path
      data_vhd          = node.data_vhd_path
      profile           = node.node_profile
      failover_priority = node.failover_priority
      mesh_role         = node.mesh_role
    }
  }
  description = "Provisioned AitherOS nodes"
}

output "switch_name" {
  value       = hyperv_network_switch.aither.name
  description = "The virtual switch name all nodes are attached to"
}

output "post_deploy_instructions" {
  value = <<-EOT
    Nodes are booting from the custom ISO. Estimated install time: 10-15 minutes.

    Next steps:
      1. Wait for VMs to install and reboot (watch Hyper-V Manager)
      2. First-boot script will auto-configure WinRM + Docker + mesh join
      3. Check mesh status:  Get-AitherMeshStatus -Action Status
      4. Or use the MCP tool: infrastructure_manage { action: "mesh", mesh_action: "Status" }
      5. Start services:     Invoke-AitherNodeDeploy -ComputerName <IP> -Action Deploy -SkipBootstrap
  EOT
}
