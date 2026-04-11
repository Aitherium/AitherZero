# Local AI Node Setup Guide

This guide explains how to set up your local machine (Windows/Linux/WSL) as an AI Node for AitherZero. This allows the cloud-based agents to generate images using your local GPU, saving costs and bypassing filters.

## Prerequisites

1. **NVIDIA GPU**: 8GB+ VRAM recommended for Flux Dev (FP8).
2. **PowerShell 7+**: Required for automation scripts.
3. **Git**: To clone the repository.
4. **Cloudflare Account**: For the tunnel (free).

## Step 1: Clone the Private Repository

Ensure you have the `AitherZero-Internal` repository cloned to your local machine.

```powershell
git clone https://github.com/Aitherium/AitherZero-Internal.git
cd AitherZero-Internal
```

## Step 2: Run the Setup Playbook

We have a dedicated playbook that automates the entire process:

1. Installs Python & Dependencies.
2. Installs ComfyUI & ComfyUI Manager.
3. Downloads Flux Dev (FP8), VAE, and CLIP models.
4. Installs `cloudflared` (Cloudflare Tunnel).
5. Starts ComfyUI and the Tunnel.

First, bootstrap the environment and import the AitherZero module:

```powershell
# 1. Bootstrap (installs dependencies and builds module)
./bootstrap.ps1 -Mode New -InstallProfile Minimal

# 2. Import the module
Import-Module ./AitherZero/AitherZero.psd1 -Force
```

Then, run the playbook using the module cmdlet:

```powershell
# 3. Execute the setup playbook
Invoke-AitherPlaybook -Name setup-local-ai-node
```

**Note:** The first run will take a while as it downloads large models (~15GB).

## Step 3: Connect the Agent

Once the playbook finishes, it will output a Cloudflare URL (e.g., `https://random-name.trycloudflare.com`).

1. Copy this URL.
2. Go to your Codespace where the Narrative Agent is running.
3. Tell the agent: "I have my local node running at [URL]. Please generate an image of..."

## Troubleshooting

* **Port Conflicts**: Ensure port 8188 is free.
* **Model Downloads**: If downloads fail, you can manually place `flux1-dev-fp8.safetensors` in `library/external/ComfyUI/models/unet/`.
* **Cloudflare**: If the tunnel fails, ensure `cloudflared` is in your PATH or let the script install it.
