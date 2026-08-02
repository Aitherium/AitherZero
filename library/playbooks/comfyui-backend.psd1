@{
    Name        = "comfyui-backend"
    Description = "Stand up a ComfyUI image-generation backend on THIS machine and register it so your Canvas/Iris jobs run on your own hardware — one command, install -> models -> serve -> register"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    # ==========================================================================
    # BRING-YOUR-OWN ComfyUI BACKEND — CUSTOMER SELF-SERVICE PLAYBOOK
    # ==========================================================================
    #
    # USAGE:
    #   Invoke-AitherPlaybook comfyui-backend -Variables @{
    #       ModelUrl      = "https://<your-mirror>/model.safetensors"
    #       PortalUrl     = "https://portal.aitherium.com"
    #       SessionCookie = "<aither_auth cookie from an interactive login>"
    #   }
    #
    # The single one-liner (any OS — AitherZero bootstraps pwsh7 + deps):
    #   pwsh -NoProfile -Command "iwr -useb https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex; Invoke-AitherPlaybook comfyui-backend -Variables @{ ModelUrl='<url>'; PortalUrl='https://portal.aitherium.com'; SessionCookie='<cookie>' }"
    #
    # GOAL: after this runs, your workspace's Canvas/Iris image generation routes to
    #       YOUR ComfyUI on YOUR hardware. If your node is offline, the platform tells
    #       you loudly rather than silently billing you on the shared pool.
    #
    # HOW: sequences four idempotent, single-concern scripts (re-run any time to
    #      reconcile). Each one verifies its own success — a wrong-CUDA torch, a
    #      truncated checkpoint, an unreachable /system_stats, or a register that
    #      lands in the wrong tenant all fail LOUD rather than looking done.
    # ==========================================================================

    Parameters = @{
        # Where ComfyUI is installed + served from.
        InstallRoot   = ''      # empty => $HOME/ComfyUI

        # REQUIRED: your SFW checkpoint download URL (a mirror / HuggingFace /
        # Civitai link). No default is baked in — a dead default link rots silently.
        ModelUrl      = ''
        ModelSha256   = ''      # optional, for exact verification

        # Serving interface. Empty ListenHost => auto-detect your tailnet/LAN IP.
        # ComfyUI's API is UNAUTHENTICATED, so it binds a PRIVATE address only.
        ListenHost    = ''
        Port          = 8188

        # REQUIRED: authenticated portal registration (so the node is scoped to YOUR
        # workspace and your Canvas jobs can discover it).
        PortalUrl     = 'https://portal.aitherium.com'
        SessionCookie = ''      # aither_auth cookie value from an interactive login

        # Preview only — validate + show what each step would do, change nothing.
        DryRun        = $false
    }

    Prerequisites = @(
        "PowerShell 7+ (AitherZero bootstrap installs it on any OS)"
        "git + python3 (3.10-3.12) on the node"
        "An NVIDIA GPU is strongly recommended (CPU SDXL is minutes per image)"
        "A checkpoint download URL (-ModelUrl)"
        "A portal session cookie (-SessionCookie) from an interactive login"
    )

    Sequence = @(
        @{
            Name            = "Install ComfyUI (venv + CUDA-matched torch)"
            Script          = "32-onboarding/3250_Install-ComfyUI"
            Description     = "Clone ComfyUI, build its venv, install the torch wheel matching your GPU driver, and verify torch actually sees the GPU"
            Parameters      = @{
                InstallRoot = '$InstallRoot'
                DryRun      = '$DryRun'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "Fetch a default SFW checkpoint"
            Script          = "32-onboarding/3251_Fetch-ImageModelPack"
            Description     = "Download + verify (SHA256 or size floor, resumable) a general SFW SDXL checkpoint into the models tree"
            Parameters      = @{
                Url    = '$ModelUrl'
                Sha256 = '$ModelSha256'
                DryRun = '$DryRun'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "Start ComfyUI on a private interface"
            Script          = "32-onboarding/3252_Start-ComfyUI"
            Description     = "Serve ComfyUI bound to your tailnet/LAN IP and prove GET /system_stats answers (the exact health check the platform runs)"
            Parameters      = @{
                InstallRoot = '$InstallRoot'
                ListenHost  = '$ListenHost'
                Port        = '$Port'
                DryRun      = '$DryRun'
            }
            ContinueOnError = $false
        }
        @{
            Name            = "Register the backend with your workspace"
            Script          = "32-onboarding/3253_Register-ImageBackend"
            Description     = "Register the node through the authenticated portal (capabilities:[comfyui] + comfyui_url) and verify it appears in YOUR listing"
            Parameters      = @{
                Address       = '$ListenHost'
                Port          = '$Port'
                PortalUrl     = '$PortalUrl'
                SessionCookie = '$SessionCookie'
                DryRun        = '$DryRun'
            }
            ContinueOnError = $false
        }
    )

    # Sequential + stop-on-error: a failed install must not proceed to serve/register.
    Options = @{
        Parallel       = $false
        MaxConcurrency = 1
        StopOnError    = $true
    }

    OnSuccess = @{
        Message = @"

+=================================================================+
|   ComfyUI BACKEND LIVE — your Canvas/Iris jobs run on YOUR box    |
+=================================================================+
|                                                                  |
|  It is registered to your workspace and health-checked per job.  |
|                                                                  |
|  VERIFY:                                                         |
|    Portal : portal.aitherium.com -> Compute -> your node online  |
|    Canvas : generate an image; it routes to your ComfyUI         |
|                                                                  |
|  NOTES:                                                          |
|    - Re-run this playbook any time to reconcile (idempotent).    |
|    - To force the shared pool for one job, send backend:platform.|
|    - If your node goes offline, the platform fails LOUD instead  |
|      of silently using the shared pool.                          |
|                                                                  |
+=================================================================+
"@
    }

    OnFailure = @{
        Message = @"

+=================================================================+
|   ComfyUI BACKEND SETUP FAILED                                  |
+=================================================================+
|  COMMON ISSUES (each step failed loud — read its message):      |
|    - torch.cuda False -> wrong torch wheel; re-run 3250 with an  |
|      explicit -TorchIndex matching your driver                   |
|    - checkpoint truncated / no URL -> pass a valid -ModelUrl     |
|    - /system_stats never answered -> ComfyUI failed to start;    |
|      check its console/log                                       |
|    - registered under 'public' tenant -> your -SessionCookie is  |
|      missing/expired; log in to the portal and pass a fresh one  |
+=================================================================+
"@
    }
}
