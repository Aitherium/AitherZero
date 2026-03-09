@{
    # ===================================================================
    # DEVELOPMENT - Development Tools and Git Automation
    # ===================================================================
    Development              = @{
        # Git automation
        GitAutomation   = @{
            Enabled           = $true
            DefaultBranch     = 'main'
            AutoCommit        = $false
            AutoPR            = $false
            SignCommits       = $false

            # Commit conventions
            CommitConventions = @{
                Format            = 'conventional'
                SignOff           = $true
                IssueReferences   = $true
                Scopes            = @('core', 'orchestration', 'infrastructure', 'tests', 'config', 'domains', 'ai', 'ui', 'automation')
                MaxSubjectLength  = 72
                MaxBodyLineLength = 100
            }

            # Branch naming
            BranchNaming      = @{
                Pattern   = '{type}/{issue-number}-{description}'
                Types     = @('feature', 'fix', 'docs', 'test', 'refactor', 'chore')
                MaxLength = 63
            }
        }

        # AI assistance
        AIAgenticCoding = @{
            Enabled            = $true
            Provider           = 'auto'
            ValidationRequired = $true
            AutoTestGeneration = $true

            # Code review settings
            CodeReview         = @{
                PSScriptAnalyzer = $true
                DependencyCheck  = $true
                ComplexityCheck  = $true
                SecurityScan     = $true
            }

            # Guardrails
            Guardrails         = @{
                RequireDocumentation = $true
                RequireTests         = $true
                RequireApproval      = $true
                MaxFilesPerCommit    = 10
                MaxLinesPerFile      = 500
                AllowedFileTypes     = @('.ps1', '.psm1', '.psd1', '.json', '.md', '.yml', '.yaml')
                BlockPatterns        = @('password', 'secret', 'key', 'token')
            }
        }

        # Code quality
        CodeQuality     = @{
            EnforceCodingStandards  = $true
            StrictMode              = 'Latest'
            MaxCyclomaticComplexity = 10
            MaxFunctionLength       = 100
            RequireCommentBasedHelp = $true
            RequireTypeDeclarations = $false
        }
    }

    Features = @{
        # Development tools
        Development    = @{
            Node   = @{
                Enabled       = $true  # Enabled by default for Standard+ profiles
                Version       = 'latest-v20.x'
                InstallScript = '0201'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    InstallNpm     = $true
                    InstallYarn    = $true
                    InstallPnpm    = $false
                    GlobalPackages = @('yarn', 'vite', 'nodemon', '@types/node')
                    PackageManager = 'auto'  # auto, winget, chocolatey, apt, yum, brew
                }
                Installer     = @{
                    Windows = 'https://nodejs.org/dist/latest-v20.x/node-v20-x64.msi'
                    Linux   = 'package-manager'
                    macOS   = 'package-manager'
                }
            }
            Python = @{
                Enabled       = $false
                Version       = '3.12+'
                InstallScript = '0206'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    InstallPip       = $true
                    InstallPoetry    = $false
                    CreateVirtualEnv = $true
                    DefaultPackages  = @('pip', 'setuptools', 'wheel')
                }
            }
            VSCode = @{
                Enabled       = $false
                InstallScript = '0210'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    Extensions = @(
                        'ms-vscode.powershell'
                        'ms-azuretools.vscode-docker'
                        'github.copilot'
                        'github.copilot-chat'
                        'ms-python.python'
                        'ms-vscode.vscode-json'
                        'ms-vsliveshare.vsliveshare'
                        'eamodio.gitlens'
                    )
                    Settings   = @{
                        AutoSave     = 'afterDelay'
                        FormatOnSave = $true
                        TabSize      = 4
                    }
                }
            }
            GitHubCLI = @{
                Enabled = $false
                Version = 'latest'
                InstallScript = '0211'
                Platforms = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    AuthMethod = 'browser'  # browser, token
                    DefaultEditor = 'vim'
                    Protocol = 'https'
                }
            }
            Go = @{
                Enabled = $false
                Version = '1.21+'
                InstallScript = '0212'
                Platforms = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    GOPATH = '$HOME/go'
                    InstallTools = @('gopls', 'golangci-lint')
                }
            }
            Docker = @{
                Enabled           = $false
                InstallScript     = '0208'
                Platforms         = @('Windows', 'Linux', 'macOS')
                RequiresElevation = $true
                Configuration     = @{
                    StartOnBoot = $true
                    WSL2Backend = $true  # Windows only
                    Resources   = @{
                        Memory = '4GB'
                        CPUs   = 2
                        Disk   = '60GB'
                    }
                }
            }
        }

        # Cloud and DevOps tools
        Cloud          = @{
            GitHubCLI = @{
                Enabled       = $true  # Required for git automation
                InstallScript = '0207'  # Integrated with Git installation
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    Authenticate = $false  # Manual auth required
                    Editor       = 'code'
                    GitProtocol  = 'https'
                }
                Installer     = @{
                    Windows = 'https://github.com/cli/cli/releases/download/v2.67.0/gh_2.67.0_windows_amd64.msi'
                    Linux   = 'package-manager'
                    macOS   = 'package-manager'
                }
            }
            AzureCLI  = @{
                Enabled       = $false
                InstallScript = '0212'
                Platforms     = @('Windows', 'Linux', 'macOS')
            }
            AWSCLI    = @{
                Enabled       = $false
                InstallScript = '0213'
                Platforms     = @('Windows', 'Linux', 'macOS')
            }
        }

        # Additional Development Tools
        DevTools       = @{
            Sysinternals = @{
                Enabled       = $false
                InstallScript = '0205'
                Platforms     = @('Windows')
                Description   = 'Windows Sysinternals Suite'
            }
            SevenZip     = @{
                Enabled       = $false
                InstallScript = '0209'
                Platforms     = @('Windows')
                Description   = 'File compression utility'
            }
            VSBuildTools = @{
                Enabled           = $false
                InstallScript     = '0211'
                Platforms         = @('Windows')
                Description       = 'Visual Studio Build Tools'
                RequiresElevation = $true
            }
            Packer       = @{
                Enabled       = $false
                InstallScript = '0214'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'HashiCorp Packer for image building'
            }
            Chocolatey   = @{
                Enabled           = $false
                InstallScript     = '0215'
                Platforms         = @('Windows')
                Description       = 'Windows package manager'
                RequiresElevation = $true
            }
            Poetry       = @{
                Enabled       = $false
                InstallScript = '0204'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Description   = 'Python dependency management'
            }
        }
    }
}
