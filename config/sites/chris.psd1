#Requires -Version 7.0

<#
.SYNOPSIS
    Site config for Chris's AitherOS node (Welchman Labs tenant).
.DESCRIPTION
    Drives the onboard-remote-site playbook. Lightweight ADK + AitherNode
    deployment — NOT a full Docker stack.

    Usage:
        Invoke-AitherPlaybook onboard-remote-site -ConfigOverlay sites/chris.psd1

    Or just:
        pip install aither-adk
        aither onboard --tenant welchman-labs
#>

@{
    # ═══════════════════════════════════════════════════════════════════════
    # TENANT (org/project — NOT personal username)
    # ═══════════════════════════════════════════════════════════════════════

    TenantSlug           = 'welchman-labs'
    TenantName           = 'Welchman Labs'
    AdminEmail           = 'chris@aitherium.com'

    # Chris's personal user accounts:
    #   tnt_chris (personal tenant) — admin
    #   tnt_aitherium (org member) — admin
    # This tenant is the SITE deployment:
    #   tnt_welchman_labs — the node identity

    # ═══════════════════════════════════════════════════════════════════════
    # CREDENTIALS (Chris generates/provides these himself)
    # ═══════════════════════════════════════════════════════════════════════

    ApiKey               = '$env:AITHER_API_KEY'               # From: aither register
    TunnelToken          = '$env:CLOUDFLARE_TUNNEL_TOKEN ?? ""' # From: deploy-site UI

    # ═══════════════════════════════════════════════════════════════════════
    # WHAT GETS INSTALLED (lightweight model)
    # ═══════════════════════════════════════════════════════════════════════

    InstallADK           = $true       # pip install aither-adk
    InstallDesktop       = $true       # pip install aither-desktop (Chris gets it)
    ConfigureMCP         = $true       # Auto-configure Claude Code / Cursor / OpenClaw
    StartNode            = $true       # Start AitherNode MCP server

    # ═══════════════════════════════════════════════════════════════════════
    # CLOUD CONNECTION
    # ═══════════════════════════════════════════════════════════════════════

    ControllerUrl        = 'https://gateway.aitherium.com'
    InferenceUrl         = 'https://mcp.aitherium.com/v1'

    # Chris has enterprise-tier access — unlimited via Elysium
    PlanTier             = 'enterprise'

    # ═══════════════════════════════════════════════════════════════════════
    # WALLET & BACKUP
    # ═══════════════════════════════════════════════════════════════════════

    Wallet               = @{
        LockboxEnabled   = $true
        BackupRepo       = 'Aitherium/backup-user-chris'
        BackupSchedule   = 'daily'
    }

    # ═══════════════════════════════════════════════════════════════════════
    # OPTIONS
    # ═══════════════════════════════════════════════════════════════════════

    NonInteractive       = $false
    Force                = $false
}
