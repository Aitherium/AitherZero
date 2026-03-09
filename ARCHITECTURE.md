# AitherZero Architecture

## Overview

AitherZero is the **PowerShell automation platform** that powers infrastructure setup, orchestration, and lifecycle management across the Aither ecosystem. It provides a composable execution engine, a layered configuration system, and a standards-driven quality pipeline. AitherZero is designed for **repeatable, idempotent automation** that can run locally, in CI/CD, or through MCP tools.

---

## The Automation Cycle (AitherZero Core Loop)

Automation is modeled as a repeatable cycle: configuration informs orchestration, orchestration triggers execution, execution is validated, and results flow back into reporting and future configuration.

```
+-------------+ +----------------+ +----------------+ +-----------------+
| Configure | ---> | Orchestrate | ---> | Execute | ---> | Validate |
| (Configs) | | (Playbooks) | | (Scripts) | | (Quality/Test) |
+------+------+ +-------+--------+ +-------+--------+ +--------+--------+
 ^ | | |
 | v v v
 | +--------------+ +--------------+ +---------------+
 +---------------| Observe |<-------| Logs/Reports |<-------| Metrics/CI/CD |
 | (Telemetry) | +--------------+ +---------------+
```

---

## Core Architecture Layers

### 1. Module Core (Loader + Runtime)
- **Root**: `AitherZero.psm1`, `AitherZero.psd1`
- **Purpose**: Establish runtime environment, load functions, initialize logging and package manager mappings.
- **Key behaviors**:
 - Module root and project root discovery.
 - Environment variables: `AITHERZERO_ROOT`, `AITHERZERO_MODULE_ROOT`, `AITHERZERO_INITIALIZED`.
 - Optional transcript logging to `library/logs/`.

### 2. Configuration Layer (Hierarchical Config)
- **Primary entry**: `Get-AitherConfigs`
- **Hierarchy**:
 1. `config.psd1` (base)
 2. `config.<os>.psd1` (OS-specific)
 3. `config.local.psd1` (local overrides, gitignored)
 4. Optional custom config (`-ConfigFile`)
- **Key behavior**: All automation uses merged configuration to remain consistent and portable.

### 3. Execution Layer (Single Script Engine)
- **Primary entry**: `Invoke-AitherScript`
- **Purpose**: Execute a single script with:
 - Parameter discovery and validation
 - Transcript capture
 - Optional parallel execution
 - Friendly discovery by script number or name
- **Script location**: `library/automation-scripts/`

### 4. Orchestration Layer (Playbooks)
- **Primary entry**: `Invoke-AitherPlaybook`
- **Purpose**: Execute playbooks (script sequences) with:
 - Sequential and parallel modes
 - Dependency awareness
 - Retry and continue-on-error policies
 - Variable injection
- **Playbooks**: `library/playbooks/*.psd1`

### 5. Automation Scripts Library
- **Primary location**: `library/automation-scripts/`
- **Pattern**: Numbered scripts for repeatable orchestration (`0001`, `0800`, `0906`, etc.)
- **Categories**: bootstrap, infrastructure, build, deploy, lifecycle, AI setup, monitoring, security, testing, maintenance.

### 6. Quality, Testing, and Validation
- **Quality Validator**: `library/automation-scripts/0420_Validate-ComponentQuality.ps1`
- **Pester Tests**: `tests/`
- **ScriptAnalyzer**: enforced via scripts and CI workflows
- **Goal**: enforce logging, error handling, and test coverage across the module.

### 7. Observability and Telemetry
- **Primary logging**: `Write-AitherLog`, `Write-ScriptLog`
- **Log targets**:
 - Console
 - `library/logs/aitherzero-YYYY-MM-DD.log`
 - `library/logs/structured/*.jsonl` (structured)
- **Log access**: `Get-AitherLog`, `Search-AitherLog`

### 8. Integrations
- **MCP Server**: AitherZero can expose its automation surface to AI assistants.
- **CI/CD**: Quality gates, testing, reporting, release automation.
- **Infrastructure Artifacts**: Terraform, Kubernetes, and deployment templates under `library/infrastructure/`.

