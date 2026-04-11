# Utility Playbooks

This directory contains utility playbooks that are not part of the core CI/CD pipeline but may be useful for specific tasks.

## Available Utility Playbooks

### Setup & Environment
- **`aitherium-org-setup.psd1`** - Organization-level setup
- **`dev-environment-setup.psd1`** - Development environment setup
- **`self-hosted-runner-setup.psd1`** - Self-hosted runner setup
- **`deployment-environment.psd1`** - Deployment environment setup (kept in main for review)

### Testing & Quality
- **`code-quality-fast.psd1`** - Quick code quality checks
- **`code-quality-full.psd1`** - Complete code quality workflow
- **`comprehensive-validation.psd1`** - Full validation suite with coverage
- **`integration-tests-full.psd1`** - Complete integration test suite
- **`run-tests.psd1`** - Execute complete test suite
- **`project-health-check.psd1`** - Project health validation

### Diagnostics & Maintenance
- **`diagnose-ci.psd1`** - Diagnose CI workflow failures
- **`fix-ci-validation.psd1`** - Fix common CI validation failures
- **`validate-all-playbooks.psd1`** - Validate all playbooks
- **`self-deployment-test.psd1`** - Self-deployment validation

## Usage

These playbooks can be invoked manually when needed:

```powershell
# Run utility playbook
Invoke-AitherPlaybook -Name code-quality-fast

# Or specify full path
Invoke-AitherPlaybook -Path library/playbooks/_utilities/code-quality-fast.psd1
```

## Note

These playbooks are **not** used by GitHub Actions workflows. Only CI/CD playbooks in the main `library/playbooks/` directory are used in workflows.

