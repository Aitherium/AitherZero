@{
    # =========================================================================
    # CD LOCAL DEPLOY PLAYBOOK
    # =========================================================================
    # Pulls images from GHCR and rolling-restarts local AitherOS services.
    # Triggered by GitHub Actions self-hosted runner after merge to develop.
    #
    # Usage:
    #   Invoke-AitherPlaybook -Name cd-local-deploy
    #   Invoke-AitherPlaybook -Name cd-local-deploy -Variables @{ Tag = "sha-abc1234"; Services = "genesis" }
    # =========================================================================

    Name        = "cd-local-deploy"
    Description = "Pull images from GHCR and rolling-restart local AitherOS services"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    Parameters = @{
        Tag            = "latest"
        Services       = "genesis,veil"
        Profile        = "all"
        Registry       = "ghcr.io/aitherium"
        HealthCheckTimeout = 120
        DryRun         = $false
        NonInteractive = '$env:CI -eq "true" -or $env:GITHUB_ACTIONS -eq "true"'
    }

    Prerequisites = @(
        "Docker installed and running"
        "Authenticated to GHCR (docker login ghcr.io)"
        "AitherOS compose file available"
    )

    Sequence = @(
        # Phase 1: Validate environment
        @{
            Name            = "Validate Docker & Prerequisites"
            Script          = "00-bootstrap/0001_Validate-Prerequisites"
            Description     = "Verify Docker is running and system meets requirements"
            Parameters      = @{
                MinDiskSpaceGB = 5
                MinMemoryGB    = 8
            }
            ContinueOnError = $false
        },

        # Phase 2: Pull images and rolling restart
        @{
            Name            = "Pull & Deploy from GHCR"
            Script          = "30-deploy/3050_Deploy-FromGHCR"
            Description     = "Pull updated images from GHCR, rolling restart, health check"
            Parameters      = @{
                Tag                = '$Tag'
                Services           = '$Services'
                Registry           = '$Registry'
                Profile            = '$Profile'
                HealthCheckTimeout = '$HealthCheckTimeout'
                DryRun             = '$DryRun'
                NonInteractive     = '$NonInteractive'
            }
            ContinueOnError = $false
        },

        # Phase 3: Edge hardening
        @{
            Name            = "Sync Cloudflare Tunnel"
            Script          = "30-deploy/3040_Sync-CloudflareTunnel"
            Description     = "Push tunnel-routes.yaml to Cloudflare API"
            Condition       = 'Test-Path (Join-Path $ProjectRoot "AitherOS/config/tunnel-routes.yaml")'
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  CD DEPLOYMENT COMPLETE
  ============================================================

  Services updated from GHCR and verified healthy.

  Access points:
    Dashboard:    http://localhost:3000
    Genesis API:  http://localhost:8001
    Demo:         https://chat.aitherium.com

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  CD DEPLOYMENT FAILED
  ============================================================

  Check the logs above. Rollback may have been triggered.

  Manual recovery:
    1. Check: docker compose -f docker-compose.aitheros.yml ps
    2. Logs:  docker compose -f docker-compose.aitheros.yml logs aither-genesis
    3. Rebuild locally: docker compose --profile all build --no-cache aither-genesis
    4. Restart: docker compose --profile all up -d aither-genesis

"@
    }
}
