# AitherZero — PowerShell Automation Framework

The infrastructure automation layer for AitherOS. PowerShell 7+, 178+ numbered scripts, playbook orchestration, and one-command deployment from bare metal to running system.

---

## Quick Start

### Import the Module

```powershell
Import-Module ./AitherZero/AitherZero.psd1 -Force
Get-Module AitherZero
```

### Run a Script

```powershell
Invoke-AitherScript 0011                    # By number
pwsh -File ./AitherZero/library/automation-scripts/0011_Get-SystemInfo.ps1 -ShowOutput
```

### Run a Playbook

```powershell
./bootstrap.ps1 -Playbook test-quick
```

---

## Full Deployment from Scratch

One command takes a bare machine to a fully running AitherOS with all dependencies, runtimes, Ollama, services, and dashboard.

### One-Liner

```powershell
# Full AitherOS deployment (PowerShell 7+)
& ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/Aitherium/aither/main/bootstrap.ps1))) -Playbook genesis-bootstrap

# Install AitherZero only (skip full deployment)
iwr -useb https://raw.githubusercontent.com/Aitherium/aither/main/bootstrap.ps1 | iex
```

### What This Does

The `genesis-bootstrap` playbook automatically:

1. Detects your hardware (GPU, CPU, RAM) and configures optimal settings
2. Installs all dependencies: Python 3.11+, Node.js 20+, Docker Desktop, Ollama
3. Configures Ollama with optimal models for your hardware tier
4. Sets up AitherOS services and Genesis bootloader
5. Installs system services for persistence across reboots
6. Opens the Genesis Dashboard at http://localhost:8001/dashboard

### Configuration

All automation is driven by config files in `AitherZero/config/`:

- `config.psd1` — Master configuration (do not edit directly)
- `config.local.psd1` — Local overrides (gitignored, edit this)

```powershell
# config.local.psd1
@{
    Core = @{
        NonInteractive = $true       # No prompts (CI/CD friendly)
    }
    Features = @{
        Development = @{
            Python = @{ Enabled = $true }
            Node   = @{ Enabled = $true }
            Docker = @{ Enabled = $true }
        }
        AI = @{
            Ollama  = @{ Enabled = $true }
            ComfyUI = @{ Enabled = $false }   # Heavy, optional
        }
    }
}
```

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `AITHERZERO_NONINTERACTIVE=1` | Skip all prompts |
| `AITHEROS_SKIP_OLLAMA=1` | Skip Ollama/model setup |
| `AITHEROS_SKIP_VEIL=1` | Skip Veil dashboard setup |

### Available Playbooks

| Playbook | Description |
|----------|-------------|
| `genesis-bootstrap` | Full AitherOS deployment from scratch |
| `deploy-infrastructure` | Infrastructure/cloud deployment |
| `build` | Build container images only |
| `deploy-local` | Deploy via Docker Compose |
| `test-quick` | Quick test suite |
| `genesis-test` | Full system test |
| `ci-pr-validation` | CI/CD validation |
| `aither-ecosystem` | Start AI ecosystem |

```powershell
./bootstrap.ps1 -Playbook <playbook-name>
```

---

## Architecture

See `ARCHITECTURE.md` for the full overview.

### Directory Structure

```
AitherZero/
    AitherZero.psd1          # Module manifest
    AitherZero.psm1          # Module loader
    build.ps1                # Build script

    src/
        public/              # Exported functions (by domain)
            AI/              # Agent management
            Configuration/   # Config management
            Dashboard/       # Dashboard functions
            Deployment/      # Deployment tools
            Execution/       # Script execution
            Integrations/    # External integrations
            Logging/         # Logging utilities
            Orchestration/   # Playbook orchestration
            Remote/          # Remote execution
            Security/        # Secrets, SSH keys
            System/          # System utilities
            Testing/         # Test utilities
        private/             # Internal functions
        Startup.ps1          # Module initialization

    library/
        automation-scripts/  # 178+ numbered scripts
        playbooks/           # Orchestration playbooks
        docs/                # Documentation
        templates/           # Script templates

    config/
        config.psd1          # Master configuration
        config.local.psd1    # Local overrides (gitignored)
        config.windows.psd1  # Windows-specific
        config.linux.psd1    # Linux-specific
        config.macos.psd1    # macOS-specific

    tests/
        Unit/
        Integration/
```

---

## Module Domains

### AI (`src/public/AI/`)

| Function | Description |
|----------|-------------|
| `Invoke-Agent` | Start an AI agent |
| `Get-AgentStatus` | Check agent status |
| `Stop-Agent` | Stop a running agent |

### Configuration (`src/public/Configuration/`)

| Function | Description |
|----------|-------------|
| `Get-AitherConfigs` | Load merged configuration |
| `Import-ConfigDataFile` | Import .psd1 config files |
| `Get-ConfigValue` | Get specific config value |

### Logging (`src/public/Logging/`)

| Function | Description |
|----------|-------------|
| `Write-ScriptLog` | Write structured log entry |
| `Write-AitherError` | Write error with context |
| `Get-LogPath` | Get current log file path |

### Orchestration (`src/public/Orchestration/`)

| Function | Description |
|----------|-------------|
| `Invoke-AitherScript` | Run automation script |
| `Invoke-Playbook` | Run playbook |
| `Get-AitherScript` | List available scripts |

### Security (`src/public/Security/`)

| Function | Description |
|----------|-------------|
| `Get-SecureCredential` | Retrieve stored credential |
| `Set-SecureCredential` | Store credential securely |
| `New-SSHKeyPair` | Generate SSH keys |

### Testing (`src/public/Testing/`)

