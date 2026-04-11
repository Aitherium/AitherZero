#Requires -Version 7.0

<#
.SYNOPSIS
    Setup Taliesin Hyper-V Provider for OpenTofu

.DESCRIPTION
    Configures the Taliesin Hyper-V provider for OpenTofu/Terraform.
    This provider enables infrastructure-as-code management of Hyper-V VMs.

    Prerequisites:
    - Windows with Hyper-V enabled
    - WinRM configured for remote management
    - OpenTofu installed (script 0008)

    The provider requires:
    - WinRM over HTTPS (port 5986)
    - NTLM authentication enabled
    - Admin credentials for the Hyper-V host

.PARAMETER HyperVHost
    Hyper-V host IP or hostname. Default from config.psd1

.PARAMETER ConfigureWinRM
    Also configure WinRM on the local machine for Hyper-V management

.PARAMETER ShowOutput
    Show detailed output

.EXAMPLE
    ./0022_Setup-TaliesinHyperVProvider.ps1
    Sets up the provider using config.psd1 defaults

.EXAMPLE
    ./0022_Setup-TaliesinHyperVProvider.ps1 -ConfigureWinRM
    Also configures WinRM for local Hyper-V management

.NOTES
    File Name      : 0022_Setup-TaliesinHyperVProvider.ps1
    Stage          : Infrastructure
    Dependencies   : OpenTofu (0008)
    Tags           : infrastructure, hyperv, opentofu, provider
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$HyperVHost,

    [Parameter()]
    [switch]$ConfigureWinRM,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize
. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Setting up Taliesin Hyper-V Provider for OpenTofu"

try {
    # ===================================================================
    # CHECK PREREQUISITES
    # ===================================================================
    
    Write-ScriptLog "Checking prerequisites..."
    
    # Check for OpenTofu
    $tofu = Get-Command tofu -ErrorAction SilentlyContinue
    if (-not $tofu) {
        $tofuPath = "$env:ProgramFiles\OpenTofu\tofu.exe"
        if (Test-Path $tofuPath) {
            $tofu = Get-Command $tofuPath
            $env:PATH = "$env:PATH;$env:ProgramFiles\OpenTofu"
        } else {
            Write-ScriptLog "OpenTofu not found. Run 0008_Install-OpenTofu.ps1 first." -Level 'Error'
            exit 1
        }
    }
    Write-ScriptLog "  ✓ OpenTofu found: $(& $tofu version | Select-Object -First 1)"
    
    # Check for Hyper-V
    if ($IsWindows) {
        $hyperv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction SilentlyContinue
        if ($hyperv.State -ne 'Enabled') {
            Write-ScriptLog "Hyper-V is not enabled on this machine" -Level 'Warning'
            Write-ScriptLog "Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
        } else {
            Write-ScriptLog "  ✓ Hyper-V enabled"
        }
    }
    
    # ===================================================================
    # CONFIGURE WINRM (if requested)
    # ===================================================================
    
    if ($ConfigureWinRM -and $IsWindows) {
        Write-ScriptLog "Configuring WinRM for Hyper-V management..."
        
        # Check if running as admin
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-ScriptLog "WinRM configuration requires administrator privileges" -Level 'Error'
            Write-ScriptLog "Please run this script as Administrator with -ConfigureWinRM"
            exit 1
        }
        
        # Enable WinRM
        Write-ScriptLog "  Enabling WinRM service..."
        & winrm quickconfig -quiet 2>$null
        
        # Configure HTTPS listener
        Write-ScriptLog "  Checking HTTPS listener..."
        $httpsListener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue | 
            Where-Object { $_.Keys -contains "Transport=HTTPS" }
        
        if (-not $httpsListener) {
            Write-ScriptLog "  Creating self-signed certificate for WinRM HTTPS..."
            $hostname = [System.Net.Dns]::GetHostName()
            $cert = New-SelfSignedCertificate -DnsName $hostname -CertStoreLocation Cert:\LocalMachine\My
            
            Write-ScriptLog "  Creating HTTPS listener..."
            New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
        }
        
        # Enable NTLM
        Write-ScriptLog "  Enabling NTLM authentication..."
        Set-Item WSMan:\localhost\Service\Auth\Negotiate -Value $true
        Set-Item WSMan:\localhost\Service\Auth\Ntlm -Value $true
        
        # Open firewall
        Write-ScriptLog "  Configuring firewall..."
        $firewallRule = Get-NetFirewallRule -DisplayName "WinRM HTTPS" -ErrorAction SilentlyContinue
        if (-not $firewallRule) {
            New-NetFirewallRule -DisplayName "WinRM HTTPS" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow | Out-Null
        }
        
        Write-ScriptLog "  ✓ WinRM configured for Hyper-V management"
    }
    
    # ===================================================================
    # CREATE PROVIDER LOCK FILE
    # ===================================================================
    
    Write-ScriptLog "Creating OpenTofu provider configuration..."
    
    # Get infrastructure paths from config
    $infraPath = "./infrastructure/tofu-base-lab"
    if (-not (Test-Path $infraPath)) {
        Write-ScriptLog "  Infrastructure path not found: $infraPath" -Level 'Warning'
        Write-ScriptLog "  Run 0109_Initialize-InfrastructureSubmodules.ps1 first to clone the repo"
    }
    
    # Create .terraformrc / .tofurc for provider caching
    $tofurcPath = Join-Path $env:USERPROFILE ".tofurc"
    $pluginCacheDir = Join-Path $env:LOCALAPPDATA "tofu" "plugin-cache"
    
    if (-not (Test-Path $pluginCacheDir)) {
        New-Item -ItemType Directory -Path $pluginCacheDir -Force | Out-Null
    }
    
    $tofurcContent = @"
