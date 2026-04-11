# =============================================================================
# AitherOS Azure Infrastructure Module
# =============================================================================
# Deploy AitherOS services to Azure using Container Instances, AKS, or VMs.
# Supports minimal/demo/full profiles with optional GPU nodes.
#
# Usage:
#   cd AitherZero/library/infrastructure/environments/azure
#   tofu init
#   tofu plan -var-file="profiles/demo.tfvars"
#   tofu apply -var-file="profiles/demo.tfvars"
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
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

  profiles = {
    minimal = {
      aci_cpu    = 1
      aci_memory = 1.5
      vm_size    = "Standard_B2s"
      aks_nodes  = 0
    }
    demo = {
      aci_cpu    = 2
      aci_memory = 4
      vm_size    = "Standard_D4s_v3"
      aks_nodes  = 0
    }
    full = {
      aci_cpu    = 4
      aci_memory = 8
      vm_size    = "Standard_NC6s_v3"
      aks_nodes  = 3
    }
  }

  profile = local.profiles[var.deployment_profile]
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "aither" {
  name     = "rg-aitheros-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Virtual Network
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "aither" {
  name                = "vnet-aitheros-${var.environment}"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.aither.location
  resource_group_name = azurerm_resource_group.aither.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "services" {
  name                 = "snet-services"
  resource_group_name  = azurerm_resource_group.aither.name
  virtual_network_name = azurerm_virtual_network.aither.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 1)]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# Container Registry (ACR) — for private images
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "aither" {
  count               = var.create_acr ? 1 : 0
  name                = replace("aitheros${var.environment}", "-", "")
  resource_group_name = azurerm_resource_group.aither.name
  location            = azurerm_resource_group.aither.location
  sku                 = "Standard"
  admin_enabled       = true
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# Container Instances — one per service
# ---------------------------------------------------------------------------
resource "azurerm_container_group" "services" {
  for_each = var.services

  name                = "aci-aitheros-${each.key}"
  location            = azurerm_resource_group.aither.location
  resource_group_name = azurerm_resource_group.aither.name
  os_type             = "Linux"
  restart_policy      = "Always"
  ip_address_type     = lookup(each.value, "public", false) ? "Public" : "Private"
  subnet_ids          = lookup(each.value, "public", false) ? null : [azurerm_subnet.services.id]

  tags = local.common_tags

  container {
    name   = each.key
    image  = each.value.image
    cpu    = lookup(each.value, "cpu", local.profile.aci_cpu)
    memory = lookup(each.value, "memory", local.profile.aci_memory)

    dynamic "ports" {
      for_each = lookup(each.value, "ports", [])
      content {
        port     = ports.value
        protocol = "TCP"
      }
    }

    environment_variables = merge(var.common_env, lookup(each.value, "env", {}))

    dynamic "liveness_probe" {
      for_each = lookup(each.value, "health_path", null) != null ? [each.value.health_path] : []
      content {
        http_get {
          path   = liveness_probe.value
          port   = each.value.ports[0]
          scheme = "Http"
        }
        initial_delay_seconds = 30
        period_seconds        = 30
        failure_threshold     = 3
      }
    }
  }

  dynamic "image_registry_credential" {
    for_each = var.registry_credentials != null ? [var.registry_credentials] : []
    content {
      server   = image_registry_credential.value.server
      username = image_registry_credential.value.username
      password = image_registry_credential.value.password
    }
  }
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace (monitoring)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "aither" {
  name                = "law-aitheros-${var.environment}"
  location            = azurerm_resource_group.aither.location
  resource_group_name = azurerm_resource_group.aither.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}
