#Requires -Version 7.0

<#
.SYNOPSIS
    Scaffolds a new AitherZero project workspace.

.DESCRIPTION
    Creates a standard AitherZero project structure with all necessary directories,
    configuration files, and boilerplate code. Supports templates, CI/CD generation,
    IDE configuration, and multiple languages (PowerShell, Python, OpenTofu).

.PARAMETER Path
    The path where the new project should be created.

.PARAMETER Name
    The name of the project. Defaults to the leaf folder name.

.PARAMETER Template
    Project template to use. Options: 'Standard' (default), 'Minimal'.

.PARAMETER Language
    Project language/type. Options: 'PowerShell' (default), 'Python', 'OpenTofu'.

.PARAMETER IncludeCI
    Generate GitHub Actions CI/CD workflow.

.PARAMETER IncludeVSCode
    Generate VS Code configuration (.vscode).

.PARAMETER IncludeModule
    Create a default PowerShell module within the project (PowerShell only).

.PARAMETER GitInit
    Initialize a git repository in the new project.

.PARAMETER RegisterProject
    Register the project in the AitherZero registry.

.PARAMETER Force
    Overwrite existing files if they exist.

.EXAMPLE
    New-AitherProject -Path ./MyPyService -Language Python -IncludeCI
#>
function New-AitherProject {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, HelpMessage = "The path where the new project should be created.")]
        [string]$Path,

        [Parameter(HelpMessage = "The name of the project.")]
        [string]$Name,

        [Parameter(HelpMessage = "Project template.")]
        [ValidateSet('Standard', 'Minimal')]
        [string]$Template = 'Standard',

        [Parameter(HelpMessage = "Project language.")]
        [ValidateSet('PowerShell', 'Python', 'OpenTofu')]
        [string]$Language = 'PowerShell',

        [Parameter(HelpMessage = "Generate CI/CD workflows.")]
        [switch]$IncludeCI,

        [Parameter(HelpMessage = "Generate VS Code config.")]
        [switch]$IncludeVSCode,

        [Parameter(HelpMessage = "Create default module.")]
        [switch]$IncludeModule,

        [Parameter(HelpMessage = "Initialize a git repository.")]
        [switch]$GitInit,

        [Parameter(HelpMessage = "Register the project in the AitherZero registry.")]
        [switch]$RegisterProject,

        [Parameter(HelpMessage = "Overwrite existing files.")]
        [switch]$Force,

        [Parameter(HelpMessage = "Show command output in console.")]
        [switch]$ShowOutput
    )

    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    process {
        if ($PSCmdlet.ShouldProcess($Path, "Create AitherZero $Language project '$Name'")) {
            try {
                # Handle Path resolution
                $fullPath = $Path
                if (-not (Test-Path $Path)) {
                    New-Item -Path $Path -ItemType Directory -Force | Out-Null
                    $fullPath = Resolve-Path -Path $Path
                } else {
                    $fullPath = Resolve-Path -Path $Path
                }

                if (-not $Name) {
                    $Name = Split-Path $fullPath -Leaf
                }

                Write-AitherLog -Level Information -Message "Scaffolding project '$Name' at '$fullPath' (Template: $Template, Language: $Language)"

                # 1. Create Base Directory Structure
                $directories = @(
                    "automation-scripts",
                    "AitherZero/config",
                    "logs",
                    "docs"
                )

                if ($Template -eq 'Standard') {
                    $directories += @("AitherZero/library/templates")
                }

                # Language-specific directories
                if ($Language -eq 'PowerShell') {
                    if ($Template -eq 'Standard') {
                        $directories += @("AitherZero/library/modules", "tests")
                    }
                }
                elseif ($Language -eq 'Python') {
                    $directories += @("src/$Name", "tests")
                }
                elseif ($Language -eq 'OpenTofu') {
                    $directories += @("modules", "environments/dev", "environments/prod", "scripts", "tests", "AitherZero/config")
                }

                foreach ($dir in $directories) {
                    $dirPath = Join-Path $fullPath $dir
                    if (-not (Test-Path $dirPath)) {
                        New-Item -Path $dirPath -ItemType Directory -Force | Out-Null
                    }
                }

                # 2. Create Config (config.psd1) - Common
                $configPath = Join-Path $fullPath "AitherZero/config/config.psd1"
                if (-not (Test-Path $configPath) -or $Force) {
                    $configContent = @"
@{
    Core = @{
        Name        = '$Name'
        Environment = 'Development'
        Version     = '0.1.0'
        ProjectRoot = '$fullPath'
        Language    = '$Language'
    }
    Automation = @{
        ScriptPath = './automation-scripts'
        LogPath    = './logs'
    }
    Logging = @{
        Level         = 'Information'
        Path          = './logs'
        RetentionDays = 30
    }
    Testing = @{
        Path = './tests'
    }
}
"@
                    # Add Infrastructure section for OpenTofu
                    if ($Language -eq 'OpenTofu') {
                        $configContent = @"
@{
    Core = @{
        Name        = '$Name'
        Environment = 'Development'
        Version     = '0.1.0'
        ProjectRoot = '$fullPath'
        Language    = '$Language'
    }
    Infrastructure = @{
        Provider = 'aws' # aws, hyperv, proxmox
        Region   = 'us-east-1'

        # Mass deployment configuration example
        Resources = @{
            VMs = @(
                @{ Name = 'web-01'; Size = 't3.micro'; Role = 'web' }
                @{ Name = 'db-01';  Size = 't3.medium'; Role = 'db' }
            )
            Networks = @(
                @{ Name = 'vpc-main'; Cidr = '10.0.0.0/16' }
            )
        }
    }
    Automation = @{
        ScriptPath = './automation-scripts'
        LogPath    = './logs'
    }
    Logging = @{
        Level         = 'Information'
        Path          = './logs'
        RetentionDays = 30
    }
}
"@
                    }
                    Set-Content -Path $configPath -Value $configContent
                }

                # 3. Create Language Specific Files
                if ($Language -eq 'PowerShell') {
                    $reqPath = Join-Path $fullPath "requirements.psd1"
                    if (-not (Test-Path $reqPath) -or $Force) {
                        $reqContent = @"
@{
    Modules = @{
        'AitherZero' = 'latest'
        'Pester'     = '5.0.0'
    }
}
"@
                        Set-Content -Path $reqPath -Value $reqContent
                    }
                }
                elseif ($Language -eq 'Python') {
                    # requirements.txt
                    $reqPath = Join-Path $fullPath "requirements.txt"
                    if (-not (Test-Path $reqPath) -or $Force) {
                        $reqContent = @"
pytest>=7.0.0
black>=23.0.0
flake8>=6.0.0
"@
                        Set-Content -Path $reqPath -Value $reqContent
                    }

                    # pyproject.toml
                    $tomlPath = Join-Path $fullPath "pyproject.toml"
                    if (-not (Test-Path $tomlPath) -or $Force) {
                        $tomlContent = @"
[project]
name = "$Name"
version = "0.1.0"
description = "AitherZero Python Project"
readme = "README.md"
requires-python = ">=3.8"
dependencies = []

[build-system]
requires = ["setuptools>=61.0"]
build-backend = "setuptools.build_meta"

[tool.pytest.ini_options]
minversion = "6.0"
addopts = "-ra -q"
testpaths = [
    "tests",
]
"@
                        Set-Content -Path $tomlPath -Value $tomlContent
                    }

                    # __init__.py files
                    New-Item -Path (Join-Path $fullPath "src/$Name/__init__.py") -ItemType File -Force | Out-Null
                    New-Item -Path (Join-Path $fullPath "tests/__init__.py") -ItemType File -Force | Out-Null

                    # main.py
                    $mainPath = Join-Path $fullPath "src/$Name/main.py"
                    if (-not (Test-Path $mainPath) -or $Force) {
                        $mainContent = @"
def main():
    print("Hello from $Name!")

if __name__ == "__main__":
    main()
"@
                        Set-Content -Path $mainPath -Value $mainContent
                    }

                    # test_main.py
                    $testPath = Join-Path $fullPath "tests/test_main.py"
                    if (-not (Test-Path $testPath) -or $Force) {
                        $testContent = @"
import pytest
from src.$Name.main import main

def test_basic():
    assert True
"@
                        Set-Content -Path $testPath -Value $testContent
                    }
                }
                elseif ($Language -eq 'OpenTofu') {
                    # --- OpenTofu / Terraform Scaffolding ---

                    # 1. versions.tf
                    $versionsPath = Join-Path $fullPath "versions.tf"
                    $versionsContent = @"
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    proxmox = {
      source  = "Telmate/proxmox"
      version = "2.9.14"
    }
    hyperv = {
      source  = "taliesins/hyperv"
      version = "1.0.3"
    }
  }
}
"@
                    Set-Content -Path $versionsPath -Value $versionsContent

                    # 2. providers.tf
                    $providersPath = Join-Path $fullPath "providers.tf"
                    $providersContent = @"
# Provider configurations
# These are often configured via environment variables for auth

provider "aws" {
  region = var.config.Infrastructure.Region
}

# provider "proxmox" {
#   pm_api_url = "https://proxmox.example.com:8006/api2/json"
# }

# provider "hyperv" {
#   user = "Administrator"
#   password = "CHANGE_ME"
#   host = "192.168.1.100"
# }
"@
                    Set-Content -Path $providersPath -Value $providersContent

                    # 3. variables.tf
                    $varsPath = Join-Path $fullPath "variables.tf"
                    $varsContent = @"
variable "config" {
  description = "Global configuration object imported from config.psd1"
  type        = any
}

variable "environment" {
  description = "Deployment environment (dev, prod)"
  type        = string
  default     = "dev"
}
"@
                    Set-Content -Path $varsPath -Value $varsContent

                    # 4. backend.tf
                    $backendPath = Join-Path $fullPath "backend.tf"
                    $backendContent = @"
# Backend Configuration
# By default, this uses local state. For remote state, uncomment and configure.

terraform {
  # backend "local" {
  #   path = "terraform.tfstate"
  # }

  # backend "s3" {
  #   bucket = "my-terraform-state"
  #   key    = "infra/terraform.tfstate"
  #   region = "us-east-1"
  # }
}
"@
                    Set-Content -Path $backendPath -Value $backendContent

                    # 5. Sync Script (Config to Tofu Bridge)
                    $syncScriptPath = Join-Path $fullPath "scripts/Sync-ConfigToTofu.ps1"
                    $syncScriptContent = @"
#Requires -Version 7.0
<#
.SYNOPSIS
    Syncs config.psd1 to terraform.tfvars.json
.DESCRIPTION
    Reads the AitherZero configuration manifest and exports it as a JSON variable file
    that OpenTofu can natively consume. This bridges the PowerShell config world with HCL.
#>
param(
    [string]`$ConfigPath = '../AitherZero/config/config.psd1',
    [string]`$OutputPath = '../terraform.tfvars.json'
)

`$ErrorActionPreference = 'Stop'

# Resolve paths
`$root = `$PSScriptRoot
`$absConfig = Join-Path `$root `$ConfigPath
`$absOutput = Join-Path `$root `$OutputPath

Write-Host "Reading configuration from `$absConfig..."

if (-not (Test-Path `$absConfig)) {
    throw "Configuration file not found: `$absConfig"
}

`$config = Import-PowerShellDataFile -Path `$absConfig

# Transform for Terraform (flatten if needed, or keep nested)
# We wrap it in a 'config' object to match variables.tf
`$tfVars = @{
    config = `$config
}

Write-Host "Exporting to `$absOutput..."
`$tfVars | ConvertTo-Json -Depth 10 | Set-Content -Path `$absOutput -Encoding UTF8

Write-Host "Done. You can now run 'tofu plan'." -ForegroundColor Green
"@
                    Set-Content -Path $syncScriptPath -Value $syncScriptContent

                    # 6. Terratest Setup
                    $goModPath = Join-Path $fullPath "tests/go.mod"
                    $goModContent = @"
module test

go 1.18

require (
	github.com/gruntwork-io/terratest v0.41.0
	github.com/stretchr/testify v1.8.1
)
"@
                    Set-Content -Path $goModPath -Value $goModContent

                    $testFilePath = Join-Path $fullPath "tests/infrastructure_test.go"
                    $testFileContent = @"
package test

import (
	"testing"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func TestInfrastructure(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../",

        // Pass variables (mocking the config object)
        Vars: map[string]interface{}{
            "config": map[string]interface{}{
                "Infrastructure": map[string]interface{}{
                    "Region": "us-east-1",
                },
            },
        },
	})

	defer terraform.Destroy(t, terraformOptions)

	terraform.InitAndApply(t, terraformOptions)

	// Validate outputs (example)
	// output := terraform.Output(t, terraformOptions, "some_output")
	// assert.Equal(t, "expected_value", output)
}
"@
                    Set-Content -Path $testFilePath -Value $testFileContent
                }

                # 4. EditorConfig
                $editorConfigPath = Join-Path $fullPath ".editorconfig"
                if (-not (Test-Path $editorConfigPath) -or $Force) {
                    $ecContent = @"
root = true

[*]
charset = utf-8
indent_style = space
indent_size = 4
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true

[*.md]
trim_trailing_whitespace = false

[*.{yml,yaml}]
indent_size = 2

[*.py]
indent_style = space
indent_size = 4

[*.{tf,tfvars,hcl}]
indent_style = space
indent_size = 2
"@
                    Set-Content -Path $editorConfigPath -Value $ecContent
                }

                # 5. Sample Script (Common)
                $scriptPath = Join-Path $fullPath "automation-scripts/0000_Initialize.ps1"
                if (-not (Test-Path $scriptPath) -or $Force) {
                    $scriptContent = @"
#Requires -Version 7.0
<#
.SYNOPSIS
    Initialize the environment.
.DESCRIPTION
    Bootstraps the project environment using AitherZero.
#>
[CmdletBinding()]
param()

Write-Host "Initializing $Name..."
Write-Host "Environment configured successfully."
"@
                    Set-Content -Path $scriptPath -Value $scriptContent
                }

                # 6. VS Code Integration
                if ($IncludeVSCode) {
                    $vscodeDir = Join-Path $fullPath ".vscode"
                    if (-not (Test-Path $vscodeDir)) { New-Item -Path $vscodeDir -ItemType Directory -Force | Out-Null }

                    $settingsPath = Join-Path $vscodeDir "settings.json"
                    $settingsContent = ""

                    if ($Language -eq 'PowerShell') {
                        $settingsContent = @"
{
    "powershell.codeFormatting.preset": "OTBS",
    "powershell.integratedConsole.showOnStartup": false,
    "files.exclude": {
        "**/logs/**": true,
        "**/.git/**": true
    },
    "search.exclude": {
        "**/logs/**": true
    }
}
"@
                    } elseif ($Language -eq 'Python') {
                        $settingsContent = @"
{
    "python.defaultInterpreterPath": "\${workspaceFolder}/.venv/bin/python",
    "python.analysis.typeCheckingMode": "basic",
    "editor.formatOnSave": true,
    "python.formatting.provider": "black",
    "files.exclude": {
        "**/logs/**": true,
        "**/.git/**": true,
        "**/__pycache__/**": true,
        "**/.venv/**": true
    }
}
"@
                    } elseif ($Language -eq 'OpenTofu') {
                        $settingsContent = @"
{
    "hashicorp.terraform.path": "tofu",
    "hashicorp.terraform.languageServer.enable": true,
    "editor.formatOnSave": true,
    "files.associations": {
        "*.tf": "terraform",
        "*.tfvars": "terraform",
        "*.tfvars.json": "terraform"
    },
    "files.exclude": {
        "**/.terraform/**": true,
        "**/terraform.tfstate": true,
        "**/terraform.tfstate.backup": true
    }
}
"@
                    }
                    Set-Content -Path $settingsPath -Value $settingsContent
                }

                # 7. CI/CD Integration
                if ($IncludeCI) {
                    $githubDir = Join-Path $fullPath ".github/workflows"
                    if (-not (Test-Path $githubDir)) { New-Item -Path $githubDir -ItemType Directory -Force | Out-Null }

                    if ($Language -eq 'PowerShell') {
                        $ciPath = Join-Path $githubDir "ci.yml"
                        $ciContent = @"
name: CI

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install PowerShell Modules
        shell: pwsh
        run: |
          Install-Module PSScriptAnalyzer -Force
          Install-Module Pester -Force

      - name: Lint Code
        shell: pwsh
        run: |
          Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error

      - name: Run Tests
        shell: pwsh
        run: |
          if (Test-Path ./tests) {
             Invoke-Pester -Path ./tests -Passthru
          }
"@
                        Set-Content -Path $ciPath -Value $ciContent
                    } elseif ($Language -eq 'Python') {
                        $ciPath = Join-Path $githubDir "python-ci.yml"
                        $ciContent = @"
name: Python CI

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.9'
    - name: Install dependencies
      run: |
        python -m pip install --upgrade pip
        pip install pytest flake8 black
        if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
    - name: Lint with flake8
      run: |
        # stop the build if there are Python syntax errors or undefined names
        flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics
        # exit-zero treats all errors as warnings.
        flake8 . --count --exit-zero --max-complexity=10 --max-line-length=127 --statistics
    - name: Test with pytest
      run: |
        pytest
"@
                        Set-Content -Path $ciPath -Value $ciContent
                    } elseif ($Language -eq 'OpenTofu') {
                        $ciPath = Join-Path $githubDir "tofu-ci.yml"
                        $ciContent = @"
name: OpenTofu CI

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Setup OpenTofu
      uses: opentofu/setup-opentofu@v1

    - name: OpenTofu Init
      run: tofu init

    - name: OpenTofu Validate
      run: tofu validate

    - name: OpenTofu Plan
      run: tofu plan
      env:
        TF_VAR_config: '{"Infrastructure": {"Region": "us-east-1"}}'  # Mock config for simple validation
"@
                        Set-Content -Path $ciPath -Value $ciContent
                    }
                }

                # 8. Default Module (PowerShell Only)
                if ($IncludeModule -and $Language -eq 'PowerShell') {
                    $modulesPath = Join-Path $fullPath "AitherZero/library/modules"
                    if (-not (Test-Path $modulesPath)) { New-Item -Path $modulesPath -ItemType Directory -Force | Out-Null }

                    if (Get-Command New-AitherModule -ErrorAction SilentlyContinue) {
                        New-AitherModule -Name "$Name.Core" -Path $modulesPath -Description "Core module for $Name" -Force
                    } else {
                        Write-AitherLog -Level Warning -Message "New-AitherModule cmdlet not found. Skipping module creation." -Source 'New-AitherProject'
                    }
                }

                # 9. Git Init
                if ($GitInit) {
                    if (Get-Command git -ErrorAction SilentlyContinue) {
                        $currentLocation = Get-Location
                        try {
                            Set-Location $fullPath
                            if (-not (Test-Path ".git")) {
                                git init | Out-Null
                            }

                            # Create .gitignore
                            $gitignorePath = ".gitignore"
                            if (-not (Test-Path $gitignorePath) -or $Force) {
                                $gitignoreContent = ""
                                if ($Language -eq 'PowerShell') {
                                    $gitignoreContent = @"
logs/
*.log
config/*.local.psd1
.vscode/
bin/
dist/
*.tmp
.DS_Store
"@
                                } elseif ($Language -eq 'Python') {
                                    $gitignoreContent = @"
logs/
*.log
config/*.local.psd1
.vscode/
__pycache__/
*.py[cod]
*$py.class
.venv
env/
venv/
ENV/
build/
dist/
*.egg-info/
.pytest_cache/
.coverage
htmlcov/
.DS_Store
"@
                                } elseif ($Language -eq 'OpenTofu') {
                                    $gitignoreContent = @"
logs/
*.log
config/*.local.psd1
.vscode/
.DS_Store
.terraform/
terraform.tfstate
terraform.tfstate.backup
*.tfvars
!*.example.tfvars
*.tfvars.json
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraform.lock.hcl
"@
                                }
                                Set-Content -Path $gitignorePath -Value $gitignoreContent
                            }

                            Write-AitherLog -Level Information -Message "Initialized Git repository" -Source 'New-AitherProject'
                        }
                        catch {
                            Write-AitherLog -Level Warning -Message "Failed to initialize git: $_" -Source 'New-AitherProject' -Exception $_
                        }
                        finally {
                            Set-Location $currentLocation
                        }
                    }
                }

                # 10. Register Project
                if ($RegisterProject -and (Get-Command Register-AitherProject -ErrorAction SilentlyContinue)) {
                    Register-AitherProject -Name $Name -Path $fullPath -Language $Language -Template $Template
                    Write-AitherLog -Level Information -Message "Registered project in AitherZero registry" -Source 'New-AitherProject'
                }

                Write-AitherLog -Level Information -Message "Project created successfully at $fullPath" -Source 'New-AitherProject'
                return Get-Item $fullPath
            }
            catch {
                Write-AitherLog -Level Error -Message "Failed to create project: $_" -Source 'New-AitherProject' -Exception $_
                throw
            }
            finally {
                $script:AitherLogTargets = $originalLogTargets
            }
        }
    }
}

