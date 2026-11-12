@{
    Name        = "node-onboard"
    Description = "Onboard a machine as an AitherOS fleet node: pick its hardware tier, then join it to the fleet placement controller (awrun fleet-join, node id + certificate pin)"
    Version     = "2.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    # ==========================================================================
    # FLEET NODE ONBOARDING PLAYBOOK
    # ==========================================================================
    #
    # USAGE:
    #   Invoke-AitherPlaybook node-onboard -Variables @{ NodeId = "optiplex-wsl" }
    #   Invoke-AitherPlaybook node-onboard -Variables @{ NodeId = "awnix"; DryRun = $true }
    #
    # GOAL: the node becomes an APPROVED member of the fleet placement controller
    #       (aither-registry, https://127.0.0.1:8149 on the awnix host), verified
    #       by its certificate pin.
    #
    # HOW: 3239 picks the hardware tier; 3214 delegates to
    #      3268_Invoke-FleetMembership -Action join, which queues
    #      `awrun submit --kind node-op --action fleet-join` and drains it. The
    #      join token is minted controller-side, bound to the node id, and never
    #      passed in or printed. (The retired public-gateway installer path and
    #      its cluster-agent unit are gone.)
    #
    # Leaving the fleet: the fleet-node-leave playbook.
    # ==========================================================================

    Parameters = @{
        # The controller node id; also the nodes.yaml name the node transport
        # reaches. Empty => this machine's host name.
        NodeId     = ''

        # The https URL the joining node dials. Empty => the library default
        # (https://127.0.0.1:8149, right for the awnix host itself).
        Controller = ''

        # SHA-256 of the controller certificate. Empty => the measured pin
        # (or $env:AITHER_PLACEMENT_CONTROLLER_SHA256).
        PinSha256  = ''

        # Re-join a node the controller already approved.
        Force      = $false

        # Hardware tier. 'auto' detects the GPU; no GPU => cpu_only, the smallest
        # working model + enhancement loops (plan spec P5). Pin a profile name to override.
        Tier      = 'auto'
        PullModel = $false

        # Preview only: validate + show what would run, change nothing.
        DryRun  = $false
    }

    Prerequisites = @(
        "PowerShell 7+"
        "awrun on PATH and python with the AitherOS monorepo (the node-op worker)"
        "The awnix host's placement controller (aither-registry) running"
        "The node named in nodes.yaml, reachable by the node transport"
    )

    Sequence = @(
        @{
            Name            = "Select hardware tier (no GPU => smallest model, CPU-only)"
            Script          = "32-onboarding/3239_Select-NodeHardwareTier"
            Description     = "Detect GPU; pick the profile + default model; write ~/.aither/node-hardware.json and export AITHER_HARDWARE_TIER / AITHER_CPU_ONLY / AITHER_NODE_MODEL"
            Parameters      = @{
                Tier      = '$Tier'
                PullModel = '$PullModel'
                DryRun    = '$DryRun'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "Join the fleet placement controller (awrun fleet-join)"
            Script          = "32-onboarding/3214_Onboard-ClusterNode"
            Description     = "Delegates to 3268_Invoke-FleetMembership -Action join: mint (controller-side), install, approve, read back"
            Parameters      = @{
                NodeId     = '$NodeId'
                Controller = '$Controller'
                PinSha256  = '$PinSha256'
                Force      = '$Force'
                DryRun     = '$DryRun'
            }
            ContinueOnError = $false
        }
    )

    OnSuccess = @{
        Message = @"

+=================================================================+
|   NODE JOINED - approved by the fleet placement controller       |
+=================================================================+
|                                                                  |
|  VERIFY:                                                         |
|    3268_Invoke-FleetMembership.ps1 -Action status -Node <id>     |
|                                                                  |
+=================================================================+
"@
    }

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
|  The step printed the controller's verdict. COMMON ISSUES:       |
|    - node not in nodes.yaml / unreachable by the node transport  |
|    - aither-registry not running on the awnix host               |
|    - certificate pin mismatch -> re-measure, pass PinSha256      |
|    - already approved -> set Force to re-join                    |
+=================================================================+
"@
    }
}
