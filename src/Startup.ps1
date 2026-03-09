# Set module root
$script:ModuleRoot = $PSScriptRoot
# Adjust ProjectRoot calculation based on location
if ((Split-Path $PSScriptRoot -Leaf) -eq 'bin') {
    # If running from bin/, we need to go up two levels to get to repo root
    $script:ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
} else {
    # If running from module root (AitherZero/), we need to go up one level
    $script:ProjectRoot = Split-Path $PSScriptRoot -Parent
}

# Set environment variables
$env:AITHERZERO_ROOT = $script:ProjectRoot
$env:AITHERZERO_MODULE_ROOT = $script:ModuleRoot
$env:AITHERZERO_INITIALIZED = "1"

# Module loading tracking
$script:LoadedModules = @()
$script:FailedModules = @()
$script:LoadedFunctions = @()
$script:FailedFunctions = @()

# Helper function for logging during module initialization
function Write-InitLog {
    param(
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information'
    )

    # Try Write-AitherLog first, fallback to Write-Host/Write-Warning/Write-Error
    if (Get-Command Write-AitherLog -ErrorAction SilentlyContinue) {
        Write-AitherLog -Message $Message -Level $Level -Source 'ModuleLoader'
    }
    elseif ($Level -eq 'Error') {
        Write-Error $Message -ErrorAction Continue
    }
    elseif ($Level -eq 'Warning') {
        Write-Warning $Message
    }
    else {
        # Information level - only show if verbose mode
        if ($VerbosePreference -eq 'Continue' -or $env:AITHERZERO_VERBOSE -eq '1') {
            Write-Information $Message -InformationAction Continue
        }
    }
}

# Performance optimization: Skip transcript in test mode or when disabled
$isTestOrCIMode = ($env:AITHERZERO_DISABLE_TRANSCRIPT -eq '1') -or
                   ($env:AITHERZERO_TEST_MODE) -or
                   ($env:CI)
$script:TranscriptEnabled = -not $isTestOrCIMode

# Start PowerShell transcription for complete activity logging (if enabled)
if ($script:TranscriptEnabled) {
    $transcriptPath = Join-Path $script:ProjectRoot 'AitherZero/library/logs' "transcript-$(Get-Date -Format 'yyyy-MM-dd').log"
    $logsDir = Split-Path $transcriptPath -Parent
    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    try {
        # Try to start transcript, stop any existing one first
        try {
            Stop-Transcript -ErrorAction Stop | Out-Null
        }
        catch {
            # No active transcript to stop - this is expected
        }
        Start-Transcript -Path $transcriptPath -Append -IncludeInvocationHeader | Out-Null
    } catch {
        # Transcript functionality not available or failed - continue without it
        Write-Verbose "Transcript logging unavailable: $($_.Exception.Message)"
    }
}

