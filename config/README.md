# ⚙️ Configuration

> **Navigation**: [Home](../../README.md) > [AitherZero](../README.md) > Configuration

Central configuration directory for AitherZero module.

## 📁 Directory Structure

```text
config/
├── README.md               # This file
├── config.psd1             # Master configuration manifest
├── config.example.psd1     # Example configuration
├── config.local.psd1       # Local overrides (gitignored)
└── domains/                # Domain-specific configs
    ├── ai.psd1             # AI features config
    ├── testing.psd1        # Testing config
    └── ...
```

## Configuration Hierarchy

Configuration merges from multiple sources (highest to lowest priority):

1. **Command-line parameters** (highest priority)
2. **Environment variables** (`AITHERZERO_*`)
3. **config.local.psd1** (gitignored, user overrides)
4. **Domain configs** (`config/domains/*.psd1`)
5. **config.psd1** (master manifest, lowest priority)

## Reading Configuration

```powershell
# Get merged configuration
$config = Get-AitherConfigs

# Access nested values
$config.Core.LogLevel          # "Info"
$config.Features.AI.Enabled    # $true
$config.Testing.Severity       # "Warning"
```

## Master Configuration (config.psd1)

The main configuration file contains these sections:

| Section | Purpose |
|---------|---------|
| `Core` | Essential settings (LogLevel, Paths) |
| `Features` | Feature flags |
| `Agents` | AI agent configurations |
| `System` | System-level settings |
| `Testing` | Test configuration |
| `Dependencies` | External dependencies |

## Local Overrides

Create `config.local.psd1` for machine-specific settings:

```powershell
# config.local.psd1
@{
    Core = @{
        LogLevel = 'Debug'
    }
    Features = @{
        AI = @{
            ComfyUI = @{
                Path = 'D:\ComfyUI'
            }
        }
    }
}
```

This file is automatically excluded from Git.

## Environment Variables

Override any setting with environment variables:

```powershell
# Set log level
$env:AITHERZERO_CORE_LOGLEVEL = 'Debug'

# Enable ComfyUI
$env:AITHERZERO_FEATURES_AI_COMFYUI_ENABLED = 'true'
```

## Domain Configurations

Domain-specific settings are in `config/domains/`:

- `ai.psd1` - AI model paths, API keys
- `testing.psd1` - Test settings, coverage thresholds
- `logging.psd1` - Log formatting, retention
- `security.psd1` - Security settings

## Example Configuration

See [config.example.psd1](config.example.psd1) for a complete example.

---

[← AitherZero](../README.md) | [Documentation](../../docs/CONFIGURATION.md)
