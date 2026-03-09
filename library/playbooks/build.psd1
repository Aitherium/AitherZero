@{
    # =========================================================================
    # AITHEROS BUILD PLAYBOOK
    # =========================================================================
    # Builds all container images for AitherOS
    # Usage: ./bootstrap.ps1 -Playbook build
    # =========================================================================

    Name = "build"
    Description = "Build all AitherOS container images"
    Version = "2.0.0"
    Author = "AitherZero"
    Category = "build"

    # Parameters
    Parameters = @{
        Target = "production"  # development, production
        Push = $false
        Registry = "ghcr.io/aitheros"
        Tag = "latest"
        BuildGenesisOnly = $false
        BuildVeilOnly = $false
    }

    Prerequisites = @(
        "Docker installed and running"
        "Sufficient disk space (10GB+)"
    )

    Sequence = @(
        # =====================================================================
        # PHASE 1: BASE IMAGES
        # =====================================================================
        @{
            Name = "Build Genesis Image"
            Script = "20-build/2001_Build-GenesisImage"
            Description = "Build the Genesis bootloader container"
            Parameters = @{
                Target = '$Target'
                Tag = '$Tag'
                Registry = '$Registry'
            }
            ContinueOnError = $false
        },

        @{
            Name = "Build Service Base Images"
            Script = "20-build/2002_Build-ServicesBase"
            Description = "Build base images for Python and Node services"
            Condition = '$BuildGenesisOnly -eq $false -and $BuildVeilOnly -eq $false'
            Parameters = @{
                Target = '$Target'
                Tag = '$Tag'
                Registry = '$Registry'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 2: SERVICE IMAGES
        # =====================================================================
        @{
            Name = "Build All Service Images"
            Script = "20-build/2003_Build-ServiceImages"
            Description = "Build all service images using Docker Compose"
            Condition = '$BuildGenesisOnly -eq $false -and $BuildVeilOnly -eq $false'
            Parameters = @{
                Target = '$Target'
                Parallel = $true
            }
            ContinueOnError = $false
        },

        @{
            Name = "Build Veil Dashboard"
            Script = "20-build/2004_Build-VeilImage"
            Description = "Build the Veil dashboard image"
            Condition = '$BuildGenesisOnly -eq $false'
            Parameters = @{
                Target = '$Target'
                Tag = '$Tag'
                Registry = '$Registry'
            }
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 3: PUSH (OPTIONAL)
        # =====================================================================
        @{
            Name = "Push Images to Registry"
            Script = "20-build/2005_Push-Images"
            Description = "Push all images to container registry"
            Condition = '$Push -eq $true'
            Parameters = @{
                Registry = '$Registry'
                Tag = '$Tag'
            }
            ContinueOnError = $true
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  BUILD COMPLETE!
  ============================================================

  All AitherOS container images have been built.

  To deploy locally:
    ./bootstrap.ps1 -Playbook deploy-local

  To push to registry:
    ./bootstrap.ps1 -Playbook build -Variables @{ Push = `$true }

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  BUILD FAILED
  ============================================================

  Please check the build logs above for errors.

  Common issues:
    - Docker daemon not running
    - Insufficient disk space
    - Network issues pulling base images

"@
    }
}
