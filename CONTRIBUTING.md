# Contributing to AitherZero

Thank you for your interest in contributing to AitherZero! This guide will help you get started.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How Can I Contribute?](#how-can-i-contribute)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Plugin Development](#plugin-development)

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to [conduct@aitherium.com](mailto:conduct@aitherium.com).

## How Can I Contribute?

### 🐛 Reporting Bugs

- Use the [Bug Report](https://github.com/aitherium/aitherzero/issues/new?template=bug_report.yml) issue template
- Include your PowerShell version (`$PSVersionTable`), OS, and steps to reproduce
- Check existing issues first to avoid duplicates

### 💡 Suggesting Features

- Use the [Feature Request](https://github.com/aitherium/aitherzero/issues/new?template=feature_request.yml) issue template
- Explain the problem you're trying to solve, not just the solution you want
- Consider whether this belongs in core or as a plugin

### 🔧 Code Contributions

Great areas to contribute:

| Area | Difficulty | Impact | Examples |
|------|-----------|--------|----------|
| **Dev tool installers** (`10-devtools/`) | Easy | High | New installer scripts for common tools |
| **Playbook templates** | Easy | High | CI/CD playbooks for frameworks (Next.js, Django, etc.) |
| **Plugin examples** | Medium | High | Reference deployments for web apps, APIs, etc. |
| **OpenTofu modules** | Medium | Very High | AWS/Azure/GCP infrastructure modules |
| **Cross-platform fixes** | Medium | High | Linux/macOS compatibility improvements |
| **Documentation** | Easy | High | Guides, tutorials, API reference |
| **MCP server tools** | Medium | Medium | New tool endpoints for AI integration |
| **Core framework** | Hard | Very High | Orchestration, config system, plugin loader |

Look for issues labeled [`good-first-issue`](https://github.com/aitherium/aitherzero/labels/good-first-issue) or [`help-wanted`](https://github.com/aitherium/aitherzero/labels/help-wanted).

## Development Setup

### Prerequisites

- **PowerShell 7.4+** — [Install Guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- **Git** — [Install Guide](https://git-scm.com/downloads)
- **Docker** (optional, for container features)
- **OpenTofu** (optional, for infrastructure features)

### Clone and Bootstrap

```bash
git clone https://github.com/aitherium/aitherzero.git
cd aitherzero
```

```powershell
# Bootstrap the environment
./bootstrap.ps1 -Mode New -InstallProfile Minimal -NonInteractive

# Import the module
Import-Module ./AitherZero.psd1 -Force

# Verify
Get-Module AitherZero
```

### Run Tests

```powershell
# Run all Pester tests
Invoke-Pester ./tests/ -Output Detailed

# Run PSScriptAnalyzer
Invoke-ScriptAnalyzer -Path ./src/ -Recurse -Settings PSGallery

# Run the built-in validation
./library/automation-scripts/80-testing/0402_Run-UnitTests.ps1
./library/automation-scripts/80-testing/0404_Run-PSScriptAnalyzer.ps1
```

## Making Changes

### Branch Naming

```
feature/short-description    # New features
fix/short-description        # Bug fixes
docs/short-description       # Documentation only
plugin/plugin-name           # New plugins or plugin updates
infra/short-description      # OpenTofu/infrastructure changes
```

### Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scripts): add Rust installer to 10-devtools
fix(orchestration): handle empty playbook steps array
docs(plugins): add plugin development guide
test(config): add tests for config merge behavior
chore(ci): update Pester to v5.6
```

### Creating Automation Scripts

Scripts follow the numbered convention. See [Script Standards](#script-standards) below.

```powershell
# Template for a new script
#Requires -Version 7.0

<#
.SYNOPSIS
    Brief description of what this script does.
.DESCRIPTION
    Detailed description including use cases.
.PARAMETER Example
    Description of the parameter.
.EXAMPLE
    ./library/automation-scripts/10-devtools/1030_Install-Rust.ps1
.NOTES
    Category: DevTools
    Author: Your Name
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Import module init
. (Join-Path $PSScriptRoot '../_init.ps1')

Write-ScriptLog "Starting Rust installation..." -Level Info

# ... implementation ...

Write-ScriptLog "Rust installation complete." -Level Info
```

## Pull Request Process

1. **Fork** the repository and create a branch from `develop`
2. **Make your changes** following the coding standards
3. **Add tests** for any new functionality
4. **Run the full test suite** locally
5. **Submit a PR** against `develop` with a clear description
6. **Respond to review feedback** — maintainers will review within 48 hours

### PR Requirements

- [ ] Tests pass (`Invoke-Pester ./tests/`)
- [ ] PSScriptAnalyzer clean (`Invoke-ScriptAnalyzer -Path ./src/ -Recurse`)
- [ ] Conventional commit messages
- [ ] Documentation updated (if applicable)
- [ ] No secrets, credentials, or internal URLs
- [ ] Works on at least Windows + one other platform (Linux or macOS)

## Coding Standards

### PowerShell Style

- **PowerShell 7.0+** — no Windows PowerShell 5.1 compatibility required
- `#Requires -Version 7.0` at the top of every script
- `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version Latest`
- Use `[CmdletBinding()]` on all functions
- Full cmdlet names (no aliases in committed code)
- Comment-based help on all public functions
- Use `Write-ScriptLog` or `Write-AitherLog` for output (not `Write-Host`)

### Script Standards

- **Idempotent** — running twice produces the same result
- **Cross-platform** — use `Join-Path`, `[IO.Path]::Combine()`, test `$IsWindows`/`$IsLinux`/`$IsMacOS`
- **Config-driven** — read from `Get-AitherConfigs`, don't hardcode paths or URLs
- **Error handling** — `try/catch` with meaningful error messages
- **Logging** — log start, key actions, and completion

### File Organization

```
src/public/<Domain>/        # One function per file, filename = function name
library/automation-scripts/ # Numbered scripts in category folders
library/playbooks/          # Declarative .psd1 playbook files
plugins/<name>/             # Plugin directories with plugin.psd1 manifest
tests/Unit/                 # Pester unit tests (Test-*.Tests.ps1)
tests/Integration/          # Integration tests (requires Docker/services)
```

## Plugin Development

See the [Plugin Development Guide](library/docs/PLUGIN-DEVELOPMENT.md) for full details.

### Quick Start

```powershell
# Scaffold a new plugin
New-AitherPlugin -Name 'my-webapp' -Description 'Deploy my web application'
```

This creates:

```
plugins/my-webapp/
├── plugin.psd1        # Plugin manifest
├── config/            # Config overlays
├── scripts/           # Automation scripts
├── functions/         # PowerShell functions
├── playbooks/         # Orchestration playbooks
└── README.md
```

### Plugin Manifest (`plugin.psd1`)

```powershell
@{
    Name        = 'my-webapp'
    Version     = '1.0.0'
    Description = 'Deploy my web application'
    Author      = 'Your Name'
    ConfigOverlay   = 'config/webapp.psd1'
    ScriptPaths     = @('scripts/')
    FunctionPaths   = @('functions/')
    PlaybookPaths   = @('playbooks/')
    MinimumVersion  = '3.0.0'
}
```

---

## Questions?

- **GitHub Discussions**: [github.com/aitherium/aitherzero/discussions](https://github.com/aitherium/aitherzero/discussions)
- **Issues**: [github.com/aitherium/aitherzero/issues](https://github.com/aitherium/aitherzero/issues)

Thank you for helping make AitherZero better! 🚀
