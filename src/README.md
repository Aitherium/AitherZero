# [FOLDER] AitherZero Source

> **Navigation**: [Home](../../README.md) > [AitherZero](../README.md) > Source

PowerShell module source code organized by access level.

## [FILES] Directory Structure

```text
src/
 README.md # This file
 public/ # Exported functions (available to users)
 Configuration/ # Config management
 Logging/ # Logging functions
 Orchestration/ # Playbook execution
 Security/ # Security functions
 System/ # System utilities
 Testing/ # Test helpers
 private/ # Internal functions (module use only)
 Helpers/ # Internal helpers
```

## Public vs Private

| Type | Location | Exported | Use Case |
|------|----------|----------|----------|
| **Public** | `src/public/` | Yes | User-facing functions |
| **Private** | `src/private/` | No | Internal module helpers |

## Function Domains

### Configuration

Functions for reading and managing configuration:

- `Get-AitherConfigs` - Get merged configuration
- `Import-ConfigDataFile` - Import .psd1 files with expressions

### Logging

Functions for logging and output:

- `Write-ScriptLog` - Write structured log messages
- `Write-AitherError` - Write error with formatting

### Orchestration

Functions for script and playbook execution:

- `Invoke-AitherScript` - Run automation script by number
- `Invoke-Playbook` - Run playbook

### Security

Security and credential functions:

- `Get-SecureCredential` - Get encrypted credential
- `Protect-SensitiveData` - Encrypt sensitive data

### System

System utilities:

- `Get-SystemInfo` - Get system information
- `Test-Prerequisite` - Check prerequisites

### Testing

Test helpers:

- `Invoke-PesterTests` - Run Pester tests
- `Get-CodeCoverage` - Get coverage metrics

## Adding New Functions

1. Create file in appropriate domain folder:

```powershell
# src/public/Configuration/Get-NewFunction.ps1
function Get-NewFunction {
 <#
 .SYNOPSIS
 Brief description.
 .DESCRIPTION
 Detailed description.
 .PARAMETER Name
 Parameter description.
 .EXAMPLE
 Get-NewFunction -Name 'example'
 #>
 [CmdletBinding()]
 param(
 [Parameter(Mandatory)]
 [string]$Name
 )
 
 # Implementation
}
```

2. Export in module manifest:

```powershell
# AitherZero/AitherZero.psd1
@{
 FunctionsToExport = @(
 'Get-NewFunction'
 # ... other functions
 )
}
```

3. Add tests:

```powershell
# tests/Unit/Get-NewFunction.Tests.ps1
```

---

[← AitherZero](../README.md) | [Tests →](../tests/README.md)
