# Changelog

All notable changes to AitherZero will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
