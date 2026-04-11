@{
    # =========================================================================
    # AITHEROS LOCAL DEPLOYMENT PLAYBOOK
    # =========================================================================
    # Deploys AitherOS locally using Docker Compose
    # Usage: ./bootstrap.ps1 -Playbook deploy-local
    # =========================================================================

    Name = "deploy-local"
    Description = "Deploy AitherOS locally using Docker Compose"
    Version = "2.0.0"
    Author = "AitherZero"
    Category = "deploy"

    # Parameters
    Parameters = @{
        Profile = "core"  # minimal, core, full
        Environment = "development"  # development, production
        Build = $true  # Build images before starting
        Wait = $true  # Wait for services to be healthy
        OpenDashboard = $true
    }

    Prerequisites = @(
        "Docker installed and running"
        "Images built (run 'build' playbook first, or use Build=$true)"
    )

    Sequence = @(
        # =====================================================================
        # PHASE 1: VALIDATION
        # =====================================================================
        @{
            Name = "Validate Docker"
            Script = "00-bootstrap/0001_Validate-Prerequisites"
            Description = "Verify Docker is running"
            Parameters = @{
                MinDiskSpaceGB = 10
                MinMemoryGB = 8
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 2: BUILD (OPTIONAL)
        # =====================================================================
        @{
            Name = "Build Images"
            Script = "20-build/2003_Build-ServiceImages"
            Description = "Build service images"
            Condition = '$Build -eq $true'
            Parameters = @{
                Target = '$Environment'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 3: DEPLOY
        # =====================================================================
        @{
            Name = "Start Genesis"
            Script = "40-lifecycle/4001_Start-Genesis"
            Description = "Start AitherOS using Docker Compose"
            Parameters = @{
                Profile = '$Profile'
                Environment = '$Environment'
                Detached = $true
                Wait = '$Wait'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 4: POST-INSTALL
        # =====================================================================
        @{
            Name = "Post-Install Provisioning"
            Script = "30-deploy/3034_Post-Install"
            Description = "Seed RBAC users/roles and ingest knowledge documents"
            ContinueOnError = $true
        },

        # =====================================================================
        # PHASE 5: EDGE HARDENING
        # =====================================================================
        @{
            Name = "Sync Cloudflare Tunnel"
            Script = "30-deploy/3040_Sync-CloudflareTunnel"
            Description = "Push tunnel-routes.yaml to Cloudflare API"
            ContinueOnError = $true
        },
        @{
            Name = "Enforce Cloudflare SSL/TLS"
            Script = "30-deploy/3042_Enforce-CloudflareSSL"
            Description = "Enforce HSTS, Full(Strict) SSL, TLS 1.3 — auto-remediates drift"
            ContinueOnError = $true
        },
        @{
            Name = "Tunnel Health Check"
            Script = "30-deploy/3041_CloudflareTunnel-HealthCheck"
            Description = "Verify all tunnel routes are healthy"
            Parameters = @{ ReportOnly = $true }
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  DEPLOYMENT COMPLETE!
  ============================================================

  AitherOS is now running locally.

  Access points:
    Dashboard:    http://localhost:3000
    Genesis API:  http://localhost:8001
    API Docs:     http://localhost:8001/docs

  Manage services:
    Status:   docker compose -f docker-compose.aitheros.yml ps
    Logs:     docker compose -f docker-compose.aitheros.yml logs -f
    Stop:     ./AitherZero/library/automation-scripts/40-lifecycle/4002_Stop-Genesis.ps1

  Useful commands:
    Get-AitherStatus    View service status
    Stop-AitherOS       Stop all services
    Open-AitherDashboard  Open dashboard in browser

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  DEPLOYMENT FAILED
  ============================================================

  Please check the logs above for errors.

  Troubleshooting:
    1. Ensure Docker is running
    2. Check available ports (8001, 3000)
    3. Check Docker logs: docker compose -f docker-compose.aitheros.yml logs

"@
    }
}
