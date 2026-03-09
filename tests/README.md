# Tests

> **Navigation**: [Home](../../README.md) > [AitherZero](../README.md) > Tests

Pester test suite for the AitherZero PowerShell module.

## [FILES] Directory Structure

```text
tests/
 README.md # This file
 Unit/ # Unit tests
 *.Tests.ps1
 Integration/ # Integration tests
 *.Tests.ps1
 Helpers/ # Test helpers
 TestHelper.psm1
```

## Running Tests

```powershell
# Run all tests
./AitherZero/library/automation-scripts/0402_Run-UnitTests.ps1

# Run with VS Code task
# Press Ctrl+Shift+B → "Run Unit Tests"

# Run specific test file
Invoke-Pester -Path ./AitherZero/tests/Unit/Get-AitherConfigs.Tests.ps1

# Run with coverage
Invoke-Pester -Path ./AitherZero/tests -CodeCoverage ./AitherZero/src/**/*.ps1
```

## Test Naming Convention

```text
<FunctionName>.Tests.ps1
```

Example: `Get-AitherConfigs.Tests.ps1`

## Writing Tests

```powershell
# Example: Get-AitherConfigs.Tests.ps1
BeforeAll {
 # Import module
 . "$PSScriptRoot/../_init.ps1"
}

Describe 'Get-AitherConfigs' {
 Context 'When called without parameters' {
 It 'Returns a hashtable' {
 $result = Get-AitherConfigs
 $result | Should -BeOfType [hashtable]
 }
 }
 
 Context 'When called with specific key' {
 It 'Returns the nested value' {
 $result = Get-AitherConfigs -Key 'Core.LogLevel'
 $result | Should -Not -BeNullOrEmpty
 }
 }
}
```

## Test Categories

### Unit Tests

Test individual functions in isolation:
- Mock external dependencies
- Fast execution
- No side effects

### Integration Tests

Test component interactions:
- May require module import
- Test real file operations
- May be slower

## Best Practices

1. **One test file per function**
2. **Use descriptive test names**
3. **Test edge cases**
4. **Mock external dependencies**
5. **Keep tests independent**

## Coverage

Coverage reports are generated to `coverage.xml` in the root:

```powershell
./AitherZero/library/automation-scripts/0402_Run-UnitTests.ps1 -Coverage
```

---

[← AitherZero](../README.md) | [Module Functions →](../src/public/README.md)
