# Deprecated Playbooks

This directory contains playbooks that have been deprecated and replaced by newer versions.

## Deprecated PR Playbooks

These playbooks have been replaced by the `ci-*` prefixed versions:

- `pr-validation.psd1` → Use `ci-pr-validation.psd1`
- `pr-validation-fast.psd1` → Use `ci-pr-validation.psd1` with fast options
- `pr-validation-full.psd1` → Use `ci-pr-validation.psd1` (default is full)
- `pr-build.psd1` → Use `ci-pr-build.psd1`
- `pr-test.psd1` → Use `ci-pr-test.psd1`
- `pr-report.psd1` → Use `ci-pr-report.psd1`

## Why Deprecated?

1. **Naming Consistency** - All CI/CD playbooks now use `ci-` prefix
2. **Better Organization** - Clear separation between CI/CD and utility playbooks
3. **Improved Features** - New playbooks have better error handling, parallel execution, and reporting
4. **Workflow Integration** - New playbooks are designed specifically for GitHub Actions workflows

## Migration Guide

### Old Way (Deprecated)
```powershell
Invoke-AitherPlaybook -Name pr-validation
Invoke-AitherPlaybook -Name pr-build
Invoke-AitherPlaybook -Name pr-test
Invoke-AitherPlaybook -Name pr-report
```

### New Way
```powershell
# Complete PR validation (replaces pr-validation, pr-validation-fast, pr-validation-full)
Invoke-AitherPlaybook -Name ci-pr-validation

# Individual phases (replaces pr-build, pr-test, pr-report)
Invoke-AitherPlaybook -Name ci-pr-build
Invoke-AitherPlaybook -Name ci-pr-test
Invoke-AitherPlaybook -Name ci-pr-report
```

## Workflow Updates

All GitHub Actions workflows have been updated to use the new `ci-*` playbooks. If you have local scripts or documentation referencing the old playbooks, update them to use the new names.