---

## Module Initialization and Execution Flow

### Script Execution Flow

```
automation-scripts/*.ps1
 |
 | (dot-sources _init.ps1)
 v
_init.ps1
 - Resolve project root
 - Import AitherZero.psd1 module
 - Ensure configuration is available
 |
 v
Invoke-AitherScript
 - Resolve script path
 - Discover parameters
 - Apply config and variables
 - Execute and log
```

### Playbook Execution Flow

```
playbooks/*.psd1
 |
 v
Invoke-AitherPlaybook
 - Load playbook definition
 - Resolve scripts
 - Execute steps (parallel/sequential)
 - Track status + results
```

---

## Configuration System

### File Layout

```
config/
 config.psd1
 config.local.psd1
 config.windows.psd1
 config.linux.psd1
 config.macos.psd1
 domains/*.psd1
```

### Configuration Principles
- **Hierarchical merge** (OS + local + overrides).
- **Environment variable override** (prefix: `AITHERZERO_`).
- **Domain configs** for targeted settings (AI, logging, testing, security).
- **Idempotent** configuration apply operations.

---

## Environment Configuration and Deployment Artifacts

AitherZero can **apply OS-level configuration** and generate deployment artifacts for automated provisioning.

### Supported Capabilities
- **Windows**: registry, features (WSL, Hyper-V), services, power settings.
- **Linux**: sysctl, packages, firewall, SSH, systemd.
- **macOS**: defaults, Homebrew, LaunchAgents.
- **Artifacts**: Unattend.xml, cloud-init, Kickstart, Brewfiles, Dockerfiles.

### Primary Interfaces
- `Get-AitherEnvironmentConfig`, `Set-AitherEnvironmentConfig`
- `New-AitherWindowsUnattendXml`, `New-AitherLinuxCloudInit`, `New-AitherMacOSBrewfile`

---

## Module Domains (Public API Surface)

Public functions are grouped by domain under `src/public/`:

| Domain | Purpose | Examples |
|--------|---------|----------|
| AI | Agent execution | `Invoke-AitherAgent` |
| Configuration | Config system | `Get-AitherConfigs` |
| Dashboard | UI reports | `New-AitherDashboard` |
| Deployment | Artifacts | `New-AitherDockerfile` |
| Execution | Script runs | `Invoke-AitherScript` |
| Integrations | MCP config | `Get-AitherMCPConfig` |
| Logging | Logs/metrics | `Write-AitherLog` |
| Orchestration | Playbooks | `Invoke-AitherPlaybook` |
| Remote | PowerShell remoting | `Invoke-AitherRemoteCommand` |
| Security | Secrets and keys | `Get-AitherSecret` |
| System | System info | `Get-AitherStatus` |
| Testing | Pester helpers | `Invoke-AitherTests` |

---

## Automation Scripts Architecture

### Category Structure (New Architecture)

```
library/automation-scripts/
 00-bootstrap/
 10-infrastructure/
 20-build/
 30-deploy/
 40-lifecycle/
 50-ai-setup/
 60-monitoring/
 70-security/
 80-testing/
 90-maintenance/
```

### Script Standards
- Idempotent and cross-platform where possible.
- Configuration-driven (reads from `config.psd1`).
- Standard exit codes for automation reliability.
- Comment-based help and consistent logging via `Write-ScriptLog`.

---

## Package Manager Abstraction

The module includes cross-platform package manager support with priority-based selection:
- **Windows**: winget, chocolatey
- **Linux**: apt, yum, dnf, pacman
- **macOS**: brew

This enables consistent automation across OS environments with unified function calls.

---

## Orchestration Model (Playbooks)

Playbooks are **declarative orchestration graphs** defined as `.psd1` files:

```
@{
 Name = 'ci-pr-validation'
 Description = 'CI/CD validation'
 Steps = @(
 @{ Script = '0906'; OnFailure = 'Stop' },
 @{ Script = '0402'; OnFailure = 'Continue' }
 )
}
```

