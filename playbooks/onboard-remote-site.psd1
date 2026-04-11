@{
    Name        = "onboard-remote-site"
    Description = "Lightweight AitherNode deployment — installs ADK, configures MCP for your IDE, connects to Elysium"
    Version     = "2.0.0"
    Author      = "AitherZero"

    # ═══════════════════════════════════════════════════════════════════════════
    # LIGHTWEIGHT REMOTE NODE ONBOARDING PLAYBOOK
    # ═══════════════════════════════════════════════════════════════════════════
    #
    # This is NOT a full AitherOS Docker deployment. It installs:
    #   - aither-adk (pip package) — agent framework + CLI
    #   - AitherNode (MCP server) — bridges local IDE tools to Elysium
    #   - AitherDesktop (optional) — native overlay app
    #   - MCP config for Claude Code / Cursor / OpenClaw
    #
    # THE COMMAND:
    #   Invoke-AitherPlaybook onboard-remote-site -Variables @{
    #       TenantSlug   = 'welchman-labs'
    #       ApiKey       = 'aither_sk_live_...'
    #   }
    #
    # OR (generated installer):
    #   pip install aither-adk && aither onboard --tenant welchman-labs
    #
    # ═══════════════════════════════════════════════════════════════════════════

    Parameters = @{
        # Tenant identity (org/project, NOT personal username)
        TenantSlug       = ''
        TenantName       = ''
        AdminEmail       = ''

        # Credentials
        ApiKey           = '$env:AITHER_API_KEY'
        TunnelToken      = '$env:CLOUDFLARE_TUNNEL_TOKEN ?? ""'

        # What to install
        InstallADK       = $true
        InstallDesktop   = $false
        ConfigureMCP     = $true
        StartNode        = $true

        # Cloud connection
        ControllerUrl    = '$env:AITHER_CONTROLLER_URL ?? "https://gateway.aitherium.com"'
        InferenceUrl     = '$env:AITHER_INFERENCE_URL ?? "https://mcp.aitherium.com/v1"'

        # Options
        NonInteractive   = '$env:CI -eq "true"'
        Force            = $false
    }

    Prerequisites = @(
        "Python 3.10+ (for pip install aither-adk)"
        "Internet connection"
        "ACTA API key (from portal.aitherium.com or aither register)"
    )

    Sequence = @(
        # ============================================================
        # PHASE 1: SYSTEM DETECTION
        # ============================================================

        @{
            Name            = "System Detection"
            Script          = "0011_Get-SystemInfo"
            Description     = "Detect platform, hardware, GPU"
            Parameters      = @{}
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 2: INSTALL ADK
        # ============================================================

        @{
            Name            = "Install AitherADK"
            Script          = "32-onboarding/3210_Install-ADK"
            Description     = "pip install aither-adk (agent framework + CLI)"
            Condition       = '$InstallADK -eq $true'
            Parameters      = @{
                InstallDesktop = '$InstallDesktop'
            }
            ContinueOnError = $false
        }

        # ============================================================
        # PHASE 3: CONFIGURE CREDENTIALS
        # ============================================================

        @{
            Name            = "Configure Credentials"
            Script          = "32-onboarding/3202_Connect-Elysium"
            Description     = "Write ~/.aither/config.json, verify cloud gateway"
            Parameters      = @{
                ApiKey       = '$ApiKey'
                GatewayUrl   = '$ControllerUrl'
                InferenceUrl = '$InferenceUrl'
            }
            ContinueOnError = $false
        }

        # ============================================================
        # PHASE 4: CONFIGURE MCP FOR IDEs
        # ============================================================

        @{
            Name            = "Configure MCP Servers"
            Script          = "32-onboarding/3211_Configure-MCP"
            Description     = "Auto-configure Claude Code, Cursor, OpenClaw, VS Code"
            Condition       = '$ConfigureMCP -eq $true'
            Parameters      = @{
                NodePort = 8080
            }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 5: START AITHERNODE
        # ============================================================

        @{
            Name            = "Start AitherNode"
            Script          = "32-onboarding/3212_Start-Node"
            Description     = "Start AitherNode MCP server (bridges local <> Elysium)"
            Condition       = '$StartNode -eq $true'
            Parameters      = @{
                ApiKey     = '$ApiKey'
                TenantSlug = '$TenantSlug'
                Port       = 8080
            }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 6: SETUP TUNNEL (optional)
        # ============================================================

        @{
            Name            = "Setup Tunnel"
            Script          = "32-onboarding/3200_Setup-SiteTunnel"
            Description     = "Install cloudflared and start tunnel (if token provided)"
            Condition       = '$TunnelToken -ne ""'
            Parameters      = @{
                TunnelToken = '$TunnelToken'
                SiteSlug    = '$TenantSlug'
            }
            ContinueOnError = $true
        }

        # ============================================================
        # PHASE 7: WALLET & BACKUP
        # ============================================================

        @{
            Name            = "Setup Wallet & Backup"
            Script          = "32-onboarding/3203_Setup-WalletAndBackup"
            Description     = "Secure credentials in Lockbox, configure GitHub backup"
            Parameters      = @{
                ApiKey     = '$ApiKey'
                SiteSlug   = '$TenantSlug'
                AdminEmail = '$AdminEmail'
            }
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

=====================================================================

          NODE DEPLOYED SUCCESSFULLY

=====================================================================

  TENANT:         {TenantSlug}
  NODE:           {TenantSlug}.aitherium.com
  MCP SERVER:     http://localhost:8080

  WHAT'S RUNNING:
    - AitherNode (MCP server) bridging your IDE to Elysium
    - MCP configured for Claude Code / Cursor / OpenClaw

  COMMANDS:
    aither run              Start your agent
    aither init my-agent    Create a new agent project
    aither connect          Check Elysium connection
    aither onboard          Re-run onboarding

  OPTIONAL:
    pip install aither-desktop    Native desktop overlay

=====================================================================
"@
    }

    OnFailure = @{
        Message = @"

=====================================================================
          ONBOARDING ENCOUNTERED ERRORS
=====================================================================

  COMMON FIXES:
    Python not found:    Install Python 3.10+
    pip install fails:   pip install --upgrade pip && pip install aither-adk
    No API key:          aither register --email you@email.com
    Cloud unreachable:   Check internet connection

=====================================================================
"@
    }
}
