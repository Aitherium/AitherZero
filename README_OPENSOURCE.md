<div align="center">

# ⚡ AitherZero

**PowerShell 7+ CI/CD Automation Framework with OpenTofu Infrastructure Abstraction**

[![CI](https://github.com/aitherium/aitherzero/actions/workflows/ci.yml/badge.svg)](https://github.com/aitherium/aitherzero/actions/workflows/ci.yml)
[![PowerShell 7+](https://img.shields.io/badge/PowerShell-7.0%2B-blue?style=flat-square&logo=powershell)](https://github.com/PowerShell/PowerShell)
[![License](https://img.shields.io/badge/license-Apache%202.0-green?style=flat-square)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-ready-purple?style=flat-square)](https://opentofu.org)

Deploy anything. Orchestrate everything. From your terminal or your AI assistant.

[Getting Started](#getting-started) · [Documentation](https://docs.aitherium.com/aitherzero) · [Plugins](#plugins) · [Contributing](CONTRIBUTING.md)

</div>

---

## What is AitherZero?

AitherZero is an **automation framework** that unifies CI/CD, infrastructure-as-code, and deployment orchestration into a single PowerShell module. It's designed to:

- **Abstract away infrastructure complexity** — Define what you want in config, not how to provision it
- **Work with AI assistants** — Native [MCP server](https://modelcontextprotocol.io) exposes all automation to Copilot, Claude, and other AI tools
- **Run anywhere** — Windows, Linux, macOS — same scripts, same config
- **Extend via plugins** — Project-specific automation without forking the framework

```powershell
# Bootstrap your environment
./bootstrap.ps1 -Mode New

# Deploy with one command
Invoke-AitherDeploy -Environment production

# Or let your AI assistant do it via MCP
# "Deploy the staging environment and run the integration tests"
```

## Key Features

| Feature | Description |
|---------|-------------|
| 🔧 **Script Engine** | 40+ numbered automation scripts with execution history, retry, and parallel support |
| 📋 **Playbook Orchestrator** | Chain scripts into declarative workflows with dependency awareness |
| ⚙️ **Configuration System** | Hierarchical config with OS-specific overrides and environment variables |
| 🏗️ **OpenTofu Abstraction** | Provision cloud infrastructure (GCP, AWS, Azure) through config-driven modules |
| 🐳 **Docker/K8s Native** | Compose management, image builds, Kubernetes deployment — all config-driven |
| 🤖 **MCP Server** | 25+ tools exposed to AI coding assistants for hands-free automation |
| 🔌 **Plugin System** | Extend with project-specific scripts, functions, playbooks, and IaC modules |
| 🔐 **Secrets Management** | Local DPAPI vault, environment variable injection, GitHub Secrets sync |
| 📊 **Observability** | Structured logging, metrics, execution history, web dashboard |
| 🧪 **Quality Pipeline** | PSScriptAnalyzer, Pester tests, script validation, coverage tracking |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your AI Assistant                     │
│            (Copilot / Claude / Cursor / etc.)            │
├───────────────────────┬─────────────────────────────────┤
│     MCP Protocol      │        Direct CLI               │
├───────────────────────┴─────────────────────────────────┤
│                   AitherZero Core                        │
│  ┌──────────┐ ┌───────────┐ ┌────────┐ ┌────────────┐  │
│  │ Config   │ │ Orchestr. │ │ Script │ │ Logging &  │  │
│  │ System   │ │ (Playbook)│ │ Engine │ │ Metrics    │  │
│  └──────────┘ └───────────┘ └────────┘ └────────────┘  │
├─────────────────────────────────────────────────────────┤
│                   Plugin Layer                           │
│  ┌──────────┐ ┌───────────┐ ┌────────┐ ┌────────────┐  │
│  │ OpenTofu │ │ Docker/K8s│ │ Cloud  │ │ Your       │  │
│  │ Modules  │ │ Deploy    │ │ Provid.│ │ Plugin     │  │
│  └──────────┘ └───────────┘ └────────┘ └────────────┘  │
├─────────────────────────────────────────────────────────┤
│              Infrastructure Targets                      │
│  GCP · AWS · Azure · Docker · Kubernetes · Bare Metal   │
└─────────────────────────────────────────────────────────┘
```

## Getting Started

### Prerequisites

- **PowerShell 7.4+** — [Install](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- **Git**
- **Docker** (optional, for container features)
- **OpenTofu** (optional, for infrastructure provisioning)

### Install

```bash
git clone https://github.com/aitherium/aitherzero.git
cd aitherzero
```

```powershell
# Bootstrap
./bootstrap.ps1 -Mode New -InstallProfile Minimal -NonInteractive

# Import the module
Import-Module ./AitherZero.psd1 -Force

# Verify
Get-AitherStatus
```

### Your First Automation

```powershell
# Run a script by number
Invoke-AitherScript 0011  # Get system fingerprint

# Run a playbook
Invoke-AitherPlaybook dev-environment

# See available scripts
Get-AitherScript | Format-Table Number, Name, Category
```

### Connect to AI Assistant (MCP)

Add to your `.vscode/mcp.json` or Claude config:

```json
{
  "servers": {
    "aitherzero": {
      "command": "node",
      "args": ["./library/integrations/mcp-server/dist/index.js"],
      "env": {
        "AITHERZERO_ROOT": "/path/to/aitherzero"
      }
    }
  }
}
```

Now your AI assistant can: run scripts, execute playbooks, query config, manage git, deploy infrastructure — all through natural language.

## Configuration

AitherZero is **entirely configuration-driven**. One file controls everything:

```powershell
# config/config.psd1
@{
    ProjectContext = @{
        Name            = 'my-app'
        ComposeFile     = 'docker-compose.yml'
        ProjectName     = 'my-app'
        ContainerPrefix = 'my-app'
        RegistryURL     = 'ghcr.io/myorg'
    }

    Container = @{
        Docker = @{
            ComposeFile = 'docker-compose.yml'
            ProjectName = 'my-app'
        }
    }
}
```

Override locally with `config/config.local.psd1` (gitignored) or environment variables prefixed with `AITHERZERO_`.

## Plugins

Plugins add project-specific automation:

```powershell
# Create a new plugin
New-AitherPlugin -Name 'my-webapp' -Description 'Deploy my web application'

# Register a plugin
Register-AitherPlugin -Path ./plugins/my-webapp

# List plugins
Get-AitherPlugin
```

### Plugin Structure

```
plugins/my-webapp/
├── plugin.psd1        # Manifest
├── config/            # Config overlays
├── scripts/           # Automation scripts
├── functions/         # PowerShell functions
├── playbooks/         # Orchestration playbooks
└── infrastructure/    # OpenTofu modules
```

See the [Plugin Development Guide](library/docs/PLUGIN-DEVELOPMENT.md) and the `plugins/_template/` directory.

## Automation Scripts

Scripts are organized by category:

| Category | Range | Purpose |
|----------|-------|---------|
| `00-bootstrap` | 0000-0099 | System prerequisites, environment setup |
| `10-devtools` | 1000-1099 | Developer tool installers |
| `20-build` | 2000-2099 | Container image builds |
| `30-deploy` | 3000-3099 | Deployment targets (compose, K8s, cloud) |
| `40-lifecycle` | 4000-4099 | Service start/stop/restart/scale |
| `50-ai-setup` | 5000-5099 | AI/ML tool setup |
| `60-monitoring` | 6000-6099 | Observability and alerting |
| `60-security` | 6000-6099 | Secrets, TLS, network policies |
| `70-git` | 7000-7099 | Git workflow automation |
| `70-maintenance` | 7000-7099 | Cleanup, backups, updates |
| `80-testing` | 8000-8099 | Testing and validation |

## Playbooks

Playbooks are declarative orchestration:

```powershell
# library/playbooks/ci-pr-validation.psd1
@{
    Name  = 'ci-pr-validation'
    Steps = @(
        @{ Script = '0906'; Description = 'Validate syntax'; OnFailure = 'Stop' }
        @{ Script = '0402'; Description = 'Run unit tests'; OnFailure = 'Continue' }
        @{ Script = '0404'; Description = 'Run PSScriptAnalyzer'; OnFailure = 'Stop' }
    )
}
```

```powershell
Invoke-AitherPlaybook ci-pr-validation
```

## OpenTofu Infrastructure

Provision cloud infrastructure through configuration:

```powershell
# Deploy infrastructure
Invoke-AitherDeploy -Target gcp -Environment production

# Plan changes
Invoke-AitherDeploy -Target gcp -PlanOnly

# Destroy
Invoke-AitherDeploy -Target gcp -Destroy
```

OpenTofu modules are in `library/infrastructure/modules/`. Contribute new modules for AWS, Azure, and other providers!

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Great first contributions:
- 🔧 New dev tool installers (`10-devtools/`)
- 📋 New playbook templates for common CI/CD workflows
- 🔌 Plugin examples for popular frameworks
- 🏗️ OpenTofu modules for AWS/Azure
- 📝 Documentation improvements
- 🐛 Bug fixes and cross-platform compatibility

## License

[Apache License 2.0](LICENSE) — use it however you want, commercial or personal.

## Built by [Aitherium](https://aitherium.com)

AitherZero was extracted from the automation backbone of [AitherOS](https://aitheros.ai), an agentic operating system with 196 microservices. It's been battle-tested deploying complex distributed systems in production.

---

<div align="center">

⭐ **Star this repo** if you find it useful · 🔌 **Build a plugin** and share it · 💬 **Join the discussion** in [GitHub Discussions](https://github.com/aitherium/aitherzero/discussions)

</div>
