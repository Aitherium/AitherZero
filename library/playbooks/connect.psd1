@{
    Name        = "connect"
    Description = "Self-service connect: sign in to Aitherium (browser device flow), make sure inference is reachable, wire your IDE to the MCP gateway, prove it"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # CONNECT — the second half of dev-workstation
    # ==========================================================================
    #
    # dev-workstation puts adk/awsh on the box. This one connects them:
    #
    #   1. adk login             browser device flow (or --github)
    #   2. inference             reuse any backend that is UP, else adk quickstart --cloud
    #   3. adk mcp setup         write the IDE's MCP config for mcp.aitherium.com
    #   4. adk mcp status        prove the gateway answers
    #
    # USAGE:
    #   Invoke-AitherPlaybook connect
    #   Invoke-AitherPlaybook connect -Variables @{ Ide = 'cursor' }
    #   Invoke-AitherPlaybook connect -Variables @{ Inference = 'local' }   # GPU box
    #
    # Blank machine, one paste (tools + connect):
    #   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1))) -Playbook dev-workstation -Variables @{ Login = $true }
    #   Invoke-AitherPlaybook connect
    #
    # Step 1 opens a browser; this playbook is interactive by design. It is
    # idempotent: an existing login and a reachable backend are reused.
    # ==========================================================================

    Parameters = @{
        # IDE / agent to wire: claude-code, cursor, windsurf, vscode, none
        Ide       = 'claude-code'

        # MCP gateway: remote (mcp.aitherium.com) or local (Docker gateway :8182)
        Gateway   = 'remote'

        # Inference: cloud (no GPU; default) or local (adk quickstart, pulls models)
        Inference = 'cloud'

        # Bake the auth token into the IDE config (IDEs without OAuth)
        BakeToken = $false
    }

    Prerequisites = @(
        "dev-workstation playbook (adk on PATH)"
        "A browser for the device-flow sign-in"
        "Network egress to api.aitherium.com and mcp.aitherium.com"
    )

    Sequence = @(
        @{
            Name            = "Sign in to Aitherium"
            Script          = "32-onboarding/3263_Connect-Aitherium"
            Description     = "adk login (browser device flow); skipped if already signed in"
            ContinueOnError = $false
        }
        @{
            Name            = "Inference"
            Script          = "32-onboarding/3264_Connect-Inference"
            Description     = "Reuse a backend that is UP, else adk quickstart (--cloud by default)"
            Parameters      = @{ Mode = '$Inference' }
            ContinueOnError = $false
        }
        @{
            Name            = "Wire IDE to MCP"
            Script          = "32-onboarding/3265_Connect-IDE"
            Description     = "adk mcp setup for the chosen IDE, then adk mcp status must show the gateway OK"
            Parameters      = @{ Ide = '$Ide'; Mode = '$Gateway'; BakeToken = '$BakeToken' }
            ContinueOnError = $false
        }
        @{
            Name            = "Verify"
            Script          = "32-onboarding/3262_Test-DevWorkstation"
            Description     = "Every tool answers; adk status shows a reachable backend"
            ContinueOnError = $false
        }
    )

    Options = @{
        Parallel       = $false
        MaxConcurrency = 1
        StopOnError    = $true
    }

    OnSuccess = @{
        Message = @'

+=================================================================+
|   CONNECTED                                                      |
+=================================================================+
|                                                                  |
|  Signed in, inference reachable, IDE '$Ide' wired to the        |
|  $Gateway MCP gateway.                                           |
|                                                                  |
|    awsh                     ask your terminal anything           |
|    adk start                chat with your codebase              |
|    adk claude-model code    switch Claude Code to DeepSeek Flash |
|    adk claude-model list    ...or any other profile              |
|                                                                  |
+=================================================================+
'@
    }

    OnFailure = @{
        Message = @'

+=================================================================+
|   CONNECT FAILED                                                 |
+=================================================================+
|  - Browser did not open      -> adk login --github  (device code) |
|  - Gateway not OK            -> adk mcp status; check egress to  |
|                                 mcp.aitherium.com                |
|  - quickstart --cloud asks   -> adk login first; or pass         |
|    for a key                    -Variables @{ Inference='local' }|
|  Re-run: Invoke-AitherPlaybook connect   (idempotent)            |
+=================================================================+
'@
    }
}
