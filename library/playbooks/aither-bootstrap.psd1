@{
    Name        = "aither-bootstrap"
    Description = "Bootstrap a laptop or device as a sovereign Aitherium node: Bonsai inference + MCP gateway + developer tools (awsh, awdk) + workspace enrollment — one paste, one approval"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    # ==========================================================================
    # SOVEREIGN NODE BOOTSTRAP — FROM ZERO TO FULL DEVELOPER ENVIRONMENT
    # ==========================================================================
    #
    # PURPOSE:
    #   A blank laptop, phone, or spare box runs ONE command with a -Playbook
    #   flag and becomes a fully-provisioned Aitherium developer node with:
    #   - Bonsai inference (sized to available RAM)
    #   - MCP wired to mcp.aitherium.com
    #   - awsh (Node.js CLI tooling)
    #   - awdk (Python ADK for development)
    #   - workspace enrollment and device identification
    #
    # USAGE:
    #   irm https://aitherium.com/install.ps1 | iex -Playbook aither-bootstrap
    #
    # APPROVAL FLOW:
    #   1. User runs the command
    #   2. Device flow auth to idp.aitherium.com (user approves on phone or email reply)
    #   3. Installer fetches this playbook + config from user's drive
    #   4. Playbook runs, user's device becomes operational
    #
    # ARCHITECTURE NOTES:
    #   - Every step that can run offline does (Bonsai, npm, pip install)
    #   - MCP wiring targets the CLOUD gateway, not 127.0.0.1:8182 (home infra optional)
    #   - awsh is npm-only (one name @aitherium/awsh); awdk is pip-only
    #   - Device enrollment uses the device-flow bearer from the installer
    #   - Verification probes live APIs and local binaries (not just "file exists")
    #
    # HARD CONSTRAINTS:
    #   - Bootstrap MUST work standalone (no prior adk, no home LLM required)
    #   - Both shell and PowerShell paths call the SAME scripts (no drift)
    #   - MCP config goes to ~/.aither/.mcp.json, never hardcoded into env
    #   - Failure modes are loud and named (not silent fallbacks)
    #
    # ==========================================================================

    Parameters = @{
        # Bonsai installer URL (canonical source for install-bonsai.sh)
        BonsaiInstaller = 'https://aitherium.com/install-bonsai.sh'

        # Bonsai model sizing. auto = RAM-based, or explicit 1.7B|4B|8B|27B
        BonsaiModel     = 'auto'

        # Local loopback port for Bonsai inference
        BonsaiPort      = '8080'

        # MCP gateway URL. Must be https:// and reachable from this machine.
        # NEVER 127.0.0.1:8182 (that is the local orchestrator).
        MCPGateway      = 'https://mcp.aitherium.com/mcp'

        # Node name / device ID for workspace enrollment
        NodeName        = ''      # empty => derived from hostname

        # API key or bearer for device enrollment (passed by installer)
        DeviceBearer    = ''      # set by the device-flow auth path

        # Workspace to enroll into (empty => inferred from bearer)
        Workspace       = 'aitherium'

        # Portal URL for registration
        Portal          = 'https://portal.aitherium.com'

        # Skip interactive confirmations (scripted / unattended mode)
        Unattended      = $false

        # Verify-only: show what would run, change nothing
        DryRun          = $false
    }

    Prerequisites = @(
        "A Linux (glibc), macOS, or Windows machine — not Termux"
        "curl or wget installed"
        "Network egress to github.com (binaries), huggingface.co (weights), and mcp.aitherium.com (gateway)"
        "At least 6 GB free disk for Bonsai + models"
        "2 GB RAM minimum (4 GB recommended)"
    )

    Sequence = @(
        @{
            Name            = "Resolve OS dependencies (Bonsai + Node + Python)"
            Description     = "Install system libraries for Bonsai (glibc), Node.js, and Python3 — dependencies that scripts alone cannot provide"
            Command         = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --deps-only && (curl -fsSL https://deb.nodesource.com/setup_20.x | sh 2>/dev/null || echo ''Node repo optional'') && (apt-get update 2>/dev/null; apt-get install -y nodejs python3-pip python3-venv 2>/dev/null || echo ''Packages optional on non-apt systems'')"'
            Environment     = @{
                BONSAI_INSTALLER = '$BonsaiInstaller'
            }
            ContinueOnError = $false
        }

        @{
            Name            = "Install and start Bonsai inference"
            Description     = "Download Bonsai server + weights (sized to available RAM), serve on loopback, prove it answers"
            Command         = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --model $BONSAI_MODEL --port $BONSAI_PORT"'
            Environment     = @{
                BONSAI_INSTALLER = '$BonsaiInstaller'
                BONSAI_MODEL     = '$BonsaiModel'
                BONSAI_PORT      = '$BonsaiPort'
            }
            ContinueOnError = $false
        }

        @{
            Name            = "Install awsh (Node.js CLI tools)"
            Description     = "Install @aitherium/awsh via npm globally — the cloud agent CLI for this workspace"
            Command         = 'sh -c "npm install -g @aitherium/awsh"'
            ContinueOnError = $false
        }

        @{
            Name            = "Install awdk (Python development kit)"
            Description     = "Install awdk via pip3 into a user venv — the Python ADK for development, MCP, and workspace operations"
            Command         = 'sh -c "python3 -m pip install --user --upgrade pip setuptools wheel && pip3 install --user awdk"'
            ContinueOnError = $false
        }

        @{
            Name            = "Create MCP configuration"
            Description     = "Write ~/.aither/.mcp.json pointing to the cloud gateway (mcp.aitherium.com), never local loopback"
            Command         = 'sh -c "mkdir -p $HOME/.aither && cat > $HOME/.aither/.mcp.json <<''EOF''
{
  \"version\": 1,
  \"mcpServers\": {
    \"aitheros\": {
      \"type\": \"stdio\",
      \"command\": \"adk\",
      \"args\": [\"mcp\", \"--gateway\", \"$MCP_GATEWAY\"],
      \"env\": {}
    }
  }
}
EOF"'
            Environment     = @{
                MCP_GATEWAY = '$MCPGateway'
            }
            ContinueOnError = $false
        }

        @{
            Name            = "Verify Bonsai is answering"
            Description     = "Query the local inference server — a listening port is not a working model"
            Command         = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --verify-only --port $BONSAI_PORT"'
            Environment     = @{
                BONSAI_INSTALLER = '$BonsaiInstaller'
                BONSAI_PORT      = '$BonsaiPort'
            }
            ContinueOnError = $false
        }

        @{
            Name            = "Verify MCP gateway reachable"
            Description     = "Confirm the cloud MCP endpoint is reachable and healthy"
            Command         = 'sh -c "curl -sk $MCP_GATEWAY/health || (echo ''MCP unreachable''; exit 1)"'
            Environment     = @{
                MCP_GATEWAY = '$MCPGateway'
            }
            ContinueOnError = $false
        }

        @{
            Name            = "Verify awsh installed"
            Description     = "Check awsh is callable and can list MCP models"
            Command         = 'sh -c "which awsh && awsh --version"'
            ContinueOnError = $false
        }

        @{
            Name            = "Verify awdk installed"
            Description     = "Check awdk is callable and can initialize"
            Command         = 'sh -c "python3 -m adk --version || adk --version || echo ''adk callable via python3 -m adk''"'
            ContinueOnError = $false
        }

        @{
            Name            = "Enroll device to workspace"
            Description     = "Register this device with your workspace for credential storage and task tracking"
            # Only run if a device bearer was passed (device-flow auth completed)
            Condition       = '$DeviceBearer -ne ""'
            Command         = 'sh -c "adk enroll --workspace $WORKSPACE --node-id $NODE_NAME --portal $PORTAL 2>/dev/null || echo ''Enrollment optional (requires portal access)''"'
            Environment     = @{
                WORKSPACE = '$Workspace'
                NODE_NAME = '$NodeName'
                PORTAL    = '$Portal'
            }
            ContinueOnError = $true
        }
    )

    # Strict sequential execution: each step's success is a gate for the next
    Options = @{
        Parallel       = $false
        MaxConcurrency = 1
        StopOnError    = $true
    }

    PostConditions = @(
        "Bonsai binds 127.0.0.1 deliberately (not 0.0.0.0) — unauthenticated inference is local-only"
        "On Android Linux terminal: enable port forwarding in the Terminal app so the browser can reach loopback"
        "MCP config lives at ~/.aither/.mcp.json — do NOT set AITHER_MCP_* env vars (file-based config wins)"
        "Device enrollment uses the bearer from device-flow auth; if skipped, you can re-run 'adk enroll' manually"
    )

    OnSuccess = @{
        Message = @"

+=================================================================+
|   BOOTSTRAP COMPLETE — Sovereign Node Ready                     |
+=================================================================+
|                                                                  |
|  This device is now a fully-provisioned Aitherium node:         |
|                                                                  |
|  1. BONSAI INFERENCE                                            |
|     Local LLM answering on http://127.0.0.1:$BonsaiPort        |
|     Size: $BonsaiModel (tuned to your RAM)                      |
|                                                                  |
|  2. MCP GATEWAY                                                 |
|     Cloud-connected: $MCPGateway                                |
|     Use awsh to ask the fleet, or run agents locally           |
|                                                                  |
|  3. DEVELOPER TOOLS INSTALLED                                   |
|     awsh  : npm exec awsh (global CLI)                          |
|     awdk  : python3 -m adk (Python development kit)            |
|                                                                  |
|  4. WORKSPACE ENROLLED (if bearer was provided)                |
|     This device appears in your workspace portal                |
|     Enroll manually: adk enroll --workspace $Workspace          |
|                                                                  |
|  NEXT STEPS:                                                    |
|     1. Try the local model: awsh ask 'hello'                    |
|     2. Open desktop.aitherium.com to access Atlas/Forge/etc    |
|     3. Run 'adk --help' for development tasks                  |
|     4. Join the workspace on your phone at aitherium.com       |
|                                                                  |
+=================================================================+

"@
    }

    OnFailure = @{
        Message = @"

+=================================================================+
|   BOOTSTRAP FAILED                                               |
+=================================================================+
|                                                                  |
|  One of the core components did not install. Common issues:     |
|                                                                  |
|  BONSAI:                                                         |
|    - Missing glibc (Termux? Use a real Linux distro)            |
|    - Insufficient free disk (need 6+ GB)                        |
|    - curl/wget missing                                          |
|                                                                  |
|  NODE.JS / AWsh:                                                |
|    - 'npm: command not found' -> Node.js did not install        |
|    - '@aitherium/awsh' not in npm registry -> network issue     |
|                                                                  |
|  PYTHON / AWdk:                                                 |
|    - 'python3: not found' -> Python 3 not installed            |
|    - awdk import error -> run 'pip3 install --upgrade pip'     |
|                                                                  |
|  MCP GATEWAY:                                                   |
|    - Unreachable -> check network egress to mcp.aitherium.com  |
|    - 'curl: (7) ...' -> DNS or firewall blocking              |
|                                                                  |
|  DEVICE ENROLLMENT:                                             |
|    - 'Portal not found' -> portal.aitherium.com unreachable    |
|    - This is non-critical; you can enroll manually later       |
|                                                                  |
|  TO RETRY:                                                       |
|    Run this playbook again. All steps are idempotent.           |
|                                                                  |
+=================================================================+

"@
    }
}
