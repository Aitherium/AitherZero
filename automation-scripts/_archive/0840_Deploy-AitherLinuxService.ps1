#Requires -Version 7.0

# Stage: Deployment
# Dependencies: SSH, SCP/Rsync
# Description: Deploy AitherOS as a system service to a remote Linux host
# Tags: linux, deploy, service, systemd

<#
.SYNOPSIS
    Deploys AitherOS to a remote Linux server and installs it as a system service.

.DESCRIPTION
    This script automates the deployment of AitherOS to a Linux host.
    It performs the following steps:
    1. Validates local dependencies (ssh, scp/rsync).
    2. Compresses the AitherOS directory (excluding heavy/temp files).
    3. Transfers the package to the remote host.
    4. Executes the Linux installer script remotely.
    5. Verifies the service status.

.PARAMETER TargetHost
    The IP address or hostname of the target Linux server.

.PARAMETER UserName
    The SSH username (default: aither or current user).

.PARAMETER IdentityFile
    Path to the private SSH key file (optional).

.PARAMETER Password
    SSH Password (optional, if not using key). Note: Key-based auth is recommended.

.PARAMETER AitherOSPath
    Path to the local AitherOS source directory (default: current workspace).

.EXAMPLE
    .\0840_Deploy-AitherLinuxService.ps1 -TargetHost 192.168.1.50 -UserName ubuntu -IdentityFile ~/.ssh/id_rsa

.EXAMPLE
    .\0840_Deploy-AitherLinuxService.ps1 -TargetHost aither-prod -UserName admin
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TargetHost,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$UserName,

    [Parameter(Mandatory = $false)]
    [string]$IdentityFile,

    [Parameter(Mandatory = $false)]
    [string]$AitherOSPath = ".\AitherOS",

    [Parameter(Mandatory = $false)]
    [switch]$Reinstall,

    [Parameter()]
    [switch]$ShowOutput
)

. "$PSScriptRoot/_init.ps1"
Write-ScriptLog "Starting AitherOS Linux Service Deployment"
Write-ScriptLog "Target: $UserName@$TargetHost"

# 1. Validation
if (-not (Test-Path $AitherOSPath)) {
    throw "AitherOS source path not found: $AitherOSPath"
}

$sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $sshCmd) {
    throw "SSH client not found. Please install OpenSSH."
}

# Build SSH options
$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null")
if ($IdentityFile) {
    if (-not (Test-Path $IdentityFile)) {
        throw "Identity file not found: $IdentityFile"
    }
    $sshOpts += ("-i", $IdentityFile)
}

# Function to run remote command
function Invoke-RemoteCommand {
    param($Command, $Sudo = $false)
    
    $fullCmd = if ($Sudo) { "sudo $Command" } else { $Command }
    Write-ScriptLog "Running remote: $fullCmd"
    
    if ($IdentityFile) {
        & ssh @sshOpts "$UserName@$TargetHost" $fullCmd
    } else {
        & ssh @sshOpts "$UserName@$TargetHost" $fullCmd
    }
    
    return $LASTEXITCODE
}

# 2. Check Connection
Write-ScriptLog "Checking connection to $TargetHost..."
$res = Invoke-RemoteCommand "echo Connection Successful"
if ($res -ne 0) {
    throw "Failed to connect to $TargetHost. Check credentials and network."
}

# 3. Prepare Payload
Write-ScriptLog "Preparing deployment payload..."
$tempDir = Join-Path $env:TEMP "aither-deploy-$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # Create archive
    # We assume tar is available on Windows (Git Bash or newer builds) or use 7z
    # For simplicity in PowerShell, we'll assume standard tools or just copy files if rsync is available
    
    $rsyncCmd = Get-Command rsync -ErrorAction SilentlyContinue
    
    if ($rsyncCmd) {
        Write-ScriptLog "Using rsync for transfer..."
        # Rsync is much better for incremental updates
        $source = (Resolve-Path $AitherOSPath).Path
        if (-not $source.EndsWith([IO.Path]::DirectorySeparatorChar)) { $source += "/" }
        
        # Convert path to cygwin style if needed (simplified check)
        if ($source -match "^([a-zA-Z]):") {
            $drive = $matches[1].ToLower()
            $path = $source.Substring(3).Replace("\", "/")
            $source = "/cygdrive/$drive/$path"
        }

        $rsh = "ssh -o StrictHostKeyChecking=no"
        if ($IdentityFile) {
            $keyPath = (Resolve-Path $IdentityFile).Path.Replace("\", "/")
            if ($keyPath -match "^([a-zA-Z]):") {
                $drive = $matches[1].ToLower()
                $rest = $keyPath.Substring(3)
                $keyPath = "/cygdrive/$drive/$rest"
            }
            $rsh += " -i '$keyPath'"
        }

        $dest = "$UserName@$TargetHost`:~/aither-deploy/"
        
        # Ensure dest dir exists
        Invoke-RemoteCommand "mkdir -p ~/aither-deploy"
        
        # Exclude heavy folders
        $excludes = @(
            "--exclude", ".git",
            "--exclude", ".venv",
            "--exclude", "venv",
            "--exclude", "__pycache__",
            "--exclude", "node_modules",
            "--exclude", "*.pyc"
        )
        
        Write-Host "Syncing files..."
        & rsync -avz -e "$rsh" @excludes "$source" "$dest"
        
        if ($LASTEXITCODE -ne 0) {
            throw "Rsync failed"
        }
        
    } else {
        Write-ScriptLog "Rsync not found, falling back to SCP (slower)..."
        
        # Create a clean temp copy to avoid copying junk
        Write-Host "Staging files..."
        Copy-Item -Path $AitherOSPath -Destination "$tempDir/AitherOS" -Recurse -Container
        
        # Remove exclusions manually
        Get-ChildItem "$tempDir/AitherOS" -Include ".git",".venv","venv","__pycache__","node_modules" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
        
        # Zip it
        $zipFile = "$tempDir/aither-deploy.zip"
        Compress-Archive -Path "$tempDir/AitherOS/*" -DestinationPath $zipFile
        
        # Upload
        Write-Host "Uploading payload..."
        if ($IdentityFile) {
            & scp @sshOpts $zipFile "$UserName@$TargetHost`:~/aither-deploy.zip"
        } else {
            & scp @sshOpts $zipFile "$UserName@$TargetHost`:~/aither-deploy.zip"
        }
        
        if ($LASTEXITCODE -ne 0) { throw "SCP failed" }
        
        # Unzip remote
        Invoke-RemoteCommand "mkdir -p ~/aither-deploy && unzip -o ~/aither-deploy.zip -d ~/aither-deploy && rm ~/aither-deploy.zip"
    }
    
    # 4. Run Installer
    Write-ScriptLog "Running remote installer..."
    
    # The install.sh is now at ~/aither-deploy/deployment/linux/install.sh
    # We need to make it executable
    Invoke-RemoteCommand "chmod +x ~/aither-deploy/deployment/linux/install.sh"
    
    # Run it
    Invoke-RemoteCommand "bash ~/aither-deploy/deployment/linux/install.sh" $true
    
    if ($LASTEXITCODE -eq 0) {
        Write-ScriptLog "✅ Installation Successful!" -Level Success
        Write-ScriptLog "Service should be running. Checking status..."
        Invoke-RemoteCommand "systemctl status aither-genesis --no-pager" $true
    } else {
        Write-ScriptLog "❌ Installation script failed." -Level Error
        exit 1
    }

}
finally {
    # Cleanup
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force
    }
}

