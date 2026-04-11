@{
    # =========================================================================
    # VEIL BUILD PLAYBOOK
    # =========================================================================
    # Validates prerequisites, installs deps, and builds AitherVeil
    # Usage: ./bootstrap.ps1 -Playbook veil-build
    #        ./bootstrap.ps1 -Playbook veil-build -Variables @{ DevMode = $true }
    # =========================================================================

    Name = "veil-build"
    Description = "Install prerequisites and build the AitherVeil dashboard"
    Version = "1.0.0"
    Author = "AitherZero"
    Category = "build"

    Parameters = @{
        DevMode = $false        # Start dev server instead of prod build
        SkipInstall = $false    # Skip npm install
        SkipGenerate = $false   # Skip prebuild generators
    }

    Prerequisites = @(
        "Node.js 18+ installed (or run with auto-install)"
        "npm available on PATH"
    )

    Sequence = @(
        # =====================================================================
        # PHASE 1: PREREQUISITES
        # =====================================================================
        @{
            Name = "Validate System Prerequisites"
            Script = "00-bootstrap/0001_Validate-Prerequisites"
            Description = "Ensure base system tools are available"
            ContinueOnError = $true
        },

        @{
            Name = "Install Node.js"
            Script = "10-devtools/1003_Install-Node"
            Description = "Install Node.js runtime if not present"
            ContinueOnError = $false
        },

        # =====================================================================
        # PHASE 2: BUILD
        # =====================================================================
        @{
            Name = "Build AitherVeil"
            Script = "20-build/2004_Build-Veil"
            Description = "Install npm dependencies and run Next.js build"
            Parameters = @{
                DevMode = '$DevMode'
                SkipInstall = '$SkipInstall'
                SkipGenerate = '$SkipGenerate'
            }
            ContinueOnError = $false
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  VEIL BUILD COMPLETE!
  ============================================================

  The AitherVeil dashboard has been built successfully.

  To start the production server:
    cd AitherOS/apps/AitherVeil && npm start

  To start in dev mode:
    ./bootstrap.ps1 -Playbook veil-build -Variables @{ DevMode = `$true }

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  VEIL BUILD FAILED
  ============================================================

  Common issues:
    - Node.js not installed (run 10-devtools/1003_Install-Node.ps1)
    - Missing npm dependencies (delete node_modules and retry)
    - TypeScript build errors (check the output above)

  Quick fix:
    cd AitherOS/apps/AitherVeil
    npm install
    SKIP_PREBUILD=1 npm run build

"@
    }
}
