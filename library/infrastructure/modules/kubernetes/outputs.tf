# =============================================================================
# AitherOS Kubernetes Module — Outputs
# =============================================================================

output "namespace" {
  description = "The namespace where AitherOS services are deployed"
  value       = kubernetes_namespace.aither.metadata[0].name
}

output "service_endpoints" {
  description = "Map of service names to their ClusterIP endpoints"
  value = {
    for name, svc in kubernetes_service.services :
    name => "${svc.metadata[0].name}.${svc.metadata[0].namespace}.svc.cluster.local:${svc.spec[0].port[0].port}"
  }
}

output "deployment_names" {
  description = "List of created deployment names"
  value       = [for name, dep in kubernetes_deployment.services : dep.metadata[0].name]
}

output "service_account" {
  description = "Service account name for AitherOS pods"
  value       = kubernetes_service_account.aither.metadata[0].name
}

output "ingress_hostname" {
  description = "Ingress hostname (if enabled)"
  value       = var.enable_ingress ? kubernetes_ingress_v1.aither[0].status[0].load_balancer[0].ingress[0].hostname : null
}
