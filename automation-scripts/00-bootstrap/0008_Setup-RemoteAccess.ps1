#Requires -Version 7.0

<#
.SYNOPSIS
    Configures WinRM, PSRemoting, and firewall rules for remote AitherOS management.

.DESCRIPTION
    Zero-touch remote access configuration. Run this ON the target machine (via
    bootstrap.ps1 -InstallProfile Node) to enable all remote management capabilities.

    After this script runs, the machine is fully remotely manageable — no further
    manual configuration needed. Subsequent AitherNode deployments, updates, and
    management all happen remotely from the dev machine.

    What it configures:
    - WinRM service (HTTPS preferred, HTTP fallback)
    - PowerShell Remoting (Enable-PSRemoting)
    - Firewall rules for WinRM (5985, 5986)
    - Firewall rules for AitherOS services (8001, 8080-8082, 8111, 8121, 8125, 8136, 8150)
    - Firewall rules for Docker (2375, 2376)
    - Firewall rules for SSH (22) if OpenSSH is present
    - TrustedHosts configuration (configurable)
    - Self-signed certificate for WinRM HTTPS
    - Optional SSH server installation (Server 2019+)

.PARAMETER TrustedHosts
    Comma-separated list of trusted hosts for WinRM. Default: "*" for initial setup.
    Recommended to restrict in production via Set-Item WSMan:\localhost\Client\TrustedHosts.

.PARAMETER EnableSSH
    Also install and configure OpenSSH Server for SSH-based remoting.

.PARAMETER SkipFirewall
    Skip firewall rule creation (e.g., if managed externally).

.PARAMETER RestrictSubnet
    Restrict firewall rules to a specific subnet (e.g., "192.168.1.0/24").
    Default: any (all sources allowed).

.PARAMETER NodeName
    Friendly name for this node. Used in certificate CN and WinRM endpoint config.
    Default: $env:COMPUTERNAME.

.PARAMETER DryRun
    Show what would be configured without making changes.

.EXAMPLE
    # Run on the server itself via bootstrap:
    iwr -useb https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.ps1 | iex
    # bootstrap.ps1 calls this automatically when profile is "Node"

.EXAMPLE
    # Run standalone on the server:
    .\0008_Setup-RemoteAccess.ps1 -EnableSSH -RestrictSubnet "192.168.1.0/24"

.NOTES
    Category: bootstrap
    Dependencies: none (runs on bare Server Core)
    Platform: Windows
    Exit Codes:
        0 - Success
        1 - Not running as Administrator
        2 - WinRM configuration failed
        3 - Firewall configuration failed
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TrustedHosts = "*",
    [switch]$EnableSSH,
    [switch]$SkipFirewall,
    [string]$RestrictSubnet,
    [string]$NodeName = $env:COMPUTERNAME,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ============================================================================
