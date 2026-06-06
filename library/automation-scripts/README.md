# AitherZero Automation Scripts

This directory contains the automated installation, configuration, deployment, and
lifecycle-management scripts for the AitherOS platform. Scripts are grouped into
**category directories**; each script is a single, idempotent, cross-platform unit
of work named `NNNN_Verb-Noun.ps1`.

> **Public vs. gated:** AitherZero is curated when synced to the public repo
> (`github.com/Aitherium/AitherZero`). Only the categories marked **public** below
> ship publicly; **gated** categories (enterprise/infra-sensitive and
> project-specific tooling) stay in the private monorepo. The curation policy lives
> in [`SYNC-MANIFEST.yaml`](../../SYNC-MANIFEST.yaml) and is enforced by
> `.github/workflows/sync-aitherzero.yml`. If a category is missing from your
> checkout, see `GATED.md`.

## Numbering convention

- Filenames begin with a **4-digit number** (`NNNN_`). The runtime resolves a script
  by that number (`Invoke-AitherScript 0402`) or by `category/number`
  (`80-testing/0402`).
- The directory's 2-digit prefix groups scripts by **category**. Numbers are
  **unique repo-wide** — there are no duplicate numbers across categories.
- Some categories still contain legacy numbers that predate the current grouping
  (e.g. `01-infrastructure` holds `9011_Cleanup-DiskSpace`). These are valid and
  unique; they are simply not yet re-sequenced into their category's range.

## Categories

| Category | Scripts | Visibility | Purpose |
|----------|:------:|:----------:|---------|
| `00-bootstrap` | 14 | gated | System prerequisites, PowerShell 7, Docker, K8s, environment |
| `01-infrastructure` | 11 | gated | Infra provisioning: OpenTofu, Hyper-V, WSL2, ADK, self-hosted runner |
| `08-aitheros` | 11 | gated | AitherOS-specific config, snapshots, internal-product integrations |
| `09-restore` | 10 | gated | Backup/restore pipeline (secrets, filesystem, Postgres, volumes) |
| `10-devtools` | 23 | **public** | Dev tool installation (git, node, python, CLIs, build tools) |
| `20-ai-tools` | 13 | **public** | AI desktop tools (ComfyUI, Stable Diffusion, Ollama, local LLM) |
| `20-build` | 9 | gated | Container image builds and publishing |
| `26-roboflow` | 11 | gated | Roboflow 3D asset pipeline (project-specific) |
| `30-deploy` | 29 | gated | Deployment targets: compose, K8s/K3s, cloud, rings, partners |
| `31-remote` | 18 | gated | Remote/edge node deployment, DGX Spark, quantization |
| `32-onboarding` | 8 | gated | Node onboarding, mesh join, laptop/ADK setup |
| `40-lifecycle` | 10 | gated | Service start/stop/restart/scale, autoscale, watchdogs |
| `50-ai-setup` | 15 | gated | vLLM, model provisioning, voice, workbench, orchestrator |
| `60-chaos` | 1 | gated | Chaos-engineering scenarios |
| `60-monitoring` | 5 | **public** | Observability, service status, flight deck, SLO reports |
| `60-security` | 9 | gated | Secrets, security mesh, TLS certificates |
| `70-external-integrations` | 5 | **public** | Generic 3rd-party integrations (Proton Bridge, Slack, WhatsApp, Obsidian, Cloudflare) |
| `70-git` | 10 | **public** | Git/GitHub workflow, account switching, open-source sync |
| `70-github` | 3 | gated | GitHub org/runner/Copilot bootstrap (org-specific) |
| `70-maintenance` | 4 | **public** | Docker cleanup, disk usage, GPU memory |
| `80-testing` | 8 | **public** | Unit/integration tests, PSScriptAnalyzer, benchmarks |
| `90-competition` | 1 | gated | Competition / training runs |

**Total: 228 scripts** (plus legacy scripts archived under `_archive/`).

Public categories: `10-devtools`, `20-ai-tools`, `60-monitoring`,
`70-external-integrations`, `70-git`, `70-maintenance`, `80-testing`.

## Script Standards

### Metadata Header

Every script must include:

```powershell
#Requires -Version 7.0
<#
.SYNOPSIS
 Brief one-line description.

.DESCRIPTION
 Detailed description of what this script does.

.PARAMETER ConfigPath
 Path to configuration file.

.EXAMPLE
 .\0001_Validate-Prerequisites.ps1 -Verbose

.NOTES
 Category: bootstrap
 Order: 0001
 Dependencies: None
 Platform: Windows, Linux, macOS
#>
```

Keep the `Order:` header in sync with the filename number.

### Key Principles

1. **Idempotent**: Safe to run multiple times
2. **Cross-platform**: Support Windows, Linux, macOS where applicable
3. **Container-first**: All services run in containers
4. **Single responsibility**: Each script does one thing well
5. **Configurable**: Read settings from `services.yaml` and environment

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Prerequisites not met |
| 3 | Configuration error |
| 10 | Container build failure |
| 20 | Deployment failure |
| 30 | Service health check failure |

## Usage

### Via Playbooks (Recommended)

```powershell
# Full bootstrap
./bootstrap.ps1 -Playbook bootstrap

# Build containers
Invoke-AitherPlaybook -Name build

# Deploy locally
Invoke-AitherPlaybook -Name deploy-local
```

### Direct Execution

```powershell
# By number (resolved across categories)
Invoke-AitherScript 0001 -Verbose

# By category/number, or by path
& ".\00-bootstrap\0001_Validate-Prerequisites.ps1" -Verbose
& ".\30-deploy\3001_Deploy-LocalCompose.ps1" -Environment "development"
```

## Adding New Scripts

1. Pick the appropriate category directory (or propose a new one).
2. Use the **next available number** — it must be **unique repo-wide**, not just
   within the directory.
3. Follow the naming convention: `NNNN_Verb-Noun.ps1`.
4. Include the required metadata header (keep `Order:` = filename number).
5. Make the script idempotent and cross-platform.
6. If the script is enterprise/infra-sensitive or project-specific, place it in a
   **gated** category and confirm it is excluded by `SYNC-MANIFEST.yaml`.
7. Add it to the relevant playbook if part of a sequence.

## Legacy Scripts

Legacy scripts are archived under `_archive/` for reference:

```powershell
Get-ChildItem .\_archive\*.ps1 | Select-Object Name
```
