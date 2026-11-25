@{
    Name        = "dev-stack"
    Description = "Public Aitherium developer stack: awnix (WSL2 on Windows) + Python/Git/Node/gh + awdk 4.0+ + awsh 2.0+ + core aw* brick suite + 2-way Antigravity wiring + awrise clock + live verification"
    Version     = "1.1.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # AITHERIUM PUBLIC DEV STACK PLAYBOOK
    # ==========================================================================
    #
    # One-command, idempotent setup for the complete Aither World developer stack
    # on Windows, Linux (including awnix), or macOS:
    #
    #   1. awnix (Windows)   WSL2 distro via Windows Goodbye (goodbyewindows.sh)
    #   2. Base toolchain    Python 3.10+, Git, Node 20+, GitHub CLI (optional)
    #   3. awdk 4.0+         `adk` CLI + harness daemon + Antigravity bridge
    #   4. awsh 2.0+         `@aitherium/awsh` terminal shell + terminal avatars
    #   5. aw* brick suite   awrise, awgit, awm, awrelay, awdecide, awask,
    #                        awrun, awfocus, awsettings, awmine, awbrain,
    #                        awrtifact (PyPI by default; optional local packages)
    #   6. Antigravity/awsh  `adk antigravity setup` + `awsh avatar list`
    #   7. awrise clock      `awrise doctor` + optional `awrise install-clock`
    #   8. Live verification `3273_Test-DevStack.ps1` (every tool answers)
    #
    # USAGE:
    #   # Standard public install (awnix + aw* stack + awdk 4.0 + awsh 2.0)
    #   Invoke-AitherPlaybook dev-stack
    #
    #   # Skip awnix import (e.g. if you only want native host tools)
    #   Invoke-AitherPlaybook dev-stack -Variables @{ InstallAwnix = $false }
    #
    #   # Enable host scheduler clock & local harness daemon too
    #   Invoke-AitherPlaybook dev-stack -Variables @{
    #       InstallClock       = $true
    #       StartHarnessDaemon = $true
    #   }
    #
    #   # Preview every step without mutating anything
    #   Invoke-AitherPlaybook dev-stack -DryRun
    # ==========================================================================

    Parameters = @{
        # On Windows, install awnix as a WSL2 distro via Windows Goodbye.
        InstallAwnix           = $true

        # WSL2 distro name for awnix.
        AwnixDistroName        = 'awnix'

        # pip extras for awdk. 'shell,platform,node' matches `adk setup-all`.
        AwdkExtras             = 'shell,platform,node'

        # Install GitHub CLI (`gh`).
        InstallGitHubCLI       = $true

        # Where to install the aw* Python brick suite from: 'PyPI' or 'Local'.
        BrickSource            = 'PyPI'

        # Optional directory containing local aw* package subfolders (when BrickSource='Local').
        LocalPackagesDir       = ''

        # Comma-separated override of aw* bricks (empty = default core 12).
        Bricks                 = ''

        # Wire 2-way Google Antigravity integration (`adk antigravity setup`).
        SetupAntigravity       = $true

        # Start the local harness daemon (`adk harness up`) after setup.
        StartHarnessDaemon     = $false

        # Register this host's awrise clock (`awrise install-clock`).
        InstallClock           = $false

        # Optional path to a custom surface-eval script to schedule every 30m in awrise.
        EvalScript             = ''

        # Optional AWRELAY_NICK for awrise / relay reporting.
        RelayNick              = ''

        # Run `adk login` (browser device flow) at the end.
        Login                  = $false
    }

    Prerequisites = @(
        "PowerShell 7+ (pwsh)"
        "A package manager: winget (Windows), brew (macOS), apt/dnf/apk (Linux)"
        "Windows WSL2 enabled if InstallAwnix=$true (wsl --install --no-distribution)"
        "Network egress to pypi.org, registry.npmjs.org, github.com, goodbyewindows.sh"
    )

    Sequence = @(
        @{
            Name            = "awnix (WSL2 Linux)"
            Script          = "32-onboarding/3274_Install-Awnix"
            Description     = "Install awnix via Windows Goodbye (Windows only; skipped if already installed)"
            Condition       = '$InstallAwnix -eq $true'
            Parameters      = @{
                DistroName = '$AwnixDistroName'
            }
            ContinueOnError = $true
        }
        @{
            Name            = "Python 3"
            Script          = "10-devtools/1004_Install-Python"
            Description     = "python3 + pip (awdk and aw* bricks)"
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
            Description     = "node + npm (awsh 2.0+ requires Node 20+)"
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
            Name            = "awdk 4.0+ (adk CLI)"
            Script          = "32-onboarding/3260_Install-AWDK"
            Description     = "pip install --upgrade awdk[<AwdkExtras>]"
            Parameters      = @{
                Extras = '$AwdkExtras'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "awsh 2.0+"
            Script          = "32-onboarding/3261_Install-AWSH"
            Description     = "npm install -g @aitherium/awsh"
            ContinueOnError = $false
        }
        @{
            Name            = "aw* Brick Stack"
            Script          = "32-onboarding/3270_Install-AwBrickStack"
            Description     = "Install/upgrade core aw* bricks (awrise, awgit, awm, awrelay, awdecide, awask, awrun, awfocus, awsettings, awmine, awbrain, awrtifact)"
            Parameters      = @{
                Source           = '$BrickSource'
                LocalPackagesDir = '$LocalPackagesDir'
                Bricks           = '$Bricks'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "Antigravity & awsh Wiring"
            Script          = "32-onboarding/3271_Setup-AntigravityAndAwsh"
            Description     = "2-way Google Antigravity setup, awsh avatar list, optional harness daemon"
            Condition       = '$SetupAntigravity -eq $true'
            Parameters      = @{
                StartHarnessDaemon = '$StartHarnessDaemon'
            }
            ContinueOnError = $true
        }
        @{
            Name            = "awrise Clock"
            Script          = "32-onboarding/3272_Setup-AwriseAndEval"
            Description     = "Check awrise doctor (split-home guard) and optional install-clock"
            Parameters      = @{
                InstallClock = '$InstallClock'
                EvalScript   = '$EvalScript'
                RelayNick    = '$RelayNick'
            }
            ContinueOnError = $true
        }
        @{
            Name            = "Verify Dev Stack"
            Script          = "32-onboarding/3273_Test-DevStack"
            Description     = "Live verification: awnix, adk 4.0+, awsh 2.0+, aw* bricks, Antigravity doctor, awrise doctor"
            Parameters      = @{
                RequireGitHubCLI = '$InstallGitHubCLI'
                CheckAntigravity = '$SetupAntigravity'
                CheckAwnix       = '$InstallAwnix'
            }
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

+=====================================================================+
|   AITHERIUM DEV STACK READY                                         |
+=====================================================================+
|                                                                     |
|  Installed & verified:                                              |
|    - awnix (WSL2 Linux on Windows, open with `wsl -d awnix`)        |
|    - awdk 4.0+ (`adk`) + 2-way Antigravity bridge                   |
|    - awsh 2.0+ (`awsh`, terminal avatars, `awsh agent`)             |
|    - Core aw* bricks (awrise, awgit, awm, awrelay, awdecide,        |
|      awask, awrun, awfocus, awsettings, awmine, awbrain, awrtifact) |
|                                                                     |
|  Quick daily commands:                                              |
|    wsl -d awnix                  # enter awnix Linux                |
|    awsh                          # interactive shell + avatar       |
|    adk harness up                # local harness daemon             |
|    adk antigravity doctor        # verify 2-way Antigravity bridge  |
|    awrise doctor && awrise status# verify host clock + wakes        |
|                                                                     |
|  Re-run any time to upgrade or repair; every step is idempotent.    |
+=====================================================================+
"@
    }

    OnFailure = @{
        Message = @"

+=====================================================================+
|   AITHERIUM DEV STACK SETUP FAILED                                  |
+=====================================================================+
|  Check the failing step above, then re-run:                         |
|    Invoke-AitherPlaybook dev-stack                                  |
|  Common fixes:                                                      |
|    - WSL missing on Windows -> run `wsl --install --no-distribution`|
|      in an admin PowerShell, reboot, then re-run                    |
|    - Fresh PATH after Python/Node install -> open a new terminal    |
|    - Split AWRISE_HOME reported by doctor -> align AWRISE_HOME and  |
|      re-run `awrise install-clock --force`                          |
+=====================================================================+
"@
    }
}