# HELPERS
# ============================================================================

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SKIP"    { "DarkGray" }
        default   { "Cyan" }
    }
    $prefix = switch ($Status) {
        "OK"    { "[+]" }
        "WARN"  { "[!]" }
        "ERROR" { "[-]" }
        "SKIP"  { "[~]" }
        default { "[*]" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Test-AdminPrivileges {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return (id -u) -eq 0
}

# ============================================================================
# PRE-FLIGHT
# ============================================================================

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  AitherOS Remote Access Configuration" -ForegroundColor Cyan
Write-Host "  Node: $NodeName" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

if (-not ($IsWindows -or $env:OS -eq "Windows_NT")) {
    Write-Step "This script is Windows-only. On Linux, use SSH (already available)." "SKIP"
    Write-Step "Configuring Linux firewall rules for AitherOS ports..." "INFO"

    if (-not $SkipFirewall -and -not $DryRun) {
        # Linux: Use ufw or firewalld
        $hasUfw = Get-Command ufw -ErrorAction SilentlyContinue
        $hasFirewalld = Get-Command firewall-cmd -ErrorAction SilentlyContinue

        $aitherPorts = @(8001, 8080, 8081, 8082, 8111, 8121, 8125, 8136, 8150, 3000, 2375, 2376)

        if ($hasUfw) {
            foreach ($port in $aitherPorts) {
                if ($RestrictSubnet) {
                    sudo ufw allow from $RestrictSubnet to any port $port proto tcp 2>&1 | Out-Null
                } else {
                    sudo ufw allow $port/tcp 2>&1 | Out-Null
                }
            }
            sudo ufw --force enable 2>&1 | Out-Null
            Write-Step "UFW rules configured for AitherOS ports" "OK"
        } elseif ($hasFirewalld) {
            foreach ($port in $aitherPorts) {
                sudo firewall-cmd --permanent --add-port="$port/tcp" 2>&1 | Out-Null
            }
            sudo firewall-cmd --reload 2>&1 | Out-Null
            Write-Step "Firewalld rules configured for AitherOS ports" "OK"
        } else {
            Write-Step "No firewall manager found (ufw/firewalld). Skipping." "WARN"
        }
    }
    exit 0
}

# Windows path continues
if (-not (Test-AdminPrivileges)) {
    Write-Step "This script requires Administrator privileges." "ERROR"
    Write-Step "Re-run from an elevated PowerShell prompt." "ERROR"
    exit 1
}

if ($DryRun) {
    Write-Step "DRY RUN MODE - No changes will be made" "WARN"
}

$configuredItems = @()
$warnings = @()

# ============================================================================
# PHASE 1: WINRM SERVICE
# ============================================================================

Write-Host ""
Write-Step "Phase 1: WinRM Service Configuration" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

try {
    $winrmStatus = Get-Service WinRM -ErrorAction SilentlyContinue

    if (-not $winrmStatus -or $winrmStatus.Status -ne 'Running') {
        if ($DryRun) {
            Write-Step "Would enable and start WinRM service" "SKIP"
        } else {
            # Enable WinRM - this is the core of remote access
            if ($PSCmdlet.ShouldProcess("WinRM Service", "Enable and configure")) {
                # Start WinRM first
                Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service -Name WinRM -ErrorAction SilentlyContinue

                # Enable PSRemoting (idempotent, safe to re-run)
                Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop

                Write-Step "WinRM service enabled and started" "OK"
                $configuredItems += "WinRM Service"
            }
        }
    } else {
        Write-Step "WinRM service already running" "OK"
    }

    # Configure WinRM settings for remote management
    if (-not $DryRun) {
        # Allow unencrypted for LAN (HTTPS preferred but HTTP needed for initial setup)
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true -Force -ErrorAction SilentlyContinue
        # Increase max envelope size for large payloads
        Set-Item WSMan:\localhost\Service\MaxEnvelopeSizekb -Value 8192 -Force -ErrorAction SilentlyContinue
        # Set max concurrent operations
        Set-Item WSMan:\localhost\Shell\MaxConcurrentUsers -Value 10 -Force -ErrorAction SilentlyContinue
        # Set max memory per shell
        Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 -Force -ErrorAction SilentlyContinue
        # Set idle timeout to 4 hours
        Set-Item WSMan:\localhost\Shell\IdleTimeout -Value 14400000 -Force -ErrorAction SilentlyContinue

        Write-Step "WinRM service settings optimized" "OK"
    }

    # Configure TrustedHosts
    if (-not $DryRun) {
        $currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
        if ($currentTrusted -ne $TrustedHosts) {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $TrustedHosts -Force
            Write-Step "TrustedHosts set to: $TrustedHosts" "OK"
            if ($TrustedHosts -eq "*") {
                $warnings += "TrustedHosts is set to '*'. Restrict in production: Set-Item WSMan:\localhost\Client\TrustedHosts -Value '<IP>'"
            }
        }
        $configuredItems += "TrustedHosts"
    }
} catch {
    Write-Step "WinRM configuration failed: $_" "ERROR"
    exit 2
}

# ============================================================================
# PHASE 2: WINRM HTTPS (SELF-SIGNED CERT)
# ============================================================================

Write-Host ""
Write-Step "Phase 2: WinRM HTTPS Configuration" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

try {
    # Check for existing HTTPS listener
    $httpsListener = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue |
        Where-Object { $_.Keys -contains "Transport=HTTPS" }

    if (-not $httpsListener) {
        if ($DryRun) {
            Write-Step "Would create self-signed cert and HTTPS listener" "SKIP"
        } else {
            # Create self-signed certificate
            $dnsNames = @($NodeName, $env:COMPUTERNAME, "localhost")

            # Add all IP addresses
            $ipAddresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -ne "127.0.0.1" } |
                Select-Object -ExpandProperty IPAddress
            $dnsNames += $ipAddresses

            $cert = New-SelfSignedCertificate `
                -CertStoreLocation "Cert:\LocalMachine\My" `
                -DnsName $dnsNames `
                -Subject "CN=$NodeName-AitherOS-WinRM" `
                -KeyAlgorithm RSA `
                -KeyLength 2048 `
                -NotAfter (Get-Date).AddYears(5) `
                -FriendlyName "AitherOS WinRM HTTPS" `
                -ErrorAction Stop

            # Create HTTPS listener
            New-Item -Path WSMan:\localhost\Listener `
                -Transport HTTPS `
                -Address * `
                -CertificateThumbprint $cert.Thumbprint `
                -Force -ErrorAction Stop | Out-Null

            Write-Step "HTTPS listener created with self-signed certificate" "OK"
            Write-Step "Certificate thumbprint: $($cert.Thumbprint)" "INFO"
            $configuredItems += "WinRM HTTPS"
        }
    } else {
        Write-Step "HTTPS listener already exists" "OK"
    }
} catch {
    Write-Step "HTTPS setup failed (HTTP still available): $_" "WARN"
    $warnings += "WinRM HTTPS not configured — using HTTP only. Add cert later for production."
}

# ============================================================================
# PHASE 3: PSREMOTING CONFIGURATION
# ============================================================================

Write-Host ""
Write-Step "Phase 3: PowerShell Remoting" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

try {
    # Verify PSRemoting is working
    $psRemotingEnabled = $false
    try {
        $result = Test-WSMan -ErrorAction Stop
        $psRemotingEnabled = $true
    } catch {
        $psRemotingEnabled = $false
    }

    if (-not $psRemotingEnabled) {
        if ($DryRun) {
            Write-Step "Would enable PowerShell Remoting" "SKIP"
        } else {
            Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
            Write-Step "PowerShell Remoting enabled" "OK"
        }
    } else {
        Write-Step "PowerShell Remoting already enabled" "OK"
    }

    # Create a dedicated AitherOS session configuration
    if (-not $DryRun) {
        $sessionConfigName = "AitherOS.RemoteManagement"
        $existingConfig = Get-PSSessionConfiguration -Name $sessionConfigName -ErrorAction SilentlyContinue

        if (-not $existingConfig) {
            Register-PSSessionConfiguration -Name $sessionConfigName `
                -RunAsCredential $null `
                -ThreadOptions ReuseThread `
                -MaximumReceivedDataSizePerCommandMB 500 `
                -MaximumReceivedObjectSizeMB 500 `
                -Force -ErrorAction SilentlyContinue | Out-Null

            Write-Step "Registered session config: $sessionConfigName" "OK"
            $configuredItems += "PSSession Config"
        } else {
            Write-Step "Session config '$sessionConfigName' already exists" "OK"
        }
    }
} catch {
    Write-Step "PSRemoting configuration issue: $_" "WARN"
    $warnings += "PSRemoting may need manual verification"
}

# ============================================================================
# PHASE 4: FIREWALL RULES
# ============================================================================

Write-Host ""
Write-Step "Phase 4: Firewall Rules" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

if ($SkipFirewall) {
    Write-Step "Firewall configuration skipped (-SkipFirewall)" "SKIP"
} else {
    # Define all required firewall rules
    $firewallRules = @(
        # WinRM
        @{ Name = "AitherOS-WinRM-HTTP";  Port = 5985;  Description = "WinRM HTTP for AitherOS management" }
        @{ Name = "AitherOS-WinRM-HTTPS"; Port = 5986;  Description = "WinRM HTTPS for AitherOS management" }

        # Core AitherOS services
        @{ Name = "AitherOS-Genesis";     Port = 8001;  Description = "AitherOS Genesis orchestrator" }
        @{ Name = "AitherOS-Node";        Port = 8080;  Description = "AitherOS Node service" }
        @{ Name = "AitherOS-Pulse";       Port = 8081;  Description = "AitherOS Pulse health monitor" }
        @{ Name = "AitherOS-Watch";       Port = 8082;  Description = "AitherOS Watch service" }
        @{ Name = "AitherOS-Secrets";     Port = 8111;  Description = "AitherOS Secrets vault" }
        @{ Name = "AitherOS-Chronicle";   Port = 8121;  Description = "AitherOS Chronicle logging" }
        @{ Name = "AitherOS-Mesh";        Port = 8125;  Description = "AitherOS Mesh networking" }
        @{ Name = "AitherOS-Strata";      Port = 8136;  Description = "AitherOS Strata data layer" }
        @{ Name = "AitherOS-MicroSched";  Port = 8150;  Description = "AitherOS MicroScheduler LLM router" }
        @{ Name = "AitherOS-SecurityCore"; Port = 8117; Description = "AitherOS SecurityCore (Flux+Identity)" }
        @{ Name = "AitherOS-Veil";        Port = 3000;  Description = "AitherOS Veil dashboard" }

        # Docker
        @{ Name = "AitherOS-Docker";      Port = 2375;  Description = "Docker daemon (unencrypted)" }
        @{ Name = "AitherOS-Docker-TLS";  Port = 2376;  Description = "Docker daemon (TLS)" }

        # Database
        @{ Name = "AitherOS-Postgres";    Port = 5432;  Description = "PostgreSQL database" }
        @{ Name = "AitherOS-Redis";       Port = 6379;  Description = "Redis cache" }

        # SSH (if needed)
        @{ Name = "AitherOS-SSH";         Port = 22;    Description = "SSH for PowerShell remoting" }
    )

    $rulesCreated = 0
    foreach ($rule in $firewallRules) {
        $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue

        if (-not $existing) {
            if ($DryRun) {
                Write-Step "Would create: $($rule.Name) (TCP/$($rule.Port))" "SKIP"
            } else {
                $params = @{
                    DisplayName = $rule.Name
                    Direction   = "Inbound"
                    Protocol    = "TCP"
                    LocalPort   = $rule.Port
                    Action      = "Allow"
                    Profile     = "Domain,Private"
                    Description = $rule.Description
                    Enabled     = "True"
                }

                if ($RestrictSubnet) {
                    $params['RemoteAddress'] = $RestrictSubnet
                }

                New-NetFirewallRule @params -ErrorAction SilentlyContinue | Out-Null
                $rulesCreated++
            }
        }
    }

    if ($rulesCreated -gt 0) {
        Write-Step "$rulesCreated firewall rules created" "OK"
        $configuredItems += "Firewall Rules ($rulesCreated)"
    } else {
        Write-Step "All firewall rules already exist" "OK"
    }
}

# ============================================================================
# PHASE 5: SSH SERVER (OPTIONAL)
# ============================================================================

Write-Host ""
Write-Step "Phase 5: SSH Server" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

if ($EnableSSH) {
    try {
        $sshServer = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue

        if ($sshServer.State -ne "Installed") {
            if ($DryRun) {
                Write-Step "Would install OpenSSH Server" "SKIP"
            } else {
                Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" -ErrorAction Stop | Out-Null

                # Configure SSH
                Start-Service sshd -ErrorAction Stop
                Set-Service -Name sshd -StartupType Automatic

                # Set PowerShell 7 as default SSH shell (if available)
                $pwsh7 = Get-Command pwsh -ErrorAction SilentlyContinue
                if ($pwsh7) {
                    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
                        -Name DefaultShell `
                        -Value $pwsh7.Source `
                        -PropertyType String `
                        -Force | Out-Null
                    Write-Step "SSH default shell set to PowerShell 7" "OK"
                }

                Write-Step "OpenSSH Server installed and configured" "OK"
                $configuredItems += "SSH Server"
            }
        } else {
            # Ensure it's running
            $sshService = Get-Service sshd -ErrorAction SilentlyContinue
            if ($sshService.Status -ne 'Running') {
                Start-Service sshd -ErrorAction SilentlyContinue
                Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
            }
            Write-Step "OpenSSH Server already installed" "OK"
        }
    } catch {
        Write-Step "SSH Server setup failed: $_" "WARN"
        $warnings += "SSH Server could not be installed. WinRM still available."
    }
} else {
    Write-Step "SSH Server setup skipped (use -EnableSSH to install)" "SKIP"
}