# region Package Manager Configuration
# Package Manager Configurations
$script:WindowsPackageManagers = @{
    'winget' = @{
        Command = 'winget'
        Priority = 1
        InstallArgs = @('install', '--id', '{0}', '--exact', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--silent')
        CheckArgs = @('list', '--id', '{0}', '--exact')
    }
    'chocolatey' = @{
        Command = 'choco'
        Priority = 2
        InstallArgs = @('install', '{0}', '-y')
        CheckArgs = @('list', '{0}', '--exact', '--local-only')
    }
}

$script:LinuxPackageManagers = @{
    'apt' = @{
        Command = 'apt-get'
        Priority = 1
        InstallArgs = @('install', '-y', '{0}')
        CheckArgs = @('list', '--installed', '{0}')
        UpdateArgs = @('update')
    }
    'yum' = @{
        Command = 'yum'
        Priority = 2
        InstallArgs = @('install', '-y', '{0}')
        CheckArgs = @('list', 'installed', '{0}')
    }
    'dnf' = @{
        Command = 'dnf'
        Priority = 2
        InstallArgs = @('install', '-y', '{0}')
        CheckArgs = @('list', '--installed', '{0}')
    }
    'pacman' = @{
        Command = 'pacman'
        Priority = 3
        InstallArgs = @('-S', '--noconfirm', '{0}')
        CheckArgs = @('-Qi', '{0}')
    }
}

$script:MacPackageManagers = @{
    'brew' = @{
        Command = 'brew'
        Priority = 1
        InstallArgs = @('install', '{0}')
        CheckArgs = @('list', '{0}')
        CaskArgs = @('install', '--cask', '{0}')
    }
}

# Software Package Mappings
$script:SoftwarePackages = @{
    'git' = @{
        winget = 'Git.Git'
        chocolatey = 'git'
        apt = 'git'
        yum = 'git'
        dnf = 'git'
        pacman = 'git'
        brew = 'git'
    }
    'nodejs' = @{
        winget = 'OpenJS.NodeJS'
        chocolatey = 'nodejs'
        apt = 'nodejs'
        yum = 'nodejs'
        dnf = 'nodejs'
        pacman = 'nodejs'
        brew = 'node'
    }
    'vscode' = @{
        winget = 'Microsoft.VisualStudioCode'
        chocolatey = 'vscode'
        apt = 'code'
        yum = 'code'
        dnf = 'code'
        pacman = 'code'
        brew = 'visual-studio-code'
        brew_cask = $true
    }
    'python' = @{
        winget = 'Python.Python.3.12'
        chocolatey = 'python'
        apt = 'python3'
        yum = 'python3'
        dnf = 'python3'
        pacman = 'python'
        brew = 'python3'
    }
    '7zip' = @{
        winget = '7zip.7zip'
        chocolatey = '7zip'
        apt = 'p7zip-full'
        yum = 'p7zip'
        dnf = 'p7zip'
        pacman = 'p7zip'
        brew = 'p7zip'
    }
    'azure-cli' = @{
        winget = 'Microsoft.AzureCLI'
        chocolatey = 'azure-cli'
        apt = 'azure-cli'
        yum = 'azure-cli'
        dnf = 'azure-cli'
        pacman = 'azure-cli'
        brew = 'azure-cli'
    }
    'docker' = @{
        winget = 'Docker.DockerDesktop'
        chocolatey = 'docker-desktop'
        apt = 'docker.io'
        yum = 'docker'
        dnf = 'docker'
        pacman = 'docker'
        brew = 'docker'
        brew_cask = $true
    }
    'golang' = @{
        winget = 'GoLang.Go'
        chocolatey = 'golang'
        apt = 'golang-go'
        yum = 'golang'
        dnf = 'golang'
        pacman = 'go'
        brew = 'go'
    }
    'powershell' = @{
        winget = 'Microsoft.PowerShell'
        chocolatey = 'powershell-core'
        apt = 'powershell'
        yum = 'powershell'
        dnf = 'powershell'
        pacman = 'powershell'
        brew = 'powershell'
        brew_cask = $true
    }
}
# endregion Package Manager Configuration

# region ProjectContext + Auto-Load Plugins

# Config cache for ProjectContext resolution
$script:AitherConfig = $null

# Plugin state: Use a .NET class to hold shared state that survives module scope splits.
# PowerShell's compiled PSM1 can create multiple session states, making $script: unreliable
# for variables set AFTER Export-ModuleMember. A static class is a reliable singleton.
if (-not ([System.Management.Automation.PSTypeName]'AitherPluginState').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections;

public static class AitherPluginState {
    private static Hashtable _plugins = new Hashtable(StringComparer.OrdinalIgnoreCase);
    private static System.Collections.Generic.List<string> _scriptPaths = new System.Collections.Generic.List<string>();
    private static System.Collections.Generic.List<string> _playbookPaths = new System.Collections.Generic.List<string>();
    private static Hashtable _config = null;

    public static Hashtable Plugins { get { return _plugins; } }
    public static System.Collections.Generic.List<string> ScriptPaths { get { return _scriptPaths; } }
    public static System.Collections.Generic.List<string> PlaybookPaths { get { return _playbookPaths; } }
    public static Hashtable Config { get { return _config; } set { _config = value; } }

    public static void Reset() {
        _plugins = new Hashtable(StringComparer.OrdinalIgnoreCase);
        _scriptPaths = new System.Collections.Generic.List<string>();
        _playbookPaths = new System.Collections.Generic.List<string>();
        _config = null;
    }
}
'@
} else {
    [AitherPluginState]::Reset()
}

# Backward-compat aliases (some code uses $script: directly)
$script:RegisteredPlugins = [AitherPluginState]::Plugins
$script:PluginScriptPaths = [AitherPluginState]::ScriptPaths
$script:PluginPlaybookPaths = [AitherPluginState]::PlaybookPaths

$_pluginsDir = Join-Path $script:ModuleRoot 'plugins'
if (Test-Path $_pluginsDir) {
    $pluginDirs = Get-ChildItem -Path $_pluginsDir -Directory | Where-Object { $_.Name -notlike '_*' }
    foreach ($pluginDir in $pluginDirs) {
        $manifestPath = Join-Path $pluginDir.FullName 'plugin.psd1'
        if (Test-Path $manifestPath) {
            # Defer actual registration until Register-AitherPlugin is available
            # Store paths for post-init loading
            if (-not $script:_PendingPluginPaths) {
                $script:_PendingPluginPaths = [System.Collections.Generic.List[string]]::new()
            }
            $script:_PendingPluginPaths.Add($pluginDir.FullName)
        }
    }
}
Remove-Variable -Name '_pluginsDir' -ErrorAction SilentlyContinue

# endregion Auto-Load Plugins

