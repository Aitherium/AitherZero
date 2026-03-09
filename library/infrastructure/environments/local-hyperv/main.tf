# AitherOS Local Hyper-V Deployment
#
# Deploy AitherOS nodes as Hyper-V VMs on the local machine using custom ISOs.
#
# Quick start:
#   1. Build the custom ISO:
#      pwsh -File AitherZero/library/automation-scripts/31-remote/3105_Build-WindowsISO.ps1 \
#           -SourceISO 'C:\ISOs\Server2025.iso'
#
#   2. Deploy:
#      cd AitherZero/library/infrastructure/environments/local-hyperv
#      tofu init
#      tofu plan
#      tofu apply
#
#   3. After VM installs (~10-15 min), it auto-joins the mesh.
#      Check: Get-AitherMeshStatus -Action Status

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = ">= 1.2.1"
    }
  }

  # Local state — for single-machine dev. Move to remote backend for production.
  backend "local" {
    path = "terraform.tfstate"
  }
}

# ─────────────────────────────────────────────
# Provider: Local Hyper-V (WinRM to localhost)
# ─────────────────────────────────────────────
provider "hyperv" {
  user        = var.hyperv_user
  password    = var.hyperv_password
  host        = var.hyperv_host
  port        = var.hyperv_port
  https       = var.hyperv_https
  insecure    = var.hyperv_insecure
  use_ntlm    = true
  script_path = "C:/Temp/tofu_%RAND%.cmd"
  timeout     = "60s"
}

# ─────────────────────────────────────────────
# Virtual Switch (create if not exists)
# ─────────────────────────────────────────────
resource "hyperv_network_switch" "aither" {
  name                                    = var.switch_name
  notes                                   = "AitherOS mesh network switch"
  allow_management_os                     = true
  switch_type                             = var.switch_type
  net_adapter_names                       = var.switch_type == "External" ? [var.physical_adapter] : []
  default_flow_minimum_bandwidth_absolute = 0
  default_flow_minimum_bandwidth_weight   = 0
  default_queue_vmmq_enabled              = false
  default_queue_vmmq_queue_pairs          = 16
  default_queue_vrss_enabled              = false
}

# ─────────────────────────────────────────────
# AitherOS Nodes
# ─────────────────────────────────────────────
module "aitheros_nodes" {
  source   = "../../modules/aitheros-node"
  for_each = { for node in var.nodes : node.name => node }

  node_name             = each.value.name
  iso_path              = var.iso_path
  switch_name           = hyperv_network_switch.aither.name

  # Compute — use node-level overrides or defaults
  cpu_count             = lookup(each.value, "cpu_count", var.default_cpu_count)
  memory_startup_bytes  = lookup(each.value, "memory_gb", var.default_memory_gb) * 1073741824
  memory_minimum_bytes  = lookup(each.value, "memory_min_gb", var.default_memory_min_gb) * 1073741824
  memory_maximum_bytes  = lookup(each.value, "memory_max_gb", var.default_memory_max_gb) * 1073741824
  dynamic_memory        = lookup(each.value, "dynamic_memory", true)

  # Storage
  vhd_path              = var.vhd_path
  disk_size_bytes       = lookup(each.value, "disk_gb", var.default_disk_gb) * 1073741824
  enable_data_disk      = lookup(each.value, "data_disk", false)
  data_disk_size_bytes  = lookup(each.value, "data_disk_gb", 200) * 1073741824

  # AitherOS
  node_profile          = lookup(each.value, "profile", "Core")
  failover_priority     = lookup(each.value, "failover_priority", 10)
  mesh_role             = lookup(each.value, "mesh_role", "standby")

  # Features
  nested_virtualization = lookup(each.value, "nested_virt", false)
  secure_boot           = false  # Off for custom ISO
  auto_start            = lookup(each.value, "auto_start", true)
}