| Function | Description |
|----------|-------------|
| `Invoke-PesterTests` | Run Pester tests |
| `Get-TestCoverage` | Get code coverage |
| `Assert-ScriptAnalyzer` | Run PSScriptAnalyzer |

---

## Automation Scripts

### Script Numbering Convention

| Range | Category | Examples |
|-------|----------|----------|
| 0000-0099 | Environment Setup | `0011_Get-SystemInfo.ps1`, `0014_Initialize-Environment.ps1` |
| 0100-0199 | Infrastructure | `0105_Install-HyperV.ps1`, `0150_Deploy-AgenticOS.ps1` |
| 0200-0299 | Dev Tools | `0207_Install-Git.ps1`, `0225_Install-GoogleADK.ps1` |
| 0400-0499 | Testing/Quality | `0402_Run-UnitTests.ps1`, `0404_Run-PSScriptAnalyzer.ps1` |
| 0500-0599 | Reporting | `0510_Generate-ProjectReport.ps1`, `0520_Build-Documentation.ps1` |
| 0600-0699 | Security | `0601_Manage-Secrets.ps1`, `0602_Generate-SSHKeys.ps1` |
| 0700-0799 | Git/AI/Agents | `0707_Setup-GitHubRunner.ps1`, `0762_Start-AitherNode.ps1` |
| 0800-0899 | AitherOS Ops | `0800_Start-AitherOS.ps1`, `0801_Stop-AitherOS.ps1` |
| 0900-0999 | Validation | `0902_Manage-DevBranch.ps1`, `0906_Validate-Syntax.ps1` |
| 1100+ | Genesis Tests | `1100_Run-GenesisTest.ps1` |

### Key Scripts

| Script | Description |
|--------|-------------|
| `0011_Get-SystemInfo.ps1` | Get system information |
| `0014_Initialize-Environment.ps1` | Initialize AitherZero environment |
| `0800_Start-AitherOS.ps1` | Start all AI services |
| `0801_Stop-AitherOS.ps1` | Stop all AI services |
| `0402_Run-UnitTests.ps1` | Run Pester tests |
| `0510_Generate-ProjectReport.ps1` | Generate project report |
| `0762_Start-AitherNode.ps1` | Start MCP server |
| `0902_Manage-DevBranch.ps1` | TDD workflow dev branch management |
| `0906_Validate-Syntax.ps1` | Validate PowerShell syntax |
| `1100_Run-GenesisTest.ps1` | Full system test (28 phases) |

### Script Template

```powershell
<#
.SYNOPSIS
    Brief description of the script.
.DESCRIPTION
    Detailed description of what the script does.
.PARAMETER ShowOutput
    Show output to console (scripts are silent by default).
.EXAMPLE
    .\0000_My-Script.ps1 -ShowOutput
.NOTES
    Script Number: 0000
    Category: Environment
#>
[CmdletBinding()]
param(
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"

try {
    Write-ScriptLog "Starting script..." -Level Info
    # Your code here
    Write-ScriptLog "Script completed successfully" -Level Info
    exit 0
}
catch {
    Write-AitherError -Message $_.Exception.Message -ErrorRecord $_
    exit 1
}
```

---

## Development

### Adding a New Function

1. Create file in the appropriate domain:

```powershell
# src/public/MyDomain/My-Function.ps1
function My-Function {
    <#
    .SYNOPSIS
        Brief description.
    #>
    [CmdletBinding()]
    param(
        [string]$Parameter
    )
    # Implementation
}
```

2. Export in module manifest (`AitherZero.psd1`):

```powershell
FunctionsToExport = @(
    'My-Function',
    # ...
)
```

### Adding a New Script

1. Pick the next available number in the correct range
2. Copy from `library/templates/` or use the template above
3. Place in `library/automation-scripts/`

### Running Tests

CI uses selective scope detection — changes under `tests/` run touched Pester files, changes under `src/` or `library/` run relevant validation jobs, docs-only changes skip CI.

```powershell
# All tests
pwsh -File ./AitherZero/library/automation-scripts/0402_Run-UnitTests.ps1

# Specific test file
Invoke-Pester ./AitherZero/tests/Unit/MyTest.Tests.ps1

# With coverage
Invoke-Pester -CodeCoverage ./AitherZero/src/public/*/*.ps1
```

### Quality Checks

```powershell
# PSScriptAnalyzer
pwsh -File ./AitherZero/library/automation-scripts/0404_Run-PSScriptAnalyzer.ps1

# Syntax validation
pwsh -File ./AitherZero/library/automation-scripts/0906_Validate-Syntax.ps1 -All

# Component quality
pwsh -File ./AitherZero/library/automation-scripts/0908_Validate-ComponentQuality.ps1 -Path ./src/public/Logging
```

### Playbook Format

```powershell
# playbooks/my-playbook.psd1
@{
    Name = 'my-playbook'
    Description = 'My custom playbook'
    Steps = @(
        @{
            Script = '0906'
            Parameters = @{ All = $true }
            OnFailure = 'Stop'
        },
        @{
            Script = '0402'
            OnFailure = 'Continue'
        }
    )
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
config.psd1                 (master manifest)
```

```powershell
$config = Get-AitherConfigs
$comfyEnabled = $config.Features.AI.ComfyUI.Enabled

# Or use helper
$value = Get-ConfigValue -Path 'Features.AI.ComfyUI.Enabled'
```

---

## Related Documentation

- [Architecture](./ARCHITECTURE.md)
- [Contributing](./CONTRIBUTING.md)
- [Automation Scripts Index](./library/automation-scripts/README.md)
- [Playbooks](./library/playbooks/README.md)
- [AitherOS](../AitherOS/README.md)
- [Root README](../README.md)
