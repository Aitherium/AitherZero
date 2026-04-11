# =============================================================================
# Network Module - VPC and Subnets for AitherOS
# =============================================================================

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "environment" {
  type = string
}

variable "labels" {
  type = map(string)
}

# -----------------------------------------------------------------------------
# VPC Network
# -----------------------------------------------------------------------------

resource "google_compute_network" "aither" {
  name                    = "aither-${var.environment}-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "aither" {
  name          = "aither-${var.environment}-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.aither.id
  project       = var.project_id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }

  private_ip_google_access = true
}

# -----------------------------------------------------------------------------
# Cloud NAT (for outbound internet access from private subnets)
# -----------------------------------------------------------------------------

resource "google_compute_router" "aither" {
  name    = "aither-${var.environment}-router"
  region  = var.region
  network = google_compute_network.aither.id
  project = var.project_id
}

resource "google_compute_router_nat" "aither" {
  name                               = "aither-${var.environment}-nat"
  router                             = google_compute_router.aither.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  project                            = var.project_id

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------------------------------------------------
# VPC Connector (for Cloud Run to access VPC resources)
# -----------------------------------------------------------------------------

resource "google_vpc_access_connector" "aither" {
  name          = "aither-${var.environment}"
  region        = var.region
  project       = var.project_id
  network       = google_compute_network.aither.name
  ip_cidr_range = "10.8.0.0/28"

  min_instances = 2
  max_instances = 3
}

# -----------------------------------------------------------------------------
# Firewall Rules
# -----------------------------------------------------------------------------

resource "google_compute_firewall" "allow_internal" {
  name    = "aither-${var.environment}-allow-internal"
  network = google_compute_network.aither.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "aither-${var.environment}-allow-health"
  network = google_compute_network.aither.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # Google Cloud health check IP ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["aither-service"]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "network_id" {
  value = google_compute_network.aither.id
}

output "network_name" {
  value = google_compute_network.aither.name
}

output "subnetwork_id" {
  value = google_compute_subnetwork.aither.id
}

output "subnetwork_name" {
  value = google_compute_subnetwork.aither.name
}

output "vpc_connector_id" {
  value = google_vpc_access_connector.aither.id
}

output "vpc_connector_name" {
  value = google_vpc_access_connector.aither.name
}
