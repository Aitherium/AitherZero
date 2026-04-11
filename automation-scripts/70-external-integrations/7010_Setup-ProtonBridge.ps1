<#
.SYNOPSIS
    Fully automated Proton Mail Bridge setup for AitherOS SMTP relay.
.DESCRIPTION
    Downloads, installs, logs in via Bridge CLI, extracts SMTP credentials,
    stores them in AitherSecrets + .env, verifies SMTP, and sends test email.
    Zero manual steps beyond providing Proton login credentials.
.PARAMETER ProtonUser
    Proton email address (e.g., user@pm.me or user@proton.me)
.PARAMETER ProtonPass
    Proton account password (NOT the Bridge-generated SMTP password — that is extracted automatically)
.PARAMETER TotpCode
    2FA TOTP code if your Proton account has 2FA enabled
.PARAMETER SmtpPort
    Bridge SMTP port (default 1025)
.PARAMETER SkipDownload
    Skip downloading the installer (already have it)
.PARAMETER SkipInstall
    Skip installation (Bridge already installed)
.PARAMETER ResendVerification
    After setup, resend account verification emails via AitherMail
.EXAMPLE
    .\7010_Setup-ProtonBridge.ps1 -ProtonUser "user@pm.me" -ProtonPass "mypassword"
.EXAMPLE
    .\7010_Setup-ProtonBridge.ps1 -ProtonUser "user@pm.me" -ProtonPass "mypassword" -TotpCode "123456"
.EXAMPLE
    .\7010_Setup-ProtonBridge.ps1 -ProtonUser "user@pm.me" -ProtonPass "mypassword" -SkipInstall -ResendVerification
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProtonUser,
    [Parameter(Mandatory)][string]$ProtonPass,
    [string]$TotpCode,
    [int]$SmtpPort = 1025,
    [switch]$SkipDownload,
    [switch]$SkipInstall,
    [switch]$ResendVerification
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..\..\..\").Path.TrimEnd('\')
$EnvFile = Join-Path $RepoRoot '.env'
$SecretsUrl = 'http://localhost:8111'
$GenesisUrl = 'http://localhost:8001'
$ContainerBridgeHost = 'host.docker.internal'
$LocalBridgeHost = '127.0.0.1'

# ── Output helpers ──────────────────────────────────────────────────────
function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK    { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn  { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

function Get-SecretsApiKey {
    param([string]$EnvFilePath)

    foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }

    if (Test-Path $EnvFilePath) {
        foreach ($name in @('AITHER_ADMIN_KEY', 'AITHER_INTERNAL_SECRET', 'AITHER_MASTER_KEY')) {
            $line = Select-String -Path $EnvFilePath -Pattern "^$name=(.+)$" -CaseSensitive | Select-Object -First 1
            if ($line) {
                return $line.Matches[0].Groups[1].Value.Trim()
            }
        }
    }

    return 'dev-internal-secret-687579a3'
}

# ── Bridge exe search paths ─────────────────────────────────────────────
$BridgeSearchPaths = @(
    "$env:LOCALAPPDATA\Proton\Proton Mail Bridge",
    "$env:LOCALAPPDATA\Proton Mail Bridge",
    "$env:LOCALAPPDATA\Proton\Bridge",
    "C:\Program Files\Proton AG\Proton Mail Bridge",
    "C:\Program Files\Proton\Bridge",
    "C:\Program Files\Proton\Proton Mail Bridge",
    "C:\Program Files (x86)\Proton\Bridge",
    "$env:LOCALAPPDATA\Programs\Proton Mail Bridge"
)

function Find-BridgeExe {
    # Check via Start Menu shortcut first
    $lnk = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Proton Mail Bridge.lnk"
    if (Test-Path $lnk) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $target = $shell.CreateShortcut($lnk).TargetPath
            if ($target -and (Test-Path $target)) {
                return $target
            }
        } catch {}
    }

    # Search known directories
    foreach ($sp in $BridgeSearchPaths) {
        if (-not (Test-Path $sp)) { continue }
        $exe = Get-ChildItem $sp -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'bridge|proton' -and $_.Name -notmatch 'unins|update|crash' } |
               Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

# ============================================================================
# Step 1: Download Bridge installer
# ============================================================================
$InstallerPath = Join-Path $env:TEMP 'Bridge-Installer.exe'

