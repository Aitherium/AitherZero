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
| [**AitherNode**](https://github.com/Aitherium/aither) | Lightweight MCP compute node — 30+ AI tools, runs standalone or mesh-connected | `Invoke-AitherScript 0402` |
| [**AitherADK**](https://github.com/Aitherium/aither/tree/main/aither-adk) | Agent Development Kit — build agents in 3 lines | `pip install aither-adk` |
| [**AitherDesktop**](https://github.com/Aitherium) | Native desktop client (Windows/Linux) with MCP, watchdog, and home widget | `Invoke-AitherPlaybook node-onboard` |
| [**AitherConnect**](https://github.com/Aitherium) | Browser extension (Chrome/Edge) — connects to any AitherNode instance | `Invoke-AitherPlaybook node-onboard` |
| [**AitherSDK**](https://github.com/Aitherium/aithersdk) | Python client library — `pip install aithersdk` | Auto-installed with ADK |
| [**AitherVeil**](https://github.com/Aitherium) | Next.js operator dashboard — monitoring, chat, agent management | `Invoke-AitherPlaybook node-onboard` |

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
# Build the module (generates AitherZero.psd1 — it is not committed)
./build.ps1

# Import the module
Import-Module ./AitherZero.psd1 -Force

# Verify
Get-AitherStatus
```

### Your First Commands

```powershell
# System fingerprint — see what hardware/software you have
Invoke-AitherScript 1002

# Run the quick test suite
Invoke-AitherPlaybook node-onboard

# List all available scripts
Get-AitherScript | Format-Table Number, Name, Category
```

---

## Setting Up the Aitherium Ecosystem

### Option 1: AitherNode + AitherADK (Recommended Start)

Get a local AI compute node with 30+ MCP tools and the agent SDK:

```powershell
# Install Python, Node.js, and AI dependencies
Invoke-AitherPlaybook node-onboard

# Start AitherNode (MCP server)
Invoke-AitherScript 0402

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
Invoke-AitherPlaybook node-onboard
```

This automatically:
1. Detects your hardware (GPU, CPU, RAM)
2. Installs Python 3.11+, Node.js 20+, Docker
3. Sets up Ollama with optimal models for your hardware tier
4. Configures AitherNode as your local MCP server

### Option 3: Just the Framework

Use AitherZero purely as an automation framework for your own projects:

```powershell
./build.ps1
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

71 numbered scripts organized by category:

| Range | Category | Examples |
|-------|----------|----------|
| 0402–8010 | Testing | `0402_Run-UnitTests.ps1`, `0403_Run-IntegrationTests.ps1` |
| 0650–6052 | Monitoring | `0650_Sync-Observability.ps1`, `0751_Generate-SLOReport.ps1` |
| 0701–0898 | Git | `0701_New-Branch.ps1`, `0702_Commit-Changes.ps1` |
| 0720–0741 | Ai Tools | `0720_Install-StableDiffusionWebUI.ps1`, `0721_Configure-SDWebUI-Models.ps1` |
| 0769–1033 | Devtools | `0769_Setup-WebDeveloperToolkit.ps1`, `1001_Install-Chocolatey.ps1` |
| 3214 | Onboarding | `3214_Onboard-ClusterNode.ps1` |
| 7001–9020 | Maintenance | `7001_Cleanup-Docker.ps1`, `7002_Validate-Environment.ps1` |
| 7010–7051 | External Integrations | `7010_Setup-ProtonBridge.ps1`, `7012_Setup-Slack.ps1` |

### Key Scripts

| Script | What it does |
|--------|-------------|
| `0402` | Run UnitTests |
| `0403` | Run IntegrationTests |
| `0404` | Run PSScriptAnalyzer |
| `0405` | Run PythonTest |
| `0410` | Audit OpenSourceReadiness |
| `0650` | Sync Observability |
| `0701` | New Branch |
| `0702` | Commit Changes |
| `0703` | Create PullRequest |
| `0704` | Switch GitHubAccount |

```powershell
# Run by number
Invoke-AitherScript 1002

# Or directly
pwsh -File ./library/automation-scripts/10-devtools/1002_Install-Git.ps1
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
        @{ Script = '0404'; Description = 'Run PSScriptAnalyzer'; OnFailure = 'Stop' }
        @{ Script = '0402'; Description = 'Run tests'; OnFailure = 'Continue' }
    )
}
```

```powershell
Invoke-AitherPlaybook node-onboard
```

### Built-in Playbooks

| Playbook | Description |
|----------|-------------|
| `node-onboard` | Onboard THIS machine as a secure AitherOS cluster node (Windows / Linux / macOS) |

Run `Get-AitherPlaybook` to list what your checkout actually ships — additional
playbooks (build, deploy, CI) are part of the AitherOS Enterprise distribution
and are not included in the public release.

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
pwsh -File ./library/automation-scripts/80-testing/0404_Run-PSScriptAnalyzer.ps1
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

<!-- aitherium-ecosystem:start -->
## Aitherium open-source ecosystem

This repo is one piece of a connected set. All public, MIT/BSL-licensed:

| repo | what it is | pages |
|---|---|---|
| [awrecover](https://github.com/Aitherium/awrecover) | Labelled snapshots with an all-or-nothing restore | [docs](https://aitherium.github.io/awrecover/) |
| [awshare](https://github.com/Aitherium/awshare) | Publish an artifact and fetch it back verified | [docs](https://aitherium.github.io/awshare/) |
| [awseal](https://github.com/Aitherium/awseal) | Sign an artifact so a stranger can verify it | [docs](https://aitherium.github.io/awseal/) |
| [awnode](https://github.com/Aitherium/awnode) | Lightweight local gateway — your apps to backends you chose | [docs](https://aitherium.github.io/awnode/) |
| [awnix](https://github.com/Aitherium/awnix) | A bootable, immutable Linux base for agent-run machines | [docs](https://aitherium.github.io/awnix/) |
| [awdk](https://github.com/Aitherium/awdk) | Build AI agent fleets — 3 lines, any backend | [docs](https://aitherium.github.io/awdk/) |
| [awskills](https://github.com/Aitherium/awskills) | Free agent skills, scripts & automations | [docs](https://aitherium.github.io/awskills/) |
| [AitherZero](https://github.com/Aitherium/AitherZero) | PowerShell 7+ automation framework | [docs](https://aitherium.github.io/AitherZero/) |
| [awgit](https://github.com/Aitherium/awgit) | Semantic version control on top of git | [docs](https://aitherium.github.io/awgit/) |
| [awgraph](https://github.com/Aitherium/awgraph) | Code knowledge graph for AI agents | [docs](https://aitherium.github.io/awgraph/) |
| [aitherkvcache](https://github.com/Aitherium/aitherkvcache) | Near-optimal KV cache quantization | [docs](https://aitherium.github.io/aitherkvcache/) |
| [awrelay](https://github.com/Aitherium/awrelay) | Agent-to-agent messaging over any chat server | [docs](https://aitherium.github.io/awrelay/) |
| [awm](https://github.com/Aitherium/awm) | A small world model (LeWM JEPA + MLP) to bootstrap your own | [docs](https://aitherium.github.io/awm/) |
| [AitherConnect](https://github.com/Aitherium/AitherConnect) | Browser extension: federated AI search & desktop bridge | — |
| [homebrew-tap](https://github.com/Aitherium/homebrew-tap) | `brew tap aitherium/tap` | — |

Built by [Aitherium](https://aitherium.com).
<!-- aitherium-ecosystem:end -->

<!-- aither-ecosystem:start GENERATED from the ecosystem registry. Edits here are overwritten; change the registry instead. -->

## The aw family

Standalone tools that share one idea: **replace something you would otherwise have to _trust_ with something you can _check_.**

Each installs on its own, works offline, and needs no account.

| | instead of trusting | you check |
|---|---|---|
| [awdk](https://github.com/Aitherium/awdk) | a framework's idea of how your agents should run | one loop you can read, pointed at a backend you already pay for |
| [awskills](https://github.com/Aitherium/awskills) | that an agent knows your procedure | the procedure written down, versioned, and loadable by any agent |
| [awm](https://github.com/Aitherium/awm) | that memory stayed in its lane | tenant:user:project scopes, so a write cannot cross a boundary |
| [awnode](https://github.com/Aitherium/awnode) | a vendor's cloud with every prompt | a local gateway routing to backends you chose |
| [awgraph](https://github.com/Aitherium/awgraph) | that grep found everything | an AST + tree-sitter call graph an agent can traverse |
| [awgit](https://github.com/Aitherium/awgit) | that no one else is editing this file | a lease, refused at commit time if you do not hold it |
| [awseal](https://github.com/Aitherium/awseal) | that the artifact came from who you think | an Ed25519 seal — the key that verifies is not the key that forges |
| [awshare](https://github.com/Aitherium/awshare) | that the download is intact | content-addressed bundles, verified on fetch |
| [awnest](https://github.com/Aitherium/awnest) | that there is a person on the other end | a verdict with evidence, where "we could not tell" is not "yes" |
| [awnboard](https://github.com/Aitherium/awnboard) | a share link anyone who sees it can use | an invitation addressed to one person, for one gate, revocable |
| [awnix](https://github.com/Aitherium/awnix) | that the box is what you left it as | an immutable image you built, with atomic rollback |
| [awrecover](https://github.com/Aitherium/awrecover) | that the restore worked | a restore that fully lands or does not land at all |
| [awrelay](https://github.com/Aitherium/awrelay) | a SaaS in the middle of your agents | findings, alerts and coordination over your own transport |
| [awmail](https://github.com/Aitherium/awmail) | a mailbox somebody else can read | mail your agents send and receive over your own server |
| [awfind](https://github.com/Aitherium/awfind) | one vendor's idea of the web | results from whichever providers you configured |
| [awbrowse](https://github.com/Aitherium/awbrowse) | that the page said what you were told | the render, the DOM and the requests it made |
| [aitherkvcache](https://github.com/Aitherium/aitherkvcache) | a vendor's quantisation defaults | sub-byte KV cache kernels you can benchmark yourself |
| **AitherZero** _(you are here)_ | a pile of scripts nobody has numbered | numbered, discoverable automation with declarative playbooks |
| [AitherConnect](https://github.com/Aitherium/AitherConnect) | what a page tells your browser to do | a federated search and desktop bridge you host |

[**awnix**](https://github.com/Aitherium/awnix) is the ground floor — A Linux you can hand to an agent — immutable base, capabilities included.

## The Aitherium ecosystem

Every repository here is public. Each publishes an `aither-manifest.json` beside its page, so any surface can read every sibling's — the network is browsable from any node in it.

| repo | what it is | pages |
|---|---|---|
| [awdk](https://github.com/Aitherium/awdk) | Build AI agent fleets — 3 lines, any backend, local or cloud | [docs](https://aitherium.github.io/awdk/) |
| [awskills](https://github.com/Aitherium/awskills) | Portable agent skills — self-contained procedures an agent loads on demand | [docs](https://aitherium.github.io/awskills/) |
| [awm](https://github.com/Aitherium/awm) | A portable, scoped agent memory | [docs](https://aitherium.github.io/awm/) |
| [awnode](https://github.com/Aitherium/awnode) | A lightweight local gateway — bridges your apps to the AI backends you chose | [docs](https://aitherium.github.io/awnode/) |
| [awrun](https://github.com/Aitherium/awrun) | A priority-aware queue and dispatcher for agentic runs and ad-hoc CI builds | [docs](https://aitherium.github.io/awrun/) |
| [awgraph](https://github.com/Aitherium/awgraph) | A semantic code graph for agents — AST + tree-sitter, call graphs | [docs](https://aitherium.github.io/awgraph/) |
| [awgit](https://github.com/Aitherium/awgit) | Semantic version control on top of git — edit-ops and leases | [docs](https://aitherium.github.io/awgit/) |
| [awseal](https://github.com/Aitherium/awseal) | Sign an artifact so a stranger can verify it | [docs](https://aitherium.github.io/awseal/) |
| [awshare](https://github.com/Aitherium/awshare) | Publish an artifact and fetch it back verified | [docs](https://aitherium.github.io/awshare/) |
| [awnest](https://github.com/Aitherium/awnest) | Prove there is a human before you let them into the nest | — |
| [awnboard](https://github.com/Aitherium/awnboard) | A front gate you can put in front of anything, and hand someone the key to | — |
| [awnix](https://github.com/Aitherium/awnix) | A Linux you can hand to an agent — immutable base, capabilities included | [docs](https://aitherium.github.io/awnix/) |
| [awrecover](https://github.com/Aitherium/awrecover) | Labelled snapshots with an all-or-nothing restore | [docs](https://aitherium.github.io/awrecover/) |
| [awrelay](https://github.com/Aitherium/awrelay) | Portable agent messaging — findings, alerts, coordination | [docs](https://aitherium.github.io/awrelay/) |
| [awmail](https://github.com/Aitherium/awmail) | Give an agent an email address — send, and actually receive | — |
| [awfind](https://github.com/Aitherium/awfind) | A portable search client — query, results, ranking | — |
| [awbrowse](https://github.com/Aitherium/awbrowse) | A portable browser client — navigate, console, network, DOM, screenshot | — |
| [aitherkvcache](https://github.com/Aitherium/aitherkvcache) | Near-optimal KV cache quantization for LLM inference — sub-byte compression | [docs](https://aitherium.github.io/aitherkvcache/) |
| **AitherZero** _(you are here)_ | PowerShell 7+ automation framework — numbered, self-describing scripts | [docs](https://aitherium.github.io/AitherZero/) |
| [AitherConnect](https://github.com/Aitherium/AitherConnect) | Browser extension — federated AI search, page context, and the Living OS overlay | — |

<!-- aither-ecosystem:end -->
