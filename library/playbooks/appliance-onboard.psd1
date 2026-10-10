@{
    Name        = "appliance-onboard"
    Description = "Put a customer appliance on THIS machine from a blank Windows/Linux/macOS box: toolchain, sign-in, clone, enroll, deploy — one paste, re-runnable"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # APPLIANCE ONBOARD PLAYBOOK
    # ==========================================================================
    #
    # A customer machine usually has NONE of the prerequisites: no PowerShell 7,
    # no git, no python on PATH. The public bootstrap already handles PowerShell 7
    # and fetches AitherZero without git; this playbook does the rest:
    #
    #   python3 + pip, git, gh          (public package managers)
    #   awdk (adk)                      (PyPI; Scripts dir put on PATH)
    #   adk login                       (browser device flow)
    #   gh auth login, clone the repo   (appliance repos are private)
    #   adk enroll                      (signed status / logs / redeploy only)
    #   deploy/deploy.ps1               (from the appliance repo)
    #
    # USAGE (blank Windows machine, any PowerShell window):
    #   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1))) -Playbook appliance-onboard -Variables @{ Repo = 'owner/name' }
    #
    # Every step is idempotent; re-running finishes a partial run.
    # ==========================================================================

    Parameters = @{
        # owner/name of the appliance repo. Required.
        Repo   = ''
        # Clone location; default <home>/<repo name>.
        Dir    = ''
        Enroll = $true
        Deploy = $true
        # Employee invite code from an onboarding link (/setup-pc?i=<code>). Set ->
        # `adk enroll --invite <code>` enrolls this machine under the inviting org.
        Invite = ''
    }

    Prerequisites = @(
        "PowerShell 7+ (bootstrap.ps1 / bootstrap.sh install it)"
        "A package manager: winget (Windows), brew (macOS), apt/dnf/apk (Linux)"
        "Docker Desktop or Podman, for the deploy step"
        "A GitHub account with access to the appliance repo"
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
            Name            = "GitHub CLI"
            Script          = "10-devtools/1007_Install-GitHubCLI"
            Description     = "gh (signs in to GitHub and clones the private repo)"
            ContinueOnError = $false
        }
        @{
            Name            = "awdk (adk CLI)"
            Script          = "32-onboarding/3260_Install-AWDK"
            Description     = "pip install awdk"
            Parameters      = @{ Extras = '' }
            ContinueOnError = $false
        }
        @{
            Name            = "adk login"
            Script          = "32-onboarding/3263_Connect-Aitherium"
            Description     = "Browser device flow; skipped when already signed in"
            ContinueOnError = $false
        }
        @{
            Name            = "Clone, enroll, deploy"
            Script          = "32-onboarding/3266_Onboard-Appliance"
            Description     = "gh auth login if needed, clone or update the repo, adk enroll (--invite when set), deploy/deploy.ps1"
            Parameters      = @{
                Repo   = '$Repo'
                Dir    = '$Dir'
                Enroll = '$Enroll'
                Deploy = '$Deploy'
                Invite = '$Invite'
            }
            ContinueOnError = $false
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
|   APPLIANCE READY                                                |
+=================================================================+
|  Open a NEW PowerShell window before typing adk, git or pwsh.    |
|  Later deploys:  pwsh -File <repo>\deploy\deploy.ps1             |
|  Re-run this playbook any time; finished steps are skipped.      |
+=================================================================+
"@
    }

    OnFailure = @{
        Message = @"

+=================================================================+
|   APPLIANCE ONBOARD FAILED                                       |
+=================================================================+
|  - 'not on PATH' after   -> open a new PowerShell window and     |
|    an install               paste the same command again         |
|  - winget missing        -> install "App Installer" from the     |
|                             Microsoft Store                      |
|  - clone 404 / denied    -> the GitHub account you signed in     |
|                             with has no access to the repo       |
|  - deploy preflight      -> install Docker Desktop or Podman     |
+=================================================================+
"@
    }
}
