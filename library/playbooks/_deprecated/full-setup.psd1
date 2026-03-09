# Master deployment playbook for AitherZero with all AI infrastructure
#
# This is the ONE playbook to rule them all. Running this will:
#   1. Set up the base environment (directories, config, git hooks)
#   2. Install all prerequisites (Python, Node, Git, etc.)
#   3. Install AI infrastructure (Ollama, ComfyUI)
#   4. Set up all agents (Narrative, Infrastructure, Automation)
#   5. Configure and start services
#   6. Generate the dashboard
#
# All scripts are IDEMPOTENT - running this multiple times is safe.
#
# Usage:
#   ./bootstrap.ps1 -InstallProfile Full           # Via bootstrap
#   Invoke-AitherPlaybook -Name full-setup         # Via playbook
#   ./Start-AitherZero.ps1 -Playbook full-setup    # Via launcher

@{
    Name        = "full-setup"
    Description = "Complete AitherZero deployment: Prerequisites → AI Infrastructure → Agents → Dashboard"
    Version     = "2.0.0"
    Author      = "Aitherium"
    Tags        = @("setup", "deployment", "full", "ai", "agents", "dashboard")

    # =========================================================================
    # CONFIGURATION
    # =========================================================================
    Options = @{
        Parallel        = $false    # Sequential for dependency safety
        StopOnError     = $false    # Continue to see all failures
        CaptureOutput   = $true
        MaxConcurrency  = 1
    }

    # Variables available to all scripts
    Variables = @{
        Profile     = "Full"
        Interactive = $false
    }

    # =========================================================================
    # EXECUTION SEQUENCE
    # =========================================================================
    Sequence = @(

        # =====================================================================
        # PHASE 1: ENVIRONMENT SETUP (0000-0099)
        # =====================================================================
        @{
            Script          = "0001"
            Description     = "Configure base environment variables"
            ContinueOnError = $true
            Phase           = "Environment"
        },
        @{
            Script          = "0002"
            Description     = "Create required directory structure"
            ContinueOnError = $false
            Phase           = "Environment"
        },
        @{
            Script          = "0003"
            Description     = "Sync configuration manifest"
            ContinueOnError = $true
            Phase           = "Environment"
        },
        @{
            Script          = "0004"
            Description     = "Install Git hooks for development"
            ContinueOnError = $true
            Phase           = "Environment"
        },

        # =====================================================================
        # PHASE 2: CORE PREREQUISITES (0200-0299)
        # =====================================================================
        @{
            Script          = "0207"
            Description     = "Install Git (version control)"
            ContinueOnError = $false
            Phase           = "Prerequisites"
        },
        @{
            Script          = "0206"
            Description     = "Install Python 3.12+"
            ContinueOnError = $false
            Phase           = "Prerequisites"
        },
        @{
            Script          = "0201"
            Description     = "Install Node.js (for web dashboard)"
            ContinueOnError = $true
            Phase           = "Prerequisites"
        },
        @{
            Script          = "0211"
            Description     = "Install GitHub CLI"
            ContinueOnError = $true
            Phase           = "Prerequisites"
        },

        # =====================================================================
        # PHASE 3: AI INFRASTRUCTURE (0700-0799)
        # =====================================================================
        @{
            Script          = "0740"
            Description     = "Install Ollama (local LLM runtime)"
            ContinueOnError = $true
            Phase           = "AI-Infrastructure"
            Params          = @{
                Model = "mistral-nemo"
            }
        },
        @{
            Script          = "0730"
            Description     = "Install ComfyUI (image generation)"
            ContinueOnError = $true
            Phase           = "AI-Infrastructure"
            Params          = @{
                InstallPath = "~/ComfyUI"
            }
        },
        @{
            Script          = "0731"
            Description     = "Download ComfyUI models (Flux)"
            ContinueOnError = $true
            Phase           = "AI-Infrastructure"
            Params          = @{
                InstallPath = "~/ComfyUI"
                ModelSet    = "Flux"
            }
        },

        # =====================================================================
        # PHASE 4: AGENT SETUP (0750-0799)
        # =====================================================================
        @{
            Script          = "0225"
            Description     = "Install Google ADK (agent framework)"
            ContinueOnError = $false
            Phase           = "Agents"
        },
        @{
            Script          = "0752"
            Description     = "Setup NarrativeAgent virtual environment"
            ContinueOnError = $false
            Phase           = "Agents"
            Params          = @{
                Path = "AitherOS/agents/NarrativeAgent"
            }
        },
        @{
            Script          = "0752"
            Description     = "Setup InfrastructureAgent virtual environment"
            ContinueOnError = $false
            Phase           = "Agents"
            Params          = @{
                Path = "AitherOS/agents/InfrastructureAgent"
            }
        },
        @{
            Script          = "0752"
            Description     = "Setup AitherZeroAutomationAgent virtual environment"
            ContinueOnError = $false
            Phase           = "Agents"
            Params          = @{
                Path = "AitherOS/agents/AitherZeroAutomationAgent"
            }
        },

        # =====================================================================
        # PHASE 5: MCP & SERVICES (0760-0799)
        # =====================================================================
        @{
            Script          = "0760"
            Description     = "Install Filesystem MCP server"
            ContinueOnError = $true
            Phase           = "Services"
            Params          = @{
                AllowedPaths = @(".")
            }
        },
        @{
            Script          = "0761"
            Description     = "Setup AitherNode (MCP orchestrator)"
            ContinueOnError = $true
            Phase           = "Services"
        },

        # =====================================================================
        # PHASE 6: VALIDATION & DASHBOARD (0400-0599)
        # =====================================================================
        @{
            Script          = "0005"
            Description     = "Validate environment setup"
            ContinueOnError = $true
            Phase           = "Validation"
        },
        @{
            Script          = "0510"
            Description     = "Generate project report"
            ContinueOnError = $true
            Phase           = "Dashboard"
            Params          = @{
                Format = "All"
            }
        },
        @{
            Script          = "0520"
            Description     = "Start Web Dashboard with Pulse"
            ContinueOnError = $true
            Phase           = "Dashboard"
            Params          = @{
                WithPulse = $true
            }
        }
    )

    # =========================================================================
    # METADATA
    # =========================================================================
    Metadata = @{
        Created           = "2025-11-28"
        EstimatedDuration = "15-30 minutes (depending on downloads)"
        RequiresAdmin     = $false
        RequiresInternet  = $true
        Phases            = @(
            "Environment",
            "Prerequisites",
            "AI-Infrastructure",
            "Agents",
            "Services",
            "Validation",
            "Dashboard"
        )
    }

    # =========================================================================
    # POST-EXECUTION
    # =========================================================================
    PostExecution = @{
        ShowSummary = $true
        Commands    = @()
    }
}