### Execution Modes
- **Sequential**: ensure dependencies.
- **Parallel**: speed for independent steps.
- **Hybrid**: parallel groups with sequential boundaries.

---

## Scheduling, History, and State

AitherZero tracks orchestration state and supports scheduled execution:
- **Execution history**: `Get-AitherExecutionHistory`
- **Orchestration status**: `Get-AitherOrchestrationStatus`
- **Resume/stop**: `Resume-AitherOrchestration`, `Stop-AitherOrchestration`
- **Schedules**: `Get-AitherSchedule`, `Start-AitherSchedule`

---

## Logging and Telemetry

### Logging Pipeline
- `Write-AitherLog` is the central interface.
- Optional structured JSON logs for machine processing.
- Transcript logging for full execution capture.

### Log Locations
- `library/logs/aitherzero-YYYY-MM-DD.log`
- `library/logs/structured/structured-YYYY-MM-DD.jsonl`

---

## Metrics and Reporting

Metrics and reports provide visibility into automation health:
- **Metrics**: `Get-AitherMetrics`, `Register-AitherMetrics`, `Export-AitherMetrics`
- **Reports**: `library/reports/` (project reports, dashboards, performance metrics)

---

## Quality and Test Architecture

### Quality Validation
- Component checks: error handling, logging, PSScriptAnalyzer compliance, test coverage.
- Automated in CI/CD and locally via numbered scripts.

### Testing Strategy
- **Unit tests**: `tests/Unit/`
- **Integration tests**: `tests/Integration/`
- **Coverage**: `Invoke-Pester -CodeCoverage ...`

---

## CI/CD Architecture (High Level)

AitherZero uses multi-stage CI/CD pipelines:
- Build + validation
- Unit + integration tests
- Security + performance tests
- Release packaging and publishing
- Report generation and dashboard updates

CI/CD policies enforce **quality gates** (coverage, linting, security thresholds).

---

## MCP Server Integration

AitherZero can run as an **MCP server**, exposing automation to AI tools:

```
AI Assistant
 |
 | MCP (stdio)
 v
AitherZero MCP Server (Node.js)
 |
 | PowerShell Invocation
 v
AitherZero Module + Scripts
```

### Exposed Capabilities
- Run scripts and playbooks
- Query configuration
- Run tests and quality checks
- Generate project reports

---

## Directory Structure

```
AitherZero/
 AitherZero.psd1
 AitherZero.psm1
 build.ps1
 src/
 public/ # Exported functions
 private/ # Internal helpers
 Startup.ps1
 library/
 automation-scripts/
 playbooks/
 docs/
 infrastructure/
 templates/
 config/
 tests/
 integrations/
```

---

## Key Entry Points

| Component | Purpose | Path |
|----------|---------|------|
| Module Loader | Initialize runtime | `AitherZero.psm1` |
| Configuration | Load merged config | `src/public/Configuration/Get-AitherConfigs.ps1` |
| Script Execution | Run scripts | `src/public/Execution/Invoke-AitherScript.ps1` |
| Playbook Orchestration | Run playbooks | `src/public/Orchestration/Invoke-AitherPlaybook.ps1` |
| Logging | Central logging | `src/public/Logging/Write-AitherLog.ps1` |

---

## Integration with AitherOS

AitherZero is the **automation backbone** for AitherOS:
- Bootstrap and lifecycle scripts provision services.
- Playbooks manage setup and operational workflows.
- Configuration aligns environment and deployment settings.
- Testing and validation scripts enforce consistent quality.

---

## Related Documentation

- `AitherZero/README.md`
- `AitherZero/library/docs/CONFIGURATION.md`
- `AitherZero/library/docs/QUALITY-STANDARDS.md`
- `AitherZero/library/docs/AITHERZERO-MCP-SERVER.md`
- `AitherZero/library/docs/CI-CD-GUIDE.md`
- `AitherZero/library/automation-scripts/README.md`
- `AitherZero/library/playbooks/README.md`
