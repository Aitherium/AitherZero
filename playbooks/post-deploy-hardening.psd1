# =====================================================================
# Playbook: post-deploy-hardening
# Purpose:  Standalone edge/Cloudflare hardening pipeline
#           Can be invoked independently after any deployment:
#             Invoke-AitherPlaybook post-deploy-hardening
# =====================================================================

@{
    Name        = "post-deploy-hardening"
    Version     = "1.0.0"
    Description = "Post-deployment edge hardening: Cloudflare Tunnel sync, SSL/TLS enforcement, health verification"
    Author      = "AitherZero Automation"
    Tags        = @("deploy", "cloudflare", "security", "hardening", "post-deploy")

    # ── Parameters ──────────────────────────────────────────────────
    Parameters  = @{
        DryRun     = @{ Type = "switch"; Default = $false; Description = "Preview changes without applying" }
        ReportOnly = @{ Type = "switch"; Default = $false; Description = "Only report current state, no enforcement" }
    }

    # ── Pre-flight Checks ──────────────────────────────────────────
    PreChecks   = @(
        @{
            Name      = "Cloudflare Token Available"
            Condition = '(Test-Path env:CF_ZONE_SETTINGS_TOKEN) -or (Test-Path env:CLOUDFLARE_API_TOKEN) -or (Get-AitherCredential -Name "CF_ZONE_SETTINGS_TOKEN" -ErrorAction SilentlyContinue)'
            Message   = "No Cloudflare API token found. Set CF_ZONE_SETTINGS_TOKEN or store via Set-AitherCredential."
        }
    )

    # ── Execution Sequence ─────────────────────────────────────────
    Sequence    = @(
        # ─── Phase 1: Tunnel Route Synchronization ─────────────────
        @{
            Name        = "tunnel-sync"
            Description = "Push tunnel-routes.yaml to Cloudflare API"
            Steps       = @(
                @{
                    Name            = "Sync Cloudflare Tunnel Routes"
                    Script          = "3040"
                    Description     = "Reconcile local tunnel-routes.yaml with Cloudflare tunnel config"
                    ContinueOnError = $true
                }
            )
        }

        # ─── Phase 2: SSL/TLS Hardening ────────────────────────────
        @{
            Name        = "ssl-hardening"
            Description = "Enforce strict SSL/TLS settings on Cloudflare zone"
            Steps       = @(
                @{
                    Name            = "Enforce SSL/TLS Hardening"
                    Script          = "3042"
                    Description     = "Apply HSTS, Full(Strict) SSL, TLS 1.3, Always HTTPS, min TLS 1.2"
                    Args            = '-Action $(if ($Parameters.ReportOnly) { "verify" } else { "enforce" })'
                    ContinueOnError = $false
                }
            )
        }

        # ─── Phase 3: Health Verification ──────────────────────────
        @{
            Name        = "health-verification"
            Description = "Verify tunnel routes and edge connectivity"
            Steps       = @(
                @{
                    Name            = "Tunnel Health Check"
                    Script          = "3041"
                    Description     = "Verify all Cloudflare tunnel routes are live and responding"
                    Args            = "-ReportOnly"
                    ContinueOnError = $true
                }
                @{
                    Name            = "SSL Compliance Report"
                    Script          = "3042"
                    Description     = "Generate final compliance report"
                    Args            = "-Action report"
                    ContinueOnError = $true
                }
            )
        }
    )

    # ── Post-Execution ─────────────────────────────────────────────
    OnSuccess   = @{
        Message = "Edge hardening complete — all Cloudflare settings verified."
        Notify  = @("Pulse", "Strata")
    }

    OnFailure   = @{
        Message = "Edge hardening had failures — review output above."
        Notify  = @("Pulse")
    }
}
