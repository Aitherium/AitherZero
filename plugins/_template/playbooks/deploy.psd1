@{
    Name        = 'deploy-project'
    Description = 'Deploy the project to the target environment'
    Version     = '1.0.0'

    Steps       = @(
        @{
            Script      = '3001'
            Description = 'Deploy project'
            Parameters  = @{ Environment = 'development' }
            OnFailure   = 'Stop'
        }
    )

    Variables   = @{
        Environment = 'development'
    }
}
