# Changelog

All notable changes to AitherZero will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.4.0] - 2026-11-25

### Added
- **Public `dev-stack` playbook** (`library/playbooks/dev-stack.psd1`) — one-command, idempotent setup for the complete Aither World developer stack across Windows, Linux, and macOS: `awnix` (WSL2 via Windows Goodbye), Python/Git/Node/gh, `awdk 4.0+`, `@aitherium/awsh 2.0+`, the 12 core `aw*` bricks (`awrise`, `awgit`, `awm`, `awrelay`, `awdecide`, `awask`, `awrun`, `awfocus`, `awsettings`, `awmine`, `awbrain`, `awrtifact`), 2-way Google Antigravity integration, `awrise` host clock guard, and a live verification gate.
- **Public onboarding scripts `3270`–`3274`**: `3270_Install-AwBrickStack.ps1`, `3271_Setup-AntigravityAndAwsh.ps1`, `3272_Setup-AwriseAndEval.ps1`, `3273_Test-DevStack.ps1`, and `3274_Install-Awnix.ps1`.

### Fixed
- **`Write-AitherLog` & `Write-CustomLog`**: now accept `-Level Success` (rendering green `[OK]` in console and logging at `Information` rank), fixing runtime `ValidateSet` errors across 200+ automation script call sites.
- **Clean module import**: renamed `Plan-AitherNotebook` to approved verb `New-AitherNotebookPlan` (with backward-compatible alias `Plan-AitherNotebook`), eliminating the unapproved-verb warning on `Import-Module AitherZero`.
- **Docs & metadata**: refreshed `README.md` with the 1-paste `bootstrap.ps1`/`bootstrap.sh` quickstart, all 7 public playbooks, updated `awdk`/`awsh`/`awnix` links, and synced `CHANGELOG.md` to the public mirror.

## [2.3.0] - 2026-04-13

### Added
- **Standalone LLM Client** (`Invoke-AitherLLM`) — provider-agnostic LLM access with automatic fallback cascade: MicroScheduler, Ollama, OpenAI, Anthropic, Azure OpenAI
- **Interactive Chat REPL** (`Start-AitherChat`) — multi-turn terminal chat with slash commands, thread management, provider/model hot-swap
- **Conversation Threading** (`AitherZero.Threads`) — JSONL-based persistent conversation catalogs with project scoping
- **LLM configuration section** in `config.psd1` — provider cascade, effort-to-model mapping, thread storage settings
- **Graceful offline fallback** — `Invoke-AitherAgent` now falls back to `Invoke-AitherLLM` when the orchestrator is unavailable instead of failing

### Changed
- `Invoke-AitherAgent` no longer hard-fails when Genesis/orchestrator is offline
- Removed hardcoded localhost URLs from deployment output objects

### Infrastructure
- CI pipeline: PSScriptAnalyzer + Pester on Windows/Linux/macOS
- Release pipeline: GitHub Releases + PSGallery publishing on tag push
- Updated `.gitignore` for cleaner public repo separation

## [2.0.0] - 2026-01-24

### Added
- Category-based script architecture (replacing 212+ scripts with ~86 focused scripts)
- Plugin system (`Register-AitherPlugin`, `Get-AitherPlugin`)
- Intent-Driven Infrastructure (IDI) pipeline with auto-routing
- MCP server integration (25+ tools for AI coding assistants)
- Playbook orchestration engine with dependency tracking
- Hierarchical configuration system with precedence ordering
- Auto-scaling support with cloud provider abstraction
- Pain point tracking dashboard
- Notebook-based workflow execution
- Remote PowerShell session management
- Structured JSON logging with metrics export

### Changed
- Complete module restructure: 190+ exported functions across 14 domain groups
- Build system generates monolithic `.psm1` from `src/public/` and `src/private/`
- Configuration moved to single `config.psd1` manifest

## [1.0.0] - 2025-06-15

### Added
- Initial release
- Core automation script framework
- Docker and Kubernetes deployment support
- PowerShell 7+ cross-platform support
- Pester test integration
- Basic logging and error handling