plugin_cache_dir   = "$($pluginCacheDir -replace '\\', '/')"
disable_checkpoint = true
"@
    
    if (-not (Test-Path $tofurcPath)) {
        $tofurcContent | Set-Content -Path $tofurcPath
        Write-ScriptLog "  ✓ Created $tofurcPath with plugin caching"
    } else {
        Write-ScriptLog "  ✓ $tofurcPath already exists"
    }
    
    # ===================================================================
    # VALIDATE PROVIDER
    # ===================================================================
    
    Write-ScriptLog "Validating Taliesin Hyper-V provider..."
    
    # Create a temporary test directory
    $testDir = Join-Path $env:TEMP "tofu-hyperv-test"
    if (Test-Path $testDir) {
        Remove-Item -Path $testDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null
    
    # Write minimal provider config
    $testConfig = @"
terraform {
  required_providers {
    hyperv = {
      source  = "taliesins/hyperv"
      version = "~> 1.2"
    }
  }
}
"@
    $testConfig | Set-Content -Path (Join-Path $testDir "main.tf")
    
    # Run tofu init to download provider
    Push-Location $testDir
    try {
        Write-ScriptLog "  Downloading Taliesin Hyper-V provider..."
        $initResult = & tofu init 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-ScriptLog "  ✓ Provider installed successfully"
            
            # Get provider version
            $providerVersion = & tofu providers 2>&1 | Select-String "taliesins/hyperv"
            if ($providerVersion) {
                Write-ScriptLog "  ✓ Provider: $providerVersion"
            }
        } else {
            Write-ScriptLog "  Provider installation failed" -Level 'Error'
            if ($ShowOutput) {
                $initResult | ForEach-Object { Write-ScriptLog "    $_" -Level 'Debug' }
            }
        }
    }
    finally {
        Pop-Location
        Remove-Item -Path $testDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # ===================================================================
    # SUMMARY
    # ===================================================================
    
    Write-ScriptLog ""
    Write-ScriptLog "╔══════════════════════════════════════════════════════════════╗"
    Write-ScriptLog "║        Taliesin Hyper-V Provider Setup Complete              ║"
    Write-ScriptLog "╚══════════════════════════════════════════════════════════════╝"
    Write-ScriptLog ""
    Write-ScriptLog "Next steps:"
    Write-ScriptLog "  1. Clone infrastructure repo:  aitherzero 0109"
    Write-ScriptLog "  2. Configure credentials in:   infrastructure/tofu-base-lab/terraform.tfvars"
    Write-ScriptLog "  3. Initialize:                 cd infrastructure/tofu-base-lab && tofu init"
    Write-ScriptLog "  4. Deploy:                     tofu plan && tofu apply"
    Write-ScriptLog ""
    Write-ScriptLog "For WinRM setup on remote Hyper-V host, run with -ConfigureWinRM"
    
    exit 0

} catch {
    Write-ScriptLog "Setup failed: $_" -Level 'Error'
    exit 1
}
