<div align="center">

# ⚡ AitherZero

**The automation backbone for the Aitherium ecosystem**

[![CI](https://github.com/aitherium/aitherzero/actions/workflows/ci.yml/badge.svg)](https://github.com/aitherium/aitherzero/actions/workflows/ci.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7.0%2B-blue?style=flat-square&logo=powershell)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/license-Apache%202.0-green?style=flat-square)](LICENSE)

Set up your environment, install dependencies, configure AI tooling, and manage
the [Aitherium](https://github.com/Aitherium) product suite — all from one framework.

[Quick Start](#quick-start) · [Ecosystem Setup](#setting-up-the-aitherium-ecosystem) · [Automation Scripts](#automation-scripts) · [MCP Integration](#connect-to-your-ai-assistant-mcp) · [Contributing](CONTRIBUTING.md)

</div>

---

## What is AitherZero?

AitherZero is a **PowerShell 7+ automation framework** designed to get you up and running with the Aitherium ecosystem. It is **not** a deployment tool for a monolithic backend — it's the setup and orchestration layer that helps you install, configure, and manage:

| Product | What it is | Install with AitherZero |
|---------|-----------|------------------------|
| [**AitherNode**](https://github.com/Aitherium/aither) | Lightweight MCP compute node — 30+ AI tools, runs standalone or mesh-connected | `Invoke-AitherScript 0762` |
| [**AitherADK**](https://github.com/Aitherium/aither/tree/main/aither-adk) | Agent Development Kit — `pip install aither-adk`, build agents in 3 lines | `Invoke-AitherScript 0225` |
| [**AitherDesktop**](https://github.com/Aitherium) | Native desktop client (Windows/Linux) with MCP, watchdog, and home widget | `Invoke-AitherPlaybook desktop-setup` |
| [**AitherConnect**](https://github.com/Aitherium) | Browser extension (Chrome/Edge) — connects to any AitherNode instance | `Invoke-AitherPlaybook connect-setup` |
| [**AitherSDK**](https://github.com/Aitherium/aithersdk) | Python client library — `pip install aithersdk` | Auto-installed with ADK |
| [**AitherVeil**](https://github.com/Aitherium) | Next.js operator dashboard — monitoring, chat, agent management | `Invoke-AitherPlaybook veil-setup` |

Beyond ecosystem setup, AitherZero is a general-purpose automation framework you can use for your own projects: CI/CD pipelines, infrastructure provisioning, dev environment setup, and more.

---

## Quick Start

### Prerequisites

- **PowerShell 7.4+** — [Install](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- **Git**
- **Python 3.10+** (for AI features)
- **Docker** (optional, for container features)

### Install

```bash
git clone https://github.com/Aitherium/AitherZero.git
cd AitherZero
```

```powershell
# Bootstrap the environment
./bootstrap.ps1 -Mode New -InstallProfile Minimal -NonInteractive

# Import the module
Import-Module ./AitherZero.psd1 -Force

# Verify
Get-AitherStatus
```

### Your First Commands

```powershell
# System fingerprint — see what hardware/software you have
Invoke-AitherScript 0011

# Run the quick test suite
./bootstrap.ps1 -Playbook test-quick

# List all available scripts
Get-AitherScript | Format-Table Number, Name, Category
```

---

## Setting Up the Aitherium Ecosystem

### Option 1: AitherNode + AitherADK (Recommended Start)

Get a local AI compute node with 30+ MCP tools and the agent SDK:

```powershell
# Install Python, Node.js, and AI dependencies
./bootstrap.ps1 -Playbook dev-environment

# Start AitherNode (MCP server)
Invoke-AitherScript 0762

# Install AitherADK
pip install aither-adk
```

Now build an agent:

```python
from adk import AitherAgent

agent = AitherAgent("my-agent")  # Auto-detects Ollama on localhost
response = await agent.chat("Hello!")
print(response.content)
```

### Option 2: Full Dev Environment

Set up everything for Aitherium development — Python, Node.js, Docker, Ollama, and tooling:

```powershell
./bootstrap.ps1 -Playbook dev-environment
```

This automatically:
1. Detects your hardware (GPU, CPU, RAM)
2. Installs Python 3.11+, Node.js 20+, Docker
3. Sets up Ollama with optimal models for your hardware tier
4. Configures AitherNode as your local MCP server

### Option 3: Just the Framework

Use AitherZero purely as an automation framework for your own projects:

```powershell
./bootstrap.ps1 -Mode New -InstallProfile Minimal -NonInteractive
```

No AI dependencies — just the PowerShell module, config system, script engine, and playbook orchestrator.

---

## Connect to Your AI Assistant (MCP)

AitherZero exposes 25+ tools to AI coding assistants via the [Model Context Protocol](https://modelcontextprotocol.io):

```json
{
  "servers": {
    "aitherzero": {
      "command": "node",
      "args": ["./library/integrations/mcp-server/dist/index.js"],
      "env": {
        "AITHERZERO_ROOT": "/path/to/AitherZero"
      }
    }
  }
}
```

Your AI assistant can then: run automation scripts, execute playbooks, query configuration, manage git workflows, and orchestrate deployments — all through natural language.

Works with **GitHub Copilot**, **Claude**, **Cursor**, and any MCP-compatible client.

---

## Configuration

AitherZero is entirely **config-driven**. Override defaults with a local file:

```powershell
# config/config.local.psd1  (gitignored — safe for secrets and local prefs)
@{
    Core = @{
        NonInteractive = $true
    }
    Features = @{
        Development = @{
            Python = @{ Enabled = $true }
            Node   = @{ Enabled = $true }
            Docker = @{ Enabled = $true }
        }
        AI = @{
            Ollama  = @{ Enabled = $true }
            ComfyUI = @{ Enabled = $false }
        }
    }
}
```

### Config Hierarchy

```
Command-line Parameters     (highest priority)
    ↓
Environment Variables       (AITHERZERO_*)
    ↓
config.local.psd1           (user overrides, gitignored)
    ↓
config.{os}.psd1            (OS-specific)
    ↓
config.psd1                 (master defaults)
```

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `AITHERZERO_NONINTERACTIVE=1` | Skip all prompts |
| `AITHEROS_SKIP_OLLAMA=1` | Skip Ollama/model setup |
| `AITHEROS_SKIP_VEIL=1` | Skip Veil dashboard build |

---

## Automation Scripts

178+ numbered scripts organized by category:

| Range | Category | Examples |
|-------|----------|----------|
| 0000–0099 | Environment Setup | `0011_Get-SystemInfo.ps1`, `0014_Initialize-Environment.ps1` |
| 0100–0199 | Infrastructure | `0105_Install-HyperV.ps1` |
| 0200–0299 | Dev Tools | `0207_Install-Git.ps1`, `0225_Install-GoogleADK.ps1` |
| 0400–0499 | Testing & Quality | `0402_Run-UnitTests.ps1`, `0404_Run-PSScriptAnalyzer.ps1` |
| 0500–0599 | Reporting | `0510_Generate-ProjectReport.ps1` |
| 0600–0699 | Security | `0601_Manage-Secrets.ps1`, `0602_Generate-SSHKeys.ps1` |
| 0700–0799 | Git / AI / Agents | `0707_Setup-GitHubRunner.ps1`, `0762_Start-AitherNode.ps1` |
| 0800–0899 | Service Ops | `0800_Start-AitherOS.ps1`, `0801_Stop-AitherOS.ps1` |
| 0900–0999 | Validation | `0906_Validate-Syntax.ps1` |

### Key Scripts

| Script | What it does |
|--------|-------------|
| `0011` | System fingerprint (hardware, GPU, RAM, installed runtimes) |
| `0014` | Initialize AitherZero environment |
| `0207` | Install Git |
| `0225` | Install Google ADK / AitherADK |
| `0402` | Run Pester unit tests |
| `0404` | Run PSScriptAnalyzer linting |
| `0510` | Generate project report |
| `0762` | Start AitherNode (MCP server) |
| `0906` | Validate PowerShell syntax |

```powershell
# Run by number
Invoke-AitherScript 0011

# Or directly
pwsh -File ./library/automation-scripts/0011_Get-SystemInfo.ps1 -ShowOutput
```

---

## Playbooks

Chain scripts into declarative workflows:

```powershell
# library/playbooks/my-playbook.psd1
@{
    Name = 'my-playbook'
    Description = 'My custom workflow'
    Steps = @(
        @{ Script = '0906'; Description = 'Validate syntax'; OnFailure = 'Stop' }
        @{ Script = '0402'; Description = 'Run tests'; OnFailure = 'Continue' }
    )
}
```

```powershell
./bootstrap.ps1 -Playbook my-playbook
```

### Built-in Playbooks

| Playbook | Description |
|----------|-------------|
| `dev-environment` | Full dev setup (Python, Node, Docker, Ollama) |
| `test-quick` | Quick validation (syntax + unit tests) |
| `ci-pr-validation` | CI/CD validation pipeline |
| `build` | Build container images |
| `deploy-local` | Deploy via Docker Compose |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   Your AI Assistant                       │
│           (Copilot / Claude / Cursor / etc.)              │
├──────────────────────┬───────────────────────────────────┤
│    MCP Protocol      │       Direct CLI                  │
├──────────────────────┴───────────────────────────────────┤
│                   AitherZero Core                         │
│  ┌──────────┐ ┌───────────┐ ┌────────┐ ┌─────────────┐  │
│  │ Config   │ │ Playbook  │ │ Script │ │ Logging &   │  │
│  │ System   │ │ Orchestr. │ │ Engine │ │ Metrics     │  │
│  └──────────┘ └───────────┘ └────────┘ └─────────────┘  │
├──────────────────────────────────────────────────────────┤
│                   Plugin Layer                            │
│  ┌──────────┐ ┌───────────┐ ┌────────┐ ┌─────────────┐  │
│  │ OpenTofu │ │ Docker    │ │ Cloud  │ │ Your        │  │
│  │ Modules  │ │ Deploy    │ │ Provid.│ │ Plugin      │  │
│  └──────────┘ └───────────┘ └────────┘ └─────────────┘  │
├──────────────────────────────────────────────────────────┤
│              Aitherium Ecosystem                          │
│  AitherNode · AitherADK · AitherDesktop · AitherConnect  │
│  AitherVeil · AitherSDK · Ollama · vLLM                  │
└──────────────────────────────────────────────────────────┘
```

### Directory Structure

```
AitherZero/
├── AitherZero.psd1              # Module manifest
├── AitherZero.psm1              # Module loader
├── build.ps1                    # Build script
├── src/
│   ├── public/                  # Exported functions (by domain)
│   │   ├── AI/                  # Agent management
│   │   ├── Configuration/       # Config management
│   │   ├── Deployment/          # Deployment tools
│   │   ├── Execution/           # Script execution
│   │   ├── Integrations/        # External integrations
│   │   ├── Logging/             # Structured logging
│   │   ├── Orchestration/       # Playbook orchestration
│   │   ├── Security/            # Secrets, SSH keys
│   │   ├── System/              # System utilities
│   │   └── Testing/             # Test utilities
│   └── private/                 # Internal functions
├── library/
│   ├── automation-scripts/      # 178+ numbered scripts
│   ├── playbooks/               # Orchestration playbooks
│   ├── integrations/mcp-server/ # MCP server for AI assistants
│   └── templates/               # Script templates
├── config/
│   ├── config.psd1              # Master configuration
│   ├── config.local.psd1        # Local overrides (gitignored)
│   ├── config.windows.psd1      # Windows-specific
│   ├── config.linux.psd1        # Linux-specific
│   └── config.macos.psd1        # macOS-specific
├── plugins/                     # Extend with your own automation
└── tests/
    ├── Unit/
    └── Integration/
```

---

## Plugins

Extend AitherZero with project-specific automation:

```powershell
New-AitherPlugin -Name 'my-webapp' -Description 'Deploy my web app'
Register-AitherPlugin -Path ./plugins/my-webapp
```

Plugins can add scripts, functions, playbooks, config overlays, and infrastructure modules. See `plugins/_template/` for the starter structure.

---

## Development

### Adding a Function

```powershell
# src/public/MyDomain/My-Function.ps1
function My-Function {
    [CmdletBinding()]
    param([string]$Parameter)
    # Implementation
}
```

Export it in `AitherZero.psd1`:

```powershell
FunctionsToExport = @('My-Function', ...)
```

### Running Tests

```powershell
# Unit tests
Invoke-AitherScript 0402

# PSScriptAnalyzer
Invoke-AitherScript 0404

# Syntax validation
pwsh -File ./library/automation-scripts/0906_Validate-Syntax.ps1 -All
```

---

## Aitherium Ecosystem

| Repo | Description |
|------|-------------|
| [**aither**](https://github.com/Aitherium/aither) | AitherOS — agentic operating system, AitherADK, agent identities |
| [**AitherZero**](https://github.com/Aitherium/AitherZero) | This repo — automation framework |
| [**aithersdk**](https://github.com/Aitherium/aithersdk) | Python SDK — `pip install aithersdk` |
| [**aitherkvcache**](https://github.com/Aitherium/aitherkvcache) | KV cache quantization for LLM inference |

---

## License

[Apache License 2.0](LICENSE) — use it however you want, commercial or personal.

## Built by [Aitherium](https://aitherium.com)

AitherZero was extracted from the automation backbone of [AitherOS](https://github.com/Aitherium/aither), an agentic operating system. It's been battle-tested deploying complex distributed systems.

---

<div align="center">

⭐ **Star this repo** if you find it useful · 🔌 **Build a plugin** and share it · 💬 [GitHub Discussions](https://github.com/aitherium/aitherzero/discussions)

</div>
