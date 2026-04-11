@{
    # Plugin-specific configuration
    # This is merged on top of the base config.psd1
    # Only include keys you want to override or add

    ProjectContext = @{
        Name            = 'MyProject'
        ComposeFile     = 'docker-compose.yml'
        ProjectName     = 'myproject'
        ContainerPrefix = 'myproject'
        NetworkName     = 'myproject-net'
        RegistryURL     = ''
        OrchestratorURL = ''
        MetricsURL      = ''
    }
}