# ============================================================================
# PHASE 6: VERIFICATION
# ============================================================================

Write-Host ""
Write-Step "Phase 6: Verification" "INFO"
Write-Host ("-" * 40) -ForegroundColor DarkGray

if (-not $DryRun) {
    # Test WinRM is responding
    try {
        $wsmanResult = Test-WSMan -ErrorAction Stop
        Write-Step "WinRM responding: ProductVersion=$($wsmanResult.ProductVersion)" "OK"
    } catch {
        Write-Step "WinRM test failed: $_" "ERROR"
    }

    # Show listeners
    $listeners = Get-ChildItem WSMan:\localhost\Listener -ErrorAction SilentlyContinue
    foreach ($listener in $listeners) {
        $transport = ($listener.Keys | Where-Object { $_ -like "Transport=*" }) -replace "Transport=", ""
        $address = ($listener.Keys | Where-Object { $_ -like "Address=*" }) -replace "Address=", ""
        Write-Step "Listener: $transport on $address" "OK"
    }

    # Test local PSRemoting
    try {
        $testSession = New-PSSession -ComputerName localhost -ErrorAction Stop
        Remove-PSSession $testSession
        Write-Step "Local PSRemoting test: SUCCESS" "OK"
    } catch {
        Write-Step "Local PSRemoting test failed (may be normal on Server Core): $_" "WARN"
    }

    # Show IP addresses for connection info
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" }

    if ($ips) {
        Write-Host ""
        Write-Step "This machine is now remotely accessible at:" "INFO"
        foreach ($ip in $ips) {
            Write-Host "    $($ip.IPAddress) ($($ip.InterfaceAlias))" -ForegroundColor White
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host "  Remote Access Configuration Complete" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Cyan
Write-Host ""

if ($configuredItems.Count -gt 0) {
    Write-Host "  Configured:" -ForegroundColor Yellow
    foreach ($item in $configuredItems) {
        Write-Host "    [+] $item" -ForegroundColor Green
    }
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  Warnings:" -ForegroundColor Yellow
    foreach ($warn in $warnings) {
        Write-Host "    [!] $warn" -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "  From your dev machine, connect with:" -ForegroundColor Cyan
Write-Host "    Enter-PSSession -ComputerName $NodeName -Credential (Get-Credential)" -ForegroundColor White
Write-Host ""
Write-Host "  Or deploy AitherNode remotely:" -ForegroundColor Cyan
Write-Host "    Invoke-AitherElysiumDeploy -ComputerName $NodeName" -ForegroundColor White
Write-Host ""

exit 0
