@{
    Name        = "node-onboard"
    Description = "Onboard THIS machine as a secure AitherOS cluster node (Windows / Linux / macOS) — one cross-platform playbook, CLI args, zero drift"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    # ==========================================================================
    # CROSS-PLATFORM NODE ONBOARDING PLAYBOOK
    # ==========================================================================
    #
    # USAGE:
    #   Invoke-AitherPlaybook node-onboard -Variables @{ Token = "<enroll-token>" }
    #   Invoke-AitherPlaybook node-onboard -Variables @{
    #       Token   = "<enroll-token>"
    #       Gateway = "https://cluster.aitherium.com"
    #       NodeId  = "home-lab-01"
    #       Role    = "sovereign"
    #   }
    #
    # The single one-liner a customer runs (any OS — AitherZero bootstraps pwsh7 + deps):
    #   pwsh -NoProfile -Command "iwr -useb https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex; Invoke-AitherPlaybook node-onboard -Variables @{ Token='<tok>' }"
    #
    # GOAL: enroll the machine as a first-class, observable mesh node — no inbound
    #       ports, reboot-safe service, registers + heartbeats through the tunnel.
    #
    # HOW: delegates to the canonical, gateway-published installer for the host OS
    #      (install.sh on Linux/macOS, install.ps1 on Windows) so there is ONE
    #      source of truth and zero drift between the playbook and the website.
    # ==========================================================================

    Parameters = @{
        # REQUIRED: single-use enrollment token (minted in the portal "My Nodes",
        # or `adk grid enroll`) — or the long-lived cluster PSK.
        Token   = ''

        # Gateway the node registers through (public tunnel endpoint).
        Gateway = 'https://cluster.aitherium.com'

        # Node identity + role. Empty NodeId => derived from hostname.
        NodeId  = ''
        Role    = 'sovereign'

        # Preview only — validate + show what would run, change nothing.
        DryRun  = $false
    }

    Prerequisites = @(
        "PowerShell 7+ (AitherZero bootstrap installs it on any OS)"
        "python3 on the node (the installer auto-installs it if missing)"
        "Network egress to the gateway (no inbound ports required)"
        "A valid enrollment token or cluster PSK"
    )

    Sequence = @(
        @{
            Name            = "Onboard cluster node (OS-detected installer)"
            Script          = "32-onboarding/3214_Onboard-ClusterNode"
            Description     = "Fetch + run the canonical gateway installer for this OS, register + heartbeat the node"
            Parameters      = @{
                Token   = '$Token'
                Gateway = '$Gateway'
                NodeId  = '$NodeId'
                Role    = '$Role'
                DryRun  = '$DryRun'
            }
            ContinueOnError = $false
        }
    )

    OnSuccess = @{
        Message = @"

+=================================================================+
|   NODE ONBOARDED — registered + heartbeating through the tunnel  |
+=================================================================+
|                                                                  |
|  It now appears in the portal under "My Nodes", online.          |
|                                                                  |
|  VERIFY:                                                         |
|    Linux   : systemctl status aither-cluster-agent               |
|    Windows : Get-ScheduledTaskInfo -TaskName AitherClusterNodeAgent |
|    Portal  : portal.aitherium.com -> Nodes                       |
|                                                                  |
+=================================================================+
"@
    }

    # Single sequential step — pin the execution options so the runner doesn't
    # fall back to a global-config lookup for MaxConcurrency (keeps onboarding
    # self-contained / config-subsystem-independent).
    Options = @{
        Parallel       = $false
        MaxConcurrency = 1
        StopOnError    = $true
    }

    OnFailure = @{
        Message = @"

+=================================================================+
|   NODE ONBOARDING FAILED                                         |
+=================================================================+
|  COMMON ISSUES:                                                  |
|    - Token expired / already used -> mint a fresh one in the     |
|      portal "My Nodes" (single-use, ~60 min TTL)                 |
|    - python3 missing + no winget/apt -> install Python 3, re-run |
|    - Gateway unreachable -> check egress to the -Gateway URL     |
+=================================================================+
"@
    }
}
