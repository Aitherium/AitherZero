# Non-Interactive Mode Fix for Feature Checks

## Problem
Scripts that check if a feature is enabled using `Ensure-FeatureEnabled` would prompt interactively even when run with `-Detached` or in non-interactive contexts (CI/CD, remote execution). This caused automation to hang waiting for user input.

## Solution
Updated `_init.ps1`'s `Ensure-FeatureEnabled` function to:

1. **Detect non-interactive contexts**:
 - `-NonInteractive` parameter explicitly passed
 - `$env:CI` = 'true' (GitHub Actions, GitLab CI, etc.)
 - `$env:AITHERZERO_NONINTERACTIVE` = 'true' (custom flag)
 - Non-interactive PowerShell host

2. **Fail gracefully without prompting** in non-interactive mode:
 ```powershell
 throw "Feature 'X' is disabled. Enable it by running: Set-AitherConfig -Section 'Y' -Key 'Z.Enabled' -Value $true"
 ```

3. **Updated scripts** to pass `-NonInteractive:$Detached`:
 - `0734_Start-ComfyUI.ps1`
 - `0732_Start-ComfyUI-Gateway.ps1`

## Usage

### Scripts with -Detached Parameter
Scripts now automatically run in non-interactive mode when `-Detached` is used:
```powershell
# Will fail immediately if feature is disabled, no prompt
./0734_Start-ComfyUI.ps1 -Detached
```

### CI/CD Pipelines
Set environment variable to prevent prompts:
```yaml
env:
 CI: true
 # or
 AITHERZERO_NONINTERACTIVE: true
```

### Manual Override
```powershell
# Force non-interactive mode
Ensure-FeatureEnabled -Section "Features" -Key "AI.ComfyUI" -Name "ComfyUI" -NonInteractive
```

## Testing
```powershell
# Multi-script execution no longer blocks
pwsh -NoProfile -File "AitherZero/library/automation-scripts/0734_Start-ComfyUI.ps1" -Detached
pwsh -NoProfile -File "AitherZero/library/automation-scripts/0737_Start-Ollama.ps1" -Detached
pwsh -NoProfile -File "AitherZero/library/automation-scripts/0762_Start-AitherNode.ps1" -Detached
```

## Benefits
- [OK] Remote execution won't hang
- [OK] CI/CD pipelines work correctly
- [OK] Automated scripts fail fast with clear error messages
- [OK] Interactive mode still prompts users normally
