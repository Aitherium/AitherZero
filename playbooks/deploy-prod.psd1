@{
    # =========================================================================
    # AITHEROS PRODUCTION DEPLOYMENT PLAYBOOK
    # =========================================================================
    # Deploys AitherOS to production Kubernetes cluster
    # Usage: ./bootstrap.ps1 -Playbook deploy-prod
    # =========================================================================

    Name = "deploy-prod"
    Description = "Deploy AitherOS to production Kubernetes cluster"
    Version = "2.0.0"
    Author = "AitherZero"
    Category = "deploy"

    # Parameters
    Parameters = @{
        Namespace = "aitheros"
        Registry = "ghcr.io/aitheros"
        Tag = "latest"
        Context = ""  # Kubernetes context to use
        DryRun = $false
        RollingUpdate = $true
    }

    Prerequisites = @(
        "kubectl configured with cluster access"
        "Images pushed to registry"
        "Kubernetes namespace created"
    )

    Sequence = @(
        # =====================================================================
        # PHASE 1: VALIDATION
        # =====================================================================
        @{
            Name = "Validate Kubernetes Connection"
            Script = "00-bootstrap/0001_Validate-Prerequisites"
            Description = "Verify Kubernetes cluster access"
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 2: NAMESPACE SETUP
        # =====================================================================
        @{
            Name = "Create Namespace"
            Script = "30-deploy/3002_Deploy-K8sCluster"
            Description = "Create Kubernetes namespace and secrets"
            Parameters = @{
                Namespace = '$Namespace'
                Action = "setup"
                DryRun = '$DryRun'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 3: DEPLOY
        # =====================================================================
        @{
            Name = "Deploy Genesis"
            Script = "30-deploy/3002_Deploy-K8sCluster"
            Description = "Deploy Genesis bootloader to Kubernetes"
            Parameters = @{
                Namespace = '$Namespace'
                Registry = '$Registry'
                Tag = '$Tag'
                Component = "genesis"
                DryRun = '$DryRun'
            }
            ContinueOnError = $false
        },

        @{
            Name = "Deploy Services"
            Script = "30-deploy/3002_Deploy-K8sCluster"
            Description = "Deploy all services to Kubernetes"
            Parameters = @{
                Namespace = '$Namespace'
                Registry = '$Registry'
                Tag = '$Tag'
                Component = "services"
                RollingUpdate = '$RollingUpdate'
                DryRun = '$DryRun'
            }
            ContinueOnError = $false
        },

        @{
            Name = "Deploy Veil Dashboard"
            Script = "30-deploy/3002_Deploy-K8sCluster"
            Description = "Deploy Veil dashboard to Kubernetes"
            Parameters = @{
                Namespace = '$Namespace'
                Registry = '$Registry'
                Tag = '$Tag'
                Component = "veil"
                DryRun = '$DryRun'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 4: VALIDATION
        # =====================================================================
        @{
            Name = "Validate Deployment"
            Script = "80-testing/8002_Validate-Services"
            Description = "Verify all services are healthy"
            Parameters = @{
                Namespace = '$Namespace'
                WaitTimeout = 300
            }
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 5: EDGE HARDENING
        # =====================================================================
        @{
            Name = "Sync Cloudflare Tunnel Routes"
            Script = "30-deploy/3040_Sync-CloudflareTunnel"
            Description = "Push tunnel-routes.yaml to Cloudflare API"
            ContinueOnError = $true
        },
        @{
            Name = "Enforce Cloudflare SSL/TLS"
            Script = "30-deploy/3042_Enforce-CloudflareSSL"
            Description = "Enforce HSTS, Full(Strict) SSL, TLS 1.3 for aitherium.com"
            ContinueOnError = $true
        },
        @{
            Name = "Tunnel Health Check"
            Script = "30-deploy/3041_CloudflareTunnel-HealthCheck"
            Description = "Verify all tunnel routes are live and healthy"
            Parameters = @{ ReportOnly = $true }
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  PRODUCTION DEPLOYMENT COMPLETE!
  ============================================================

  AitherOS has been deployed to Kubernetes.

  Check status:
    kubectl -n aitheros get pods
    kubectl -n aitheros get services

  Access:
    kubectl -n aitheros port-forward svc/genesis 8001:8001
    kubectl -n aitheros port-forward svc/veil 3000:3000

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  PRODUCTION DEPLOYMENT FAILED
  ============================================================

  Please check the Kubernetes logs for errors:
    kubectl -n aitheros logs -l app=genesis
    kubectl -n aitheros describe pods

  To rollback:
    ./AitherZero/library/automation-scripts/40-lifecycle/4005_Rollback-Deployment.ps1

"@
    }
}
