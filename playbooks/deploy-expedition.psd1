@{
    Name        = "deploy-expedition"
    Description = "End-to-end customer expedition deployment — scaffold, build, deploy containers, configure tunnel, verify health"
    Version     = "1.0.0"
    Author      = "AitherZero"

    # ═══════════════════════════════════════════════════════════════════════════
    # EXPEDITION DEPLOYMENT PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # Deploys a customer expedition app from scratch:
    #   Invoke-AitherPlaybook deploy-expedition -Parameters @{
    #       Name = 'acme-crm'; Hostname = 'app.acmecrm.io'; Stack = 'fastapi'
    #   }
    #
    # Or use individual scripts:
    #   3061 — Scaffold new expedition
    #   3060 — Deploy expedition (container + tunnel)
    #   3062 — Tear down expedition
    #
    # AGENTS:
    #   Atlas  → Plans the expedition, selects stack, delegates to Demiurge
    #   Demi   → Generates app code, runs scaffold, triggers deploy
    #   AitherZero → Executes the scripts, manages infrastructure
    #
    # ═══════════════════════════════════════════════════════════════════════════

    Parameters = @{
        # Expedition name (short slug, e.g. "wildroot", "acme-crm")
        Name        = ''

        # Public hostname(s), comma-separated (e.g. "app.acmecrm.io,www.acmecrm.io")
        Hostname    = ''

        # App stack: fastapi | express | static | custom
        Stack       = 'fastapi'

        # Internal container port
        Port        = 8000

        # Whether to build Docker images
        Build       = $true

        # Skip tunnel configuration (container-only deploy)
        SkipTunnel  = $false

        # Force overwrite existing expedition
        Force       = $false
    }

    # ── Prerequisite checks ───────────────────────────────────────────────
    Prerequisites = @(
        @{
            Check       = 'docker info 2>&1 | Out-Null; $LASTEXITCODE -eq 0'
            Description = 'Docker daemon is running'
            FailAction  = 'abort'
        }
        @{
            Check       = 'Test-Path "$ProjectRoot/.env"'
            Description = 'Root .env file exists (Cloudflare credentials)'
            FailAction  = 'warn'
        }
        @{
            Check       = '$params.Name -ne ""'
            Description = 'Expedition name is provided'
            FailAction  = 'abort'
        }
    )

    # ── Playbook stages ──────────────────────────────────────────────────
    Stages = @(
        # ── Stage 1: Scaffold ──────────────────────────────────────────
        @{
            Name        = "scaffold"
            Description = "Scaffold expedition directory and boilerplate"
            Script      = 3061
            Parameters  = @{
                Name     = '{{Name}}'
                Stack    = '{{Stack}}'
                Hostname = '{{Hostname}}'
                Port     = '{{Port}}'
            }
            Condition   = '!(Test-Path "$ProjectRoot/expeditions/{{Name}}/backend/docker-compose.yml") -or $params.Force'
            OnFailure   = 'abort'
            Timeout     = 120
        }

        # ── Stage 2: Deploy ────────────────────────────────────────────
        @{
            Name        = "deploy"
            Description = "Build containers, start stack, configure tunnel route, sync to Cloudflare"
            Script      = 3060
            Parameters  = @{
                Name        = '{{Name}}'
                Hostname    = '{{Hostname}}'
                Service     = 'http://{{Name}}-backend:{{Port}}'
                Build       = '{{Build}}'
                SkipTunnel  = '{{SkipTunnel}}'
                Force       = '$true'
            }
            Condition   = '$params.Hostname -ne ""'
            OnFailure   = 'warn'
            Timeout     = 300
        }

        # ── Stage 3: Verify ────────────────────────────────────────────
        @{
            Name        = "verify"
            Description = "Verify container health and tunnel reachability"
            Script      = $null
            Command     = @'
$containerName = "{{Name}}-backend"
$health = docker inspect --format '{{{{.State.Health.Status}}}}' $containerName 2>&1
if ($health -eq 'healthy' -or (docker inspect --format '{{{{.State.Status}}}}' $containerName 2>&1) -eq 'running') {
    Write-Host "  ✓ Container $containerName is running" -ForegroundColor Green
} else {
    Write-Host "  ✗ Container $containerName is NOT healthy: $health" -ForegroundColor Red
    exit 1
}

# Check tunnel (if hostname provided)
$hostname = "{{Hostname}}" -split ',' | Select-Object -First 1
if ($hostname -and $hostname -ne '') {
    try {
        $resp = Invoke-RestMethod -Uri "https://$hostname/health" -TimeoutSec 15 -ErrorAction Stop
        Write-Host "  ✓ Tunnel health check passed: https://$hostname/health" -ForegroundColor Green
    } catch {
        Write-Host "  ℹ Tunnel health check pending (DNS may need propagation)" -ForegroundColor Yellow
        Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
'@
            OnFailure   = 'warn'
            Timeout     = 60
        }
    )

    # ── Post-playbook actions ─────────────────────────────────────────────
    OnComplete = @{
        Success = @'
Write-Host ""
Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✓ Expedition '{{Name}}' deployed successfully!" -ForegroundColor Green
Write-Host "  ══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Local:  http://localhost:$(docker port {{Name}}-backend 2>&1 | Select-String '\d+$' | ForEach-Object { $_.Matches[0].Value })" -ForegroundColor Cyan
if ("{{Hostname}}" -ne '') {
    Write-Host "  Public: https://$(("{{Hostname}}" -split ',')[0])" -ForegroundColor Cyan
}
Write-Host ""
'@
        Failure = @'
Write-Host ""
Write-Host "  ✗ Expedition deployment had errors. Check logs above." -ForegroundColor Red
Write-Host "  Retry: Invoke-AitherPlaybook deploy-expedition -Parameters @{ Name='{{Name}}'; Hostname='{{Hostname}}'; Stack='{{Stack}}' }" -ForegroundColor Yellow
Write-Host ""
'@
    }

    # ── Metadata for agent discovery ──────────────────────────────────────
    Tags = @("expedition", "deploy", "customer-app", "docker", "tunnel", "cloudflare")
    AgentHints = @{
        atlas     = "Use this playbook when the user asks to deploy a new customer project or expedition. Provide Name, Hostname, and Stack."
        demiurge  = "Use this playbook after generating customer app code. Pass the expedition Name and Hostname to trigger full deployment."
        aitherzero = "Scripts 3060/3061/3062 in 30-deploy/ handle the individual phases. This playbook orchestrates all three."
    }
}
