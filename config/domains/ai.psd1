@{
    # ===================================================================
    # AI - Artificial Intelligence and Automation
    # ===================================================================
    AI                       = @{
        # General AI settings
        Enabled         = $true

        # AI providers
        Providers       = @{
            Claude = @{
                Enabled       = $true
                Priority      = 1
                MaxTokens     = 4096
                Temperature   = 0.7
                ApiKeyEnvVar  = 'ANTHROPIC_API_KEY'
                Model         = 'claude-3-sonnet-20240229'
                UsageTracking = $true
            }
            Codex  = @{
                Enabled       = $true
                Priority      = 3
                MaxTokens     = 8192
                Temperature   = 0.5
                ApiKeyEnvVar  = 'OPENAI_API_KEY'
                Model         = 'gpt-4'
                UsageTracking = $true
            }
            Gemini = @{
                Enabled       = $true
                Priority      = 2
                MaxTokens     = 2048
                Temperature   = 0.9
                ApiKeyEnvVar  = 'GOOGLE_API_KEY'
                Model         = 'gemini-pro'
                UsageTracking = $true
            }
        }

        # AI capabilities
        TestGeneration  = @{
            Enabled                = $true
            Framework              = 'Pester'
            Version                = '5.0+'
            Provider               = 'Claude'
            CoverageTarget         = 80
            GenerateTypes          = @('Unit', 'Integration', 'E2E')
            IncludeMocking         = $true
            IncludeEdgeCases       = $true
            IncludeErrorConditions = $true
        }

        CodeReview      = @{
            Enabled  = $true
            Profiles = @{
                Quick         = @{
                    Checks      = @('syntax', 'quality')
                    Providers   = @('Codex')
                    Description = 'Fast validation for development'
                    Timeout     = 60
                }
                Standard      = @{
                    Checks      = @('security', 'quality', 'performance')
                    Providers   = @('Claude', 'Codex')
                    Description = 'Default review process'
                    Timeout     = 300
                }
                Comprehensive = @{
                    Checks             = @('security', 'quality', 'performance', 'compliance')
                    Providers          = @('Claude', 'Gemini', 'Codex')
                    Description        = 'Full analysis with all providers'
                    Timeout            = 600
                    FailOnHighSeverity = $true
                }
            }
        }

        # Usage monitoring
        UsageMonitoring = @{
            Enabled         = $true
            TrackCosts      = $true
            GenerateReports = $true
            BudgetAlerts    = @{
                Enabled        = $true
                DailyLimit     = 100
                MonthlyLimit   = 1000
                AlertThreshold = 80
            }
        }
    }

    Features = @{
        # AI Development Tools
        AITools        = @{
            ClaudeCode = @{
                Enabled       = $false
                InstallScript = '0217'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    APIKeyEnvVar = 'ANTHROPIC_API_KEY'
                    Model        = 'claude-3-sonnet-20240229'
                }
            }
            GeminiCLI  = @{
                Enabled       = $true
                InstallScript = '0218'
                Platforms     = @('Windows', 'Linux', 'macOS')
                Configuration = @{
                    APIKeyEnvVar = 'GOOGLE_API_KEY'
                    Model        = 'gemini-pro'
                }
            }
        }
    }
}
