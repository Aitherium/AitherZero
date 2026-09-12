@{
    Name        = "awnix"
    Description = "Build awnix - the bootc Linux underneath the Aither World - from its Containerfile (podman or docker); optionally produce a bootable iso/qcow2/ami"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "onboarding"

    # ==========================================================================
    # AWNIX — build the agent OS image
    # ==========================================================================
    #
    #   1. git (10-devtools/1002)
    #   2. clone github.com/Aitherium/awnix, podman|docker build -t awnix:<Tag>
    #      optionally bootc-image-builder --type <Bootable>
    #
    # USAGE:
    #   Invoke-AitherPlaybook awnix
    #   Invoke-AitherPlaybook awnix -Variables @{ Bootable = 'qcow2' }
    #   Invoke-AitherPlaybook awnix -DryRun
    #
    # A container engine is required and NOT installed here: on Windows,
    # `winget install RedHat.Podman-Desktop` or Docker Desktop; on Linux,
    # apt/dnf install podman. Bootable output needs a privileged Linux podman.
    # Layer an agent on the result: FROM awnix:latest / RUN pip3 install awdk.
    # ==========================================================================

    Parameters = @{
        Path     = ''         # checkout dir; empty => ~/.aitherzero/awnix
        Tag      = 'latest'
        Bootable = ''         # '' | iso | qcow2 | ami | vmdk | raw
    }

    Prerequisites = @(
        "podman or docker on PATH"
        "git (installed by this playbook if missing)"
        "Network egress to github.com and quay.io"
    )

    Sequence = @(
        @{
            Name            = "Git"
            Script          = "10-devtools/1002_Install-Git"
            Description     = "git (idempotent)"
            ContinueOnError = $false
        }
        @{
            Name            = "Build awnix image"
            Script          = "32-onboarding/3223_Build-Awnix"
            Description     = "clone/pull awnix; podman|docker build; optional bootc-image-builder"
            Parameters      = @{ Path = '$Path'; Tag = '$Tag'; Bootable = '$Bootable' }
            ContinueOnError = $false
        }
    )

    Options = @{ Parallel = $false; MaxConcurrency = 1; StopOnError = $true }

    OnSuccess = @{
        Message = @'

+=================================================================+
|   AWNIX IMAGE BUILT                                              |
+=================================================================+
|  podman images awnix                                             |
|  Layer an agent:  FROM awnix:latest                              |
|                   RUN pip3 install awdk                          |
|  Bootable disk:   -Variables @{ Bootable = 'qcow2' }  (Linux)    |
+=================================================================+
'@
    }

    OnFailure = @{
        Message = @'

+=================================================================+
|   AWNIX BUILD FAILED                                             |
+=================================================================+
|  - no podman/docker   -> winget install RedHat.Podman-Desktop    |
|  - bootc builder      -> needs privileged Linux podman            |
|  - clone failed       -> check egress to github.com               |
+=================================================================+
'@
    }
}
