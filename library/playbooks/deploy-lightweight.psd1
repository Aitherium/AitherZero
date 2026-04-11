@{
    # =========================================================================
    # AITHEROS LIGHTWEIGHT NODE DEPLOYMENT PLAYBOOK
    # =========================================================================
    # Deploy a lightweight AitherNode without the full stack.
    # Three options: ADK (pip), Node (Docker), Edge (standalone Python)
    #
    # Usage:
    #   Invoke-AitherPlaybook deploy-lightweight
    #   Invoke-AitherPlaybook deploy-lightweight -Variables @{ Target = "adk" }
    #   Invoke-AitherPlaybook deploy-lightweight -Variables @{ Target = "edge"; TargetHost = "pi.local" }
    # =========================================================================

    Name        = "deploy-lightweight"
    Description = "Deploy a lightweight AitherNode — ADK (pip), Docker node, or standalone EdgeNodeService"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    Parameters = @{
        # Deployment target
        Target         = 'node'     # adk | node | edge
        TargetHost     = ''         # Remote host (SSH) — empty for local
        UserName       = ''
        IdentityFile   = ''

        # Node config
        Port           = 8080
        Identity       = 'genesis'
        OllamaUrl      = 'http://localhost:11434'
        MeshKey        = ''
        ControllerUrl  = ''

        DryRun         = $false
    }

    Prerequisites = @(
        "adk:  Python 3.10+, pip"
        "node: Docker or Podman"
        "edge: Python 3.10+, Ollama (recommended)"
    )

    Sequence = @(
        # =====================================================================
        # STEP 1: DEPLOY NODE
        # =====================================================================
        @{
            Name            = "Deploy Lightweight Node"
            Script          = "30-deploy/3061_Deploy-LightweightNode"
            Description     = "Install ADK / start Node container / deploy EdgeNodeService"
            Parameters      = @{
                Target        = '$Target'
                TargetHost    = '$TargetHost'
                UserName      = '$UserName'
                IdentityFile  = '$IdentityFile'
                Port          = '$Port'
                Identity      = '$Identity'
                OllamaUrl     = '$OllamaUrl'
                MeshKey       = '$MeshKey'
                ControllerUrl = '$ControllerUrl'
                DryRun        = '$DryRun'
            }
            ContinueOnError = $false
        }
    )

    OnSuccess = @{
        Message = @"

=====================================================================
  LIGHTWEIGHT NODE DEPLOYED
=====================================================================

  Your AitherNode is ready.

  Endpoints:
    Health:    http://localhost:8080/health
    Discovery: http://localhost:8080/.well-known/aitheros

  ADK commands:
    adk-serve --identity genesis --port 8080
    adk-serve --agents aither,lyra,demiurge --port 8080

  Connect from browser:
    Load AitherConnect extension -> click Discover

"@
    }

    OnFailure = @{
        Message = @"

=====================================================================
  LIGHTWEIGHT NODE DEPLOYMENT FAILED
=====================================================================

  Common fixes:
    adk:  Verify Python 3.10+ and pip are installed
    node: Verify Docker is running (docker info)
    edge: Verify Ollama is reachable (curl http://localhost:11434/api/tags)

"@
    }
}
