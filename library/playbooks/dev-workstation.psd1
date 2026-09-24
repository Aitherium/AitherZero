@{
    Name        = "dev-workstation"
    Description = "Bootstrap THIS machine as an Aitherium developer workstation: Python + Git + Node + gh, then awdk (adk) and awsh — one playbook, any OS, re-runnable"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # DEVELOPER WORKSTATION PLAYBOOK
    # ==========================================================================
    #
    # This is the playbook the root bootstrap.ps1 / bootstrap.sh runs by default.
    # A blank laptop runs ONE paste and ends up with the toolchain a developer
    # needs to build against Aitherium:
    #
    #   python3 + pip     (awdk is a pip package)
    #   git + gh          (repos, PRs)
    #   node + npm        (awsh is an npm package)
    #   adk               `pip install awdk[shell,platform,node]`
    #   awsh              `npm i -g @aitherium/awsh`
    #
    # USAGE (module already imported):
    #   Invoke-AitherPlaybook dev-workstation
    #   Invoke-AitherPlaybook dev-workstation -Variables @{ Login = $true }
    #   Invoke-AitherPlaybook dev-workstation -Variables @{ InstallGitHubCLI = $false; AwdkExtras = '' }
    #   Invoke-AitherPlaybook dev-workstation -DryRun
    #
    # USAGE (blank machine):
    #   Windows : irm https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex
    #   Unix    : curl -fsSL https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.sh | sh
    #
    # Every step is idempotent: Install-AitherPackage skips a package whose
    # command already resolves, pip/npm upgrade in place. Re-running is the
    # documented way to repair a partial install.
    #
    # Measured on a blank Windows 11 box (2026-09-12): the manual sequence
    # this replaces took ~25 minutes including discovering the package names
    # (the awsh README pointed at the wrong npm package; adk doctor reported
    # a healthy install as broken). See the PR that introduced this playbook.
    # ==========================================================================

    Parameters = @{
        # pip extras for awdk. 'shell,platform,node' is what `adk setup-all`
        # installs; '' gives the bare SDK.
        AwdkExtras       = 'shell,platform,node'

        # GitHub CLI is optional for someone who only wants adk/awsh.
        InstallGitHubCLI = $true

        # Run `adk login` (browser device flow) at the end. Off by default so
        # unattended installs never block on a browser.
        Login            = $false
    }

    Prerequisites = @(
        "PowerShell 7+ (bootstrap.ps1 / bootstrap.sh install it)"
        "A package manager: winget (Windows), brew (macOS), apt/dnf/apk (Linux)"
        "Network egress to pypi.org, registry.npmjs.org, github.com"
    )

    Sequence = @(
        @{
            Name            = "Python 3"
            Script          = "10-devtools/1004_Install-Python"
            Description     = "python3 + pip (awdk is a pip package)"
            ContinueOnError = $false
        }
        @{
            Name            = "Git"
            Script          = "10-devtools/1002_Install-Git"
            Description     = "git"
            ContinueOnError = $false
        }
        @{
            Name            = "Node.js LTS"
            Script          = "10-devtools/1003_Install-Node"
            Description     = "node + npm (awsh is an npm package; needs Node 20+)"
            ContinueOnError = $false
        }
        @{
            Name            = "GitHub CLI"
            Script          = "10-devtools/1007_Install-GitHubCLI"
            Description     = "gh (optional)"
            Condition       = '$InstallGitHubCLI -eq $true'
            ContinueOnError = $true
        }
        @{
            Name            = "awdk (adk CLI)"
            Script          = "32-onboarding/3260_Install-AWDK"
            Description     = "pip install awdk[<AwdkExtras>]"
            Parameters      = @{
                Extras = '$AwdkExtras'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "awsh"
            Script          = "32-onboarding/3261_Install-AWSH"
            Description     = "npm install -g @aitherium/awsh"
            ContinueOnError = $false
        }
        @{
            Name            = "Verify"
            Script          = "32-onboarding/3262_Test-DevWorkstation"
            Description     = "Every tool resolves and answers --version; adk status reaches a backend"
            ContinueOnError = $false
        }
        @{
            Name            = "adk login"
            Script          = "32-onboarding/3263_Connect-Aitherium"
            Description     = "Browser device flow (only with -Variables @{ Login = `$true })"
            Condition       = '$Login -eq $true'
            ContinueOnError = $true
        }
    )

    Options = @{
        Parallel       = $false
        MaxConcurrency = 1
        StopOnError    = $true
    }

    OnSuccess = @{
        Message = @"

+=================================================================+
|   DEV WORKSTATION READY                                          |
+=================================================================+
|                                                                  |
|  Open a NEW terminal (PATH), then connect (sign in, inference,   |
|  wire Claude Code / Cursor to the MCP gateway, prove it):        |
|                                                                  |
|    Invoke-AitherPlaybook connect                                 |
|    Invoke-AitherPlaybook connect -Variables @{ Ide = 'cursor' }  |
|                                                                  |
|  Or by hand: adk login / adk quickstart --cloud / adk mcp setup  |
|  Then: awsh   adk start   adk claude-model code (DeepSeek Flash) |
|                                                                  |
|  Re-run either playbook any time; every step is idempotent.      |
|                                                                  |
+=================================================================+
"@
    }

    OnFailure = @{
        Message = @"

+=================================================================+
|   DEV WORKSTATION BOOTSTRAP FAILED                               |
+=================================================================+
|  COMMON ISSUES:                                                  |
|    - No package manager   -> Windows: install "App Installer"    |
|                              (winget) from the Microsoft Store;  |
|                              macOS: install Homebrew             |
|    - winget needs a UAC   -> approve the prompt and re-run       |
|      prompt                                                      |
|    - 'not on PATH' after  -> open a new terminal and re-run;     |
|      install                 the step will skip what is done     |
|    - pip/npm network      -> check egress to pypi.org /          |
|                              registry.npmjs.org                  |
+=================================================================+
"@
    }
}
