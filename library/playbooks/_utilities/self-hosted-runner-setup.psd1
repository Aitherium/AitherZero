# Self-Hosted Runner Setup Playbook
# Configure GitHub Actions self-hosted runner as a persistent Windows service
# for the AitherOS dark factory autonomous CI/CD loop.

@{
    Name = 'self-hosted-runner-setup'
    Description = 'Setup GitHub Actions self-hosted runner as a Windows service with CI/CD tools'
    Version = '2.0.0'
    Author = 'Aitherium'

    # Configuration
    Configuration = @{
        Profile = 'Self-Hosted-Runner'
        NonInteractive = $true
        ContinueOnError = $false
        Parallel = $false
    }

    # Environment detection
    Environment = @{
        DetectCI = $false  # Not in CI when setting up runner
        RequireAdmin = $true  # Runner service needs admin for sc.exe
        ValidatePrerequisites = $true
    }

    # Script execution sequence
    Sequence = @(
        # Phase 1: Validate prerequisites
        @{
            Script = '00-bootstrap/0001_Validate-Prerequisites'
            Description = 'Validate system prerequisites (PowerShell 7+, admin)'
        }

        # Phase 2: Core development tools
        @{
            Script = '10-devtools/1002_Install-Git'
            Description = 'Ensure Git is installed'
        }
        @{
            Script = '10-devtools/1003_Install-Node'
            Description = 'Ensure Node.js is installed'
        }
        @{
            Script = '10-devtools/1007_Install-GitHubCLI'
            Description = 'Ensure GitHub CLI is installed (for token generation)'
        }

        # Phase 3: Container runtime
        @{
            Script = '00-bootstrap/0003_Install-Docker'
            Description = 'Ensure Docker Desktop is installed and running'
        }

        # Phase 4: Runner installation + Windows service
        @{
            Script = '30-deploy/3045_Setup-GitHubRunner'
            Description = 'Download, configure, and install runner as Windows service (start=auto)'
        }

        # Phase 5: Verify runner service is running
        @{
            Script = '25-infrastructure/0708_Verify-GitHubRunner'
            Description = 'Verify runner service is running and registered with GitHub'
        }
    )

    # Runner-specific configuration
    RunnerConfiguration = @{
        AutoRegister = $true
        InstallAsService = $true
        StartOnBoot = $true
        RunnerGroup = 'Default'
        Labels = @('self-hosted', 'windows', 'aitheros-local', 'gpu')
        InstallPath = 'D:\actions-runner'
        Repository = 'Aitherium/AitherOS'
    }

    # Post-execution actions
    PostExecution = @{
        GenerateReport = $true
        ValidateRunnerStatus = $true
        TestRunnerConnection = $true
    }

    # Validation checks
    Validation = @{
        RequiredCommands = @('git', 'docker', 'gh', 'pwsh')
        RequiredServices = @('actions.runner.*')
        NetworkConnectivity = @('https://github.com', 'https://api.github.com')
    }
}
