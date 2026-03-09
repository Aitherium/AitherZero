# [COPY] Playbooks

> **Navigation**: [Home](../../../README.md) > [AitherZero](../../README.md) > Playbooks

Playbooks orchestrate multiple automation scripts in sequence.

## [FILES] Directory Structure

```text
playbooks/
 README.md # This file
 test-quick.psd1 # Quick test suite
 genesis-test.psd1 # Full system test (28 phases)
 ci-pr-validation.psd1 # CI/CD validation
 aither-ecosystem.psd1 # Start AI ecosystem
 dev-branch-workflow.psd1 # TDD workflow
 ...
```

## Running Playbooks

```powershell
# Run a playbook
Invoke-AitherPlaybook -Name test-quick

# With parameters
Invoke-AitherPlaybook -Name genesis-test -Variables @{ Quick = $true }
```

## Playbook Format

```powershell
# my-playbook.psd1
@{
 Name = 'my-playbook'
 Description = 'Description of what this playbook does'
 Author = 'Your Name'
 Version = '1.0.0'

 # Pre-flight checks (optional)
 PreChecks = @(
 @{
 Check = 'PowerShell Version'
 Script = { $PSVersionTable.PSVersion.Major -ge 7 }
 }
 )

 # Steps to execute
 Steps = @(
 @{
 Name = 'Validate Syntax'
 Script = '0906' # Script number
 Parameters = @{ All = $true }
 OnFailure = 'Stop' # Stop, Continue, or Skip
 },
 @{
 Name = 'Run Tests'
 Script = '0402'
 OnFailure = 'Continue'
 Condition = { $env:RUN_TESTS -eq 'true' } # Optional condition
 }
 )

 # Post-execution actions (optional)
 PostActions = @(
 @{
 Action = 'Cleanup'
 Script = '0000'
 }
 )
}
```

## Built-in Playbooks

### test-quick

Quick test suite for rapid validation.

```powershell
Invoke-AitherPlaybook -Name test-quick
```

### genesis-test

Full system test with 28 phases including TDD, A2A, and secrets validation.

```powershell
Invoke-AitherPlaybook -Name genesis-test
# Or with Quick mode
Invoke-AitherPlaybook -Name genesis-test -Variables @{ Quick = $true }
```

### ci-pr-validation

Validation for CI/CD pipelines.

```powershell
Invoke-AitherPlaybook -Name ci-pr-validation
```

### aitheros-full-setup [STAR] NEW

**Comprehensive end-to-end setup for Windows and Linux.** This is the recommended playbook for fresh installations.

7 phases:

1. Environment validation (Python, PowerShell, Git)
2. Tool installation (dependencies, development tools)
3. Windows: NSSM installation for service management
4. AitherOS configuration (services.yaml, networking)
5. Service boot (AitherGenesis bootloader)
6. Health verification
7. Final summary

```powershell
# Full setup with NSSM services (Windows)
Invoke-AitherPlaybook -Name aitheros-full-setup

# Linux/macOS - uses systemd/launchd instead
Invoke-AitherPlaybook -Name aitheros-full-setup

# Quick mode (skip optional steps)
Invoke-AitherPlaybook -Name aitheros-full-setup -Variables @{ Quick = $true }
```

### aither-ecosystem

Start the complete AI ecosystem (40+ services).

```powershell
Invoke-AitherPlaybook -Name aither-ecosystem
```

### dev-branch-workflow

TDD workflow with dev branch lifecycle management.

```powershell
Invoke-AitherPlaybook -Name dev-branch-workflow
```

## OnFailure Options

| Value | Behavior |
|-------|----------|
| `Stop` | Stop playbook execution |
| `Continue` | Continue to next step |
| `Skip` | Skip remaining steps in same group |

## Creating Custom Playbooks

1. Create a `.psd1` file in this directory
2. Follow the format above
3. Use script numbers (4 digits) in Steps
4. Add to the list below when done

See the [Custom Playbook Guide](../../docs/CUSTOM-PLAYBOOKS.md).

---

[← Automation Scripts](../automation-scripts/README.md) | [AitherZero →](../../README.md)
