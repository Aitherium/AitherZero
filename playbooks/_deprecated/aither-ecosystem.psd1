@{
    Name = "aither-ecosystem"
    Description = "Start and manage the complete Aither Neural Network ecosystem"
    Version = "2.0.0"

    Variables = @{
        HealthCheckTimeout = 30
        ServiceStartDelay = 2
    }

    # Sequence of operations for full ecosystem startup
    # Services follow the Neural Network architecture layers
    Sequence = @(
        # Step 1: Stop any existing services to ensure clean state
        @{
            Script = "0804"
            Description = "Stop existing services"
            Parameters = @{
                Services = @("All")
            }
            ContinueOnError = $true
            Timeout = 30
        },

        # Step 2: Start all services (Monitoring → Perception → Intelligence → NervousSystem → Core → UI)
        @{
            Script = "0050"
            Description = "Start Aither Ecosystem"
            Parameters = @{
                Services = @("Core")
                Background = $true
                HealthCheck = $true
                Timeout = 30
            }
            ContinueOnError = $false
            Timeout = 300  # Increased for more services
        },

        # Step 3: Verify all services are healthy
        @{
            Script = "0803"
            Description = "Verify service status"
            Parameters = @{
                Detailed = $true
            }
            ContinueOnError = $false
            Timeout = 30
        }
    )

    Options = @{
        Parallel = $false
        MaxConcurrency = 1
        StopOnError = $false
        CaptureOutput = $true
    }

    Metadata = @{
        Author = "Aitherium"
        Created = "2025-11-28"
        Updated = "2025-11-29"
        Tags = @("ecosystem", "startup", "services", "orchestration", "neural-network")
        EstimatedDuration = "180s"
        ServiceCount = 12
        Architecture = "Neural Network (8 Layers)"
    }
}