if (-not $SkipDownload -and -not $SkipInstall) {
    Write-Step "Downloading Proton Mail Bridge installer..."

    if (Test-Path $InstallerPath) {
        Write-Warn "Installer already at $InstallerPath (reusing)"
    } else {
        try {
            Invoke-WebRequest -Uri 'https://proton.me/download/bridge/Bridge-Installer.exe' `
                              -OutFile $InstallerPath -UseBasicParsing
            $sizeMB = [math]::Round((Get-Item $InstallerPath).Length / 1MB, 1)
            Write-OK "Downloaded ($sizeMB MB)"
        } catch {
            Write-Err "Download failed: $($_.Exception.Message)"
            exit 1
        }
    }
}

# ============================================================================
# Step 2: Install Bridge (silent)
# ============================================================================
if (-not $SkipInstall) {
    $bridgeExe = Find-BridgeExe
    if ($bridgeExe) {
        Write-Step "Bridge already installed at $bridgeExe"
    } else {
        Write-Step "Installing Proton Mail Bridge (silent)..."
        if (-not (Test-Path $InstallerPath)) {
            Write-Err "Installer not found at $InstallerPath. Run without -SkipDownload."
            exit 1
        }
        try {
            $proc = Start-Process -FilePath $InstallerPath -ArgumentList '/S' -PassThru -Wait -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                Write-Warn "Installer exited with code $($proc.ExitCode)"
            }
            Start-Sleep -Seconds 3
            $bridgeExe = Find-BridgeExe
            if ($bridgeExe) {
                Write-OK "Installed at $bridgeExe"
            } else {
                Write-Err "Installation completed but bridge.exe not found."
                exit 1
            }
        } catch {
            Write-Err "Install failed: $($_.Exception.Message)"
            exit 1
        }
    }
} else {
    $bridgeExe = Find-BridgeExe
    if (-not $bridgeExe) {
        Write-Err "Bridge not found. Run without -SkipInstall."
        exit 1
    }
    Write-Step "Using existing Bridge at $bridgeExe"
}

# ============================================================================
# Step 3: Kill Bridge GUI (if running)
# ============================================================================
Write-Step "Stopping Bridge GUI (if running)..."
$bridgeProcs = Get-Process -Name 'Proton Mail Bridge', 'proton-bridge', 'bridge' -ErrorAction SilentlyContinue
if ($bridgeProcs) {
    $bridgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-OK "Bridge processes stopped."
} else {
    Write-OK "No Bridge processes running."
}

# ============================================================================
# Step 4: Login via Bridge CLI and extract SMTP credentials
# ============================================================================
Write-Step "Logging into Bridge via CLI..."

$smtpUser = $null
$smtpPass = $null
$cliSuccess = $false

# --- Attempt 1: Bridge CLI mode (--cli) ---
try {
    Write-Host "    Trying Bridge CLI mode..." -ForegroundColor Gray

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bridgeExe
    $psi.Arguments = '--cli'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $cliProc = [System.Diagnostics.Process]::Start($psi)

    # Collect output asynchronously
    $outputBuilder = [System.Text.StringBuilder]::new()
    $cliProc.BeginErrorReadLine()

    # Helper to read available output with timeout
    function Read-BridgeOutput {
        param([int]$TimeoutMs = 10000)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $chunk = ''
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            while ($cliProc.StandardOutput.Peek() -ge 0) {
                $char = [char]$cliProc.StandardOutput.Read()
                $chunk += $char
            }
            if ($chunk.Length -gt 0 -and $cliProc.StandardOutput.Peek() -lt 0) {
                Start-Sleep -Milliseconds 500
                if ($cliProc.StandardOutput.Peek() -lt 0) { break }
            }
            Start-Sleep -Milliseconds 200
        }
        [void]$outputBuilder.Append($chunk)
        return $chunk
    }

    # Wait for initial prompt
    $initial = Read-BridgeOutput -TimeoutMs 15000
    Write-Host "    CLI started." -ForegroundColor Gray

    # Send login command
    $cliProc.StandardInput.WriteLine('login')
    Start-Sleep -Milliseconds 1000
    $loginPrompt = Read-BridgeOutput -TimeoutMs 5000

    # Send username
    $cliProc.StandardInput.WriteLine($ProtonUser)
    Start-Sleep -Milliseconds 1000
    $passPrompt = Read-BridgeOutput -TimeoutMs 5000

    # Send password
    $cliProc.StandardInput.WriteLine($ProtonPass)
    Start-Sleep -Milliseconds 2000

    # Send TOTP if provided
    if ($TotpCode) {
        $totpPrompt = Read-BridgeOutput -TimeoutMs 5000
        $cliProc.StandardInput.WriteLine($TotpCode)
        Start-Sleep -Milliseconds 2000
    }

    # Wait for login result
    $loginResult = Read-BridgeOutput -TimeoutMs 30000
    Write-Host "    Login response received." -ForegroundColor Gray

    # Request account info to get SMTP credentials
    $cliProc.StandardInput.WriteLine('info')
    Start-Sleep -Milliseconds 2000
    $infoOutput = Read-BridgeOutput -TimeoutMs 10000

    # Also try 'list' command for credential info
    $cliProc.StandardInput.WriteLine('list')
    Start-Sleep -Milliseconds 2000
    $listOutput = Read-BridgeOutput -TimeoutMs 5000

    # Exit CLI
    $cliProc.StandardInput.WriteLine('exit')
    Start-Sleep -Milliseconds 1000
    if (-not $cliProc.HasExited) {
        $cliProc.Kill()
    }

    # Parse all collected output for SMTP credentials
    $allOutput = $outputBuilder.ToString() + $infoOutput + $listOutput

    # Bridge CLI typically shows:
    #   Username: user@pm.me
    #   Password: <bridge-generated-password>
    # or:
    #   SMTP username: user@pm.me
    #   SMTP password: <bridge-generated-password>
    if ($allOutput -match '(?:SMTP\s+)?[Uu]sername\s*:\s*(.+@.+)') {
        $smtpUser = $Matches[1].Trim()
    }
    if ($allOutput -match '(?:SMTP\s+)?[Pp]assword\s*:\s*(\S+)') {
        $smtpPass = $Matches[1].Trim()
    }

    if ($smtpUser -and $smtpPass) {
        $cliSuccess = $true
        Write-OK "CLI login successful. SMTP credentials extracted."
        Write-Host "    SMTP User: $smtpUser" -ForegroundColor Gray
    } elseif ($allOutput -match 'error|invalid|fail|wrong') {
        Write-Warn "CLI login may have failed. Output contained error indicators."
    }
} catch {
    Write-Warn "CLI mode failed: $($_.Exception.Message)"
    # Clean up any lingering process
    if ($cliProc -and -not $cliProc.HasExited) {
        $cliProc.Kill()
    }
}

# --- Attempt 2: Vault decryption fallback ---
if (-not $cliSuccess) {
    Write-Step "CLI mode unavailable. Trying vault decryption..."

    $vaultFound = $false
    $bridgeConfigDirs = @(
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'protonmail\bridge-v3'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'protonmail\bridge-v3'),
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'protonmail\bridge'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'protonmail\bridge')
    )

    foreach ($configDir in $bridgeConfigDirs) {
        $vaultFile = Join-Path $configDir 'vault.enc'
        if (Test-Path $vaultFile) {
            Write-Host "    Found vault: $vaultFile" -ForegroundColor Gray
            $vaultFound = $true

            try {
                # Try to get the vault key from Windows Credential Manager
                # Bridge v3 stores it as: protonmail/bridge-v3/users/bridge-vault-key
                $credTargets = @(
                    'protonmail/bridge-v3/users/bridge-vault-key',
                    'protonmail/bridge-v3/bridge-vault-key',
                    'Proton Mail Bridge'
                )

                $vaultKey = $null

                # Method 1: CredentialManager module
                if (Get-Module -ListAvailable -Name 'CredentialManager' -ErrorAction SilentlyContinue) {
                    foreach ($target in $credTargets) {
                        try {
                            $cred = Get-StoredCredential -Target $target -ErrorAction Stop
                            if ($cred) {
                                $vaultKey = $cred.GetNetworkCredential().Password
                                Write-Host "    Vault key retrieved via CredentialManager ($target)" -ForegroundColor Gray
                                break
                            }
                        } catch {}
                    }
                }

                # Method 2: P/Invoke CredRead if module not available
                if (-not $vaultKey) {
                    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class CredManager {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string ReadCredential(string target) {
        IntPtr credPtr;
        if (CredRead(target, 1, 0, out credPtr)) {
            try {
                var cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
                if (cred.CredentialBlobSize > 0) {
                    return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
                }
            } finally {
                CredFree(credPtr);
            }
        }
        return null;
    }
}
'@ -ErrorAction SilentlyContinue

                    foreach ($target in $credTargets) {
                        try {
                            $key = [CredManager]::ReadCredential($target)
                            if ($key) {
                                $vaultKey = $key
                                Write-Host "    Vault key retrieved via P/Invoke ($target)" -ForegroundColor Gray
                                break
                            }
                        } catch {}
                    }
                }

                if ($vaultKey) {
                    # Decrypt vault.enc (AES-256-GCM)
                    # Bridge vault format: 12-byte nonce + ciphertext + 16-byte auth tag
                    $vaultBytes = [System.IO.File]::ReadAllBytes($vaultFile)

                    # Try decryption with AES-GCM (requires .NET 5+ or BouncyCastle)
                    try {
                        $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($vaultKey)
                        # SHA-256 hash the key to get exactly 32 bytes for AES-256
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $aesKey = $sha.ComputeHash($keyBytes)

                        $nonce = $vaultBytes[0..11]
                        $tag = $vaultBytes[($vaultBytes.Length - 16)..($vaultBytes.Length - 1)]
                        $ciphertext = $vaultBytes[12..($vaultBytes.Length - 17)]
                        $plaintext = [byte[]]::new($ciphertext.Length)

                        $aesGcm = [System.Security.Cryptography.AesGcm]::new($aesKey)
                        $aesGcm.Decrypt($nonce, $ciphertext, $tag, $plaintext)
                        $aesGcm.Dispose()

                        $vaultJson = [System.Text.Encoding]::UTF8.GetString($plaintext)
                        $vault = $vaultJson | ConvertFrom-Json

                        # Extract SMTP credentials from vault JSON
                        # Vault structure varies but typically has users[].addresses[].smtp
                        if ($vault.Users) {
                            $user = $vault.Users | Select-Object -First 1
                            if ($user.BridgePass) { $smtpPass = $user.BridgePass }
                            if ($user.Addresses) {
                                $smtpUser = ($user.Addresses | Select-Object -First 1).Address
                                if (-not $smtpUser) { $smtpUser = $user.Addresses[0] }
                            }
                            if (-not $smtpUser -and $user.Username) { $smtpUser = $user.Username }
                        }
                        # Alternative flat structure
                        if (-not $smtpPass -and $vault.bridge_password) { $smtpPass = $vault.bridge_password }
                        if (-not $smtpUser -and $vault.username) { $smtpUser = $vault.username }

                        if ($smtpUser -and $smtpPass) {
                            $cliSuccess = $true
                            Write-OK "Vault decrypted. SMTP credentials extracted."
                            Write-Host "    SMTP User: $smtpUser" -ForegroundColor Gray
                        } else {
                            Write-Warn "Vault decrypted but credentials not found in expected structure."
                            Write-Host "    Vault keys: $(($vault.PSObject.Properties.Name) -join ', ')" -ForegroundColor Gray
                        }
                    } catch {
                        Write-Warn "AES-GCM decryption failed: $($_.Exception.Message)"
                    }
                } else {
                    Write-Warn "Could not retrieve vault key from Credential Manager."
                }
            } catch {
                Write-Warn "Vault decryption error: $($_.Exception.Message)"
            }
            break
        }
    }

    if (-not $vaultFound) {
        Write-Warn "No vault.enc found. Bridge may not have any accounts configured."
    }
}

# --- Attempt 3: gRPC config fallback ---
if (-not $cliSuccess) {
    Write-Step "Checking Bridge gRPC config for credentials..."

    foreach ($configDir in $bridgeConfigDirs) {
        $grpcConfig = Join-Path $configDir 'grpcServerConfig.json'
        if (Test-Path $grpcConfig) {
            Write-Host "    Found gRPC config: $grpcConfig" -ForegroundColor Gray
            try {
                $grpc = Get-Content $grpcConfig -Raw | ConvertFrom-Json
                Write-Host "    gRPC port: $($grpc.port)" -ForegroundColor Gray
            } catch {}
        }
    }

    # Check Bridge logs for credential output
    foreach ($configDir in $bridgeConfigDirs) {
        $logDir = Join-Path $configDir 'logs'
        if (Test-Path $logDir) {
            $latestLog = Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $logContent = Get-Content $latestLog.FullName -Tail 200 | Out-String
                if ($logContent -match 'SMTP\s+[Pp]assword\s*[:=]\s*(\S+)') {
                    $smtpPass = $Matches[1]
                }
                if ($logContent -match 'address\s*[:=]\s*(\S+@\S+)') {
                    $smtpUser = $Matches[1]
                }
            }
        }
    }
}

# --- Final check: do we have credentials? ---
if (-not $smtpUser -or -not $smtpPass) {
    # Start Bridge in GUI mode so user can log in
    Write-Step "Could not extract SMTP credentials automatically."
    Write-Host ""
    Write-Host "    Bridge needs to be logged in first. Starting Bridge GUI..." -ForegroundColor Yellow
    Start-Process -FilePath $bridgeExe
    Write-Host ""
    Write-Host "    Steps:" -ForegroundColor White
    Write-Host "      1. Log into your Proton account in the Bridge GUI" -ForegroundColor White
    Write-Host "      2. Go to Settings > IMAP/SMTP to find the generated password" -ForegroundColor White
    Write-Host "      3. Re-run this script with -SkipInstall" -ForegroundColor White
    Write-Host ""

    # Offer manual credential entry as last resort
    $manual = Read-Host "    Or enter credentials now? (y/N)"
    if ($manual -eq 'y' -or $manual -eq 'Y') {
        $smtpUser = Read-Host "    SMTP username (email)"
        $secPass = Read-Host "    SMTP password (Bridge-generated)" -AsSecureString
        $smtpPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
        )
        if (-not $smtpUser -or -not $smtpPass) {
            Write-Err "Credentials required. Exiting."
            exit 1
        }
    } else {
        exit 0
    }
}

# ============================================================================
# Step 5: Store credentials in AitherSecrets
# ============================================================================
Write-Step "Storing SMTP credentials in AitherSecrets..."

$secrets = @{
    'PROTON_BRIDGE_CREDS' = "${smtpUser}:${smtpPass}"
    'AITHER_SMTP_HOST'    = $ContainerBridgeHost
    'AITHER_SMTP_PORT'    = "$SmtpPort"
    'AITHER_SMTP_USER'    = $smtpUser
    'AITHER_SMTP_PASS'    = $smtpPass
    'AITHER_SMTP_FROM'    = $smtpUser
    'AITHER_IMAP_HOST'    = $ContainerBridgeHost
    'AITHER_IMAP_PORT'    = '1143'
    'AITHER_IMAP_USER'    = $smtpUser
    'AITHER_IMAP_PASS'    = $smtpPass
}

try {
    Invoke-RestMethod -Uri "$SecretsUrl/health" -TimeoutSec 3 -ErrorAction Stop | Out-Null

    $secretsApiKey = Get-SecretsApiKey -EnvFilePath $EnvFile
    $headers = @{ 'X-API-Key' = $secretsApiKey }

    foreach ($kv in $secrets.GetEnumerator()) {
        $body = @{
            name = $kv.Key
            value = $kv.Value
            secret_type = 'generic'
            access_level = 'internal'
        } | ConvertTo-Json
        Invoke-RestMethod -Uri "$SecretsUrl/secrets?service=AitherMail" -Method Post -Body $body `
                          -Headers $headers -ContentType 'application/json' -ErrorAction Stop | Out-Null
    }
    Write-OK "Bridge SMTP + IMAP secrets stored in AitherSecrets."
} catch {
    Write-Warn "AitherSecrets not reachable: $($_.Exception.Message)"
    Write-Warn "Falling back to .env file only."
}

# ============================================================================
# Step 6: Update .env
# ============================================================================
Write-Step "Updating .env..."

if (Test-Path $EnvFile) {
    $envContent = Get-Content $EnvFile -Raw

    $updates = @{
        'AITHER_SMTP_HOST=.*'  = "AITHER_SMTP_HOST=$ContainerBridgeHost"
        'AITHER_SMTP_PORT=.*'  = "AITHER_SMTP_PORT=$SmtpPort"
        'AITHER_SMTP_USER=.*'  = "AITHER_SMTP_USER=$smtpUser"
        'AITHER_SMTP_PASS=.*'  = "AITHER_SMTP_PASS=$smtpPass"
        'AITHER_SMTP_FROM=.*'  = "AITHER_SMTP_FROM=$smtpUser"
        'AITHER_IMAP_HOST=.*'  = "AITHER_IMAP_HOST=$ContainerBridgeHost"
        'AITHER_IMAP_PORT=.*'  = 'AITHER_IMAP_PORT=1143'
        'AITHER_IMAP_USER=.*'  = "AITHER_IMAP_USER=$smtpUser"
        'AITHER_IMAP_PASS=.*'  = "AITHER_IMAP_PASS=$smtpPass"
    }

    foreach ($kv in $updates.GetEnumerator()) {
        if ($envContent -match $kv.Key) {
            $envContent = $envContent -replace $kv.Key, $kv.Value
        } else {
            $envContent += "`n$($kv.Value)"
        }
    }

    Set-Content -Path $EnvFile -Value $envContent.TrimEnd() -NoNewline
    Write-OK "Updated $EnvFile"
} else {
    # Create .env with SMTP vars
    $envLines = @(
        "AITHER_SMTP_HOST=$ContainerBridgeHost",
        "AITHER_SMTP_PORT=$SmtpPort",
        "AITHER_SMTP_USER=$smtpUser",
        "AITHER_SMTP_PASS=$smtpPass",
        "AITHER_SMTP_FROM=$smtpUser",
        "AITHER_IMAP_HOST=$ContainerBridgeHost",
        'AITHER_IMAP_PORT=1143',
        "AITHER_IMAP_USER=$smtpUser",
        "AITHER_IMAP_PASS=$smtpPass"
    )
    Set-Content -Path $EnvFile -Value ($envLines -join "`n") -NoNewline
    Write-OK "Created $EnvFile"
}

# ============================================================================
# Step 7: Restart Bridge in GUI mode
# ============================================================================
Write-Step "Starting Bridge in GUI mode for ongoing SMTP service..."

# Make sure CLI process is dead
$bridgeProcs = Get-Process -Name 'Proton Mail Bridge', 'proton-bridge', 'bridge' -ErrorAction SilentlyContinue
if ($bridgeProcs) {
    $bridgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Start-Process -FilePath $bridgeExe
Write-OK "Bridge launched."

# Wait for SMTP port to come up
Write-Host "    Waiting for SMTP port $SmtpPort..." -ForegroundColor Gray
$maxWait = 60
$waited = 0
$smtpReady = $false

while ($waited -lt $maxWait) {
    $tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port $SmtpPort `
                              -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($tcp) { $smtpReady = $true; break }
    Start-Sleep -Seconds 3
    $waited += 3
}

if ($smtpReady) {
    Write-OK "SMTP port $SmtpPort is listening."
} else {
    Write-Warn "SMTP port $SmtpPort not available after ${maxWait}s. Bridge may need manual login."
}

# ============================================================================
# Step 8: Restart Docker containers
# ============================================================================
Write-Step "Restarting Docker containers to pick up SMTP config..."

try {
    docker restart aitheros-security-core 2>$null
    Write-OK "aitheros-security-core restarted."
} catch {
    Write-Warn "Docker restart failed: $($_.Exception.Message)"
}

# ============================================================================
# Step 9: Verify SMTP connection
# ============================================================================
Write-Step "Verifying SMTP connectivity..."

try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $tcpClient.Connect('127.0.0.1', $SmtpPort)
    $stream = $tcpClient.GetStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $banner = $reader.ReadLine()
    $tcpClient.Close()

    if ($banner -match '220') {
        Write-OK "SMTP banner: $banner"
    } else {
        Write-Warn "Unexpected SMTP response: $banner"
    }
} catch {
    Write-Err "SMTP connection failed: $($_.Exception.Message)"
}

# ============================================================================
# Step 10: Send test email
# ============================================================================
Write-Step "Sending test email to $smtpUser..."

$emailSent = $false

# Try with SSL first, then without (STARTTLS)
$secSmtpPass = New-Object System.Security.SecureString
foreach ($char in $smtpPass.ToCharArray()) {
    $secSmtpPass.AppendChar($char)
}
$secSmtpPass.MakeReadOnly()
$cred = New-Object System.Management.Automation.PSCredential($smtpUser, $secSmtpPass)
$emailSubject = "AitherOS SMTP Test - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$emailBody = @"
SMTP relay is working!

Sent from AitherZero automation (7010_Setup-ProtonBridge.ps1).
Proton Mail Bridge on 127.0.0.1:$SmtpPort.

Timestamp: $(Get-Date -Format 'o')
"@

try {
    Send-MailMessage -From $smtpUser -To $smtpUser `
                     -Subject $emailSubject -Body $emailBody `
                     -SmtpServer '127.0.0.1' -Port $SmtpPort `
                     -Credential $cred -UseSsl -ErrorAction Stop
    $emailSent = $true
    Write-OK "Test email sent (SSL)!"
} catch {
    Write-Warn "SSL failed: $($_.Exception.Message)"
    try {
        Send-MailMessage -From $smtpUser -To $smtpUser `
                         -Subject $emailSubject -Body $emailBody `
                         -SmtpServer '127.0.0.1' -Port $SmtpPort `
                         -Credential $cred -ErrorAction Stop
        $emailSent = $true
        Write-OK "Test email sent (STARTTLS)!"
    } catch {
        Write-Warn "Test email failed: $($_.Exception.Message)"
    }
}

# ============================================================================
# Step 11: Resend verification emails (optional)
# ============================================================================
if ($ResendVerification -or $emailSent) {
    Write-Step "Resending account verification emails..."

    $recipients = @('dp27148@gmail.com', 'david@aitherium.com')

    foreach ($recipient in $recipients) {
        # Try via Genesis/AitherMail API first
        try {
            $mailBody = @{
                to      = $recipient
                subject = "AitherOS Account Verification (Resent)"
                body    = "Your AitherOS account is ready. SMTP relay is now configured. Please log in to verify your account."
                from    = $smtpUser
            } | ConvertTo-Json

            Invoke-RestMethod -Uri "$GenesisUrl/mail/send" -Method POST `
                              -Body $mailBody -ContentType 'application/json' `
                              -TimeoutSec 10 -ErrorAction Stop | Out-Null
            Write-OK "Verification email sent to $recipient (via Genesis)"
        } catch {
            # Fallback: try via Docker exec into security-core
            try {
                docker exec aitheros-security-core python -c @"
import smtplib
from email.mime.text import MIMEText
msg = MIMEText('Your AitherOS account is ready. SMTP is configured.')
msg['Subject'] = 'AitherOS Account Verification (Resent)'
msg['From'] = '$smtpUser'
msg['To'] = '$recipient'
with smtplib.SMTP('host.docker.internal', $SmtpPort) as s:
    s.starttls()
    s.login('$smtpUser', '$smtpPass')
    s.send_message(msg)
"@ 2>$null
                Write-OK "Verification email sent to $recipient (via Docker)"
            } catch {
                # Fallback: direct PowerShell
                try {
                    Send-MailMessage -From $smtpUser -To $recipient `
                                     -Subject "AitherOS Account Verification (Resent)" `
                                     -Body "Your AitherOS account is ready. SMTP relay is now configured." `
                                     -SmtpServer '127.0.0.1' -Port $SmtpPort `
                                     -Credential $cred -UseSsl -ErrorAction Stop
                    Write-OK "Verification email sent to $recipient (via PowerShell)"
                } catch {
                    Write-Warn "Could not send to ${recipient}: $($_.Exception.Message)"
                }
            }
        }
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Proton Mail Bridge setup complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  SMTP Host:    127.0.0.1:$SmtpPort (local)" -ForegroundColor White
Write-Host "  SMTP Docker:  host.docker.internal:$SmtpPort" -ForegroundColor White
Write-Host "  SMTP User:    $smtpUser" -ForegroundColor White
Write-Host "  Test email:   $(if ($emailSent) { 'Sent' } else { 'Failed' })" -ForegroundColor $(if ($emailSent) { 'Green' } else { 'Yellow' })
Write-Host ""
Write-Host "  Secrets stored in: AitherSecrets + .env" -ForegroundColor Gray
Write-Host ""
