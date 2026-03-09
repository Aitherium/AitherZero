# Plugin Template

This is a template for creating AitherZero plugins. Copy this directory and customize it for your project.

## Structure

```
my-plugin/
├── plugin.psd1          # Plugin manifest (required)
├── config/
│   └── plugin.psd1      # Configuration overlay
├── scripts/
│   └── 3001_Deploy-Project.ps1
├── functions/           # Additional PowerShell functions
├── playbooks/
│   └── deploy.psd1
├── infrastructure/      # OpenTofu modules (optional)
└── README.md
```

## Getting Started

1. Copy this template:
   ```powershell
   Copy-Item -Recurse ./plugins/_template ./plugins/my-project
   ```

2. Edit `plugin.psd1` with your plugin details

3. Add your automation scripts, functions, and playbooks

4. Register the plugin:
   ```powershell
   Register-AitherPlugin -Path ./plugins/my-project
   ```

## Configuration

Edit `config/plugin.psd1` to set your project-specific values (compose file, container prefix, registry, etc.). These values are merged on top of the base `config.psd1`.
