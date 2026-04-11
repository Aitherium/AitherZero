# AitherZero Plugins

Plugins extend AitherZero with project-specific automation, deployment targets, and infrastructure modules.

## What's a Plugin?

A plugin is a directory containing:

- **`plugin.psd1`** — Manifest declaring the plugin's name, version, config overlays, scripts, and functions
- **`config/`** — Configuration overlays merged on top of the base `config.psd1`
- **`scripts/`** — Automation scripts registered into the script engine
- **`functions/`** — PowerShell functions dot-sourced into the module
- **`playbooks/`** — Orchestration playbooks
- **`infrastructure/`** — OpenTofu modules specific to this plugin

## Built-in Plugins

| Plugin | Description | Status |
|--------|-------------|--------|
| `_template` | Scaffold for new plugins | ✅ Available |
| `examples/sample-webapp` | Example: deploy a containerized web app | ✅ Available |

## Installing a Plugin

```powershell
# From a local directory
Register-AitherPlugin -Path ./plugins/my-plugin

# From a Git repo (future)
Install-AitherPlugin -Repo 'https://github.com/user/aitherzero-plugin-aws'
```

## Creating a Plugin

```powershell
# Scaffold a new plugin
New-AitherPlugin -Name 'my-project' -Path ./plugins/

# Or copy the template
Copy-Item -Recurse ./plugins/_template ./plugins/my-project
```

See [Plugin Development Guide](../library/docs/PLUGIN-DEVELOPMENT.md) for full documentation.

## Plugin Discovery

AitherZero discovers plugins from:

1. `plugins/` directory in the AitherZero root
2. Paths listed in `config.local.psd1` → `PluginPaths`
3. `AITHERZERO_PLUGIN_PATH` environment variable (`;`-separated on Windows, `:`-separated on Linux/macOS)

## Community Plugins

Community plugins will be listed in the [AitherZero Plugin Registry](https://github.com/aitherium/aitherzero/discussions/categories/plugins) (GitHub Discussions).

To submit your plugin:
1. Create a public repo with your plugin
2. Post in the Plugins discussion category
3. Include a link, description, and screenshots/examples
