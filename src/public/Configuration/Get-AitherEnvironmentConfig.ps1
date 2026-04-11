#Requires -Version 7.0

<#
.SYNOPSIS
    Get current environment configuration status

.DESCRIPTION
    Reads the current state of environment configuration including:
    - Windows features (long path support, developer mode)
    - Environment variables
    - PATH configuration
    - Shell integration (Unix)
    
    This function provides a comprehensive view of the system's environment
    configuration status based on the AitherZero configuration file.

.PARAMETER Category
    Specific category to retrieve: All, Windows, Unix, EnvironmentVariables, or Path

.PARAMETER ConfigFile
    Path to configuration file (defaults to config.psd1 in module root)

.EXAMPLE
    Get-AitherEnvironmentConfig
    
    Get all environment configuration status

.EXAMPLE
    Get-AitherEnvironmentConfig -Category Windows
    
    Get Windows-specific configuration status

.EXAMPLE
    Get-AitherEnvironmentConfig -Category Path
    
    Get PATH configuration status only

.OUTPUTS
    Hashtable - Environment configuration status object with ConfigPath and Status properties

.NOTES
    Requires administrator privileges to check some Windows features.
    Unix shell integration detection works on Linux and macOS.

.LINK
    Set-AitherEnvironmentConfig
    Get-AitherWindowsLongPath
    Get-AitherWindowsDeveloperMode
#>
function Get-AitherEnvironmentConfig {
[CmdletBinding()]
param(
    [ValidateSet('All', 'Windows', 'Unix', 'EnvironmentVariables', 'Path')]
    [string]$Category = 'All',
    
    [string]$ConfigFile
)

begin {
    # Get module root
    $moduleRoot = Get-AitherModuleRoot
    
    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $moduleRoot 'config.psd1'
    }
    elseif (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
        $ConfigFile = Join-Path $moduleRoot $ConfigFile
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return $null
        }
        
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Retrieving environment configuration (Category: $Category)" -Level Information -Source 'Get-AitherEnvironmentConfig'
        }
        
        # Load configuration
        if (-not (Test-Path $ConfigFile)) {
            throw "Configuration file not found: $ConfigFile"
        }
        
        if (-not (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
            Write-AitherLog -Level Warning -Message "Get-AitherConfigs is not available. Cannot retrieve environment configuration." -Source 'Get-AitherEnvironmentConfig'
            return $null
        }
        
        $config = Get-AitherConfigs -ConfigFile $ConfigFile
        
        if (-not $config.EnvironmentConfiguration) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "No EnvironmentConfiguration section found in config" -Level Warning -Source 'Get-AitherEnvironmentConfig'
            } else {
                Write-Warning "No EnvironmentConfiguration section found in config"
            }
            return $null
        }
        
        $envConfig = $config.EnvironmentConfiguration
        $result = @{
            ConfigPath = $ConfigFile
            Status = @{}
        }
        
        # Get Windows configuration status
        if ($Category -in @('All', 'Windows') -and ($IsWindows -or $PSVersionTable.Platform -eq 'Win32NT')) {
            $longPathStatus = if (Get-Command Get-AitherWindowsLongPath -ErrorAction SilentlyContinue) {
                Get-AitherWindowsLongPath
            }
            else { $null }
            
            $devModeStatus = if (Get-Command Get-AitherWindowsDeveloperMode -ErrorAction SilentlyContinue) {
                Get-AitherWindowsDeveloperMode
            }
            else { $null }
            
            $isAdmin = if (Get-Command Test-AitherAdmin -ErrorAction SilentlyContinue) {
                Test-AitherAdmin
            }
            else { $false }
            
            $result.Status.Windows = @{
                LongPathSupport = $longPathStatus
                DeveloperMode = $devModeStatus
                IsAdministrator = $isAdmin
            }
        }
        
        # Get environment variables
        if ($Category -in @('All', 'EnvironmentVariables')) {
            $result.Status.EnvironmentVariables = @{
                System = @{}
                User = @{}
                Process = @{}
            }
            
            # Check configured variables
            if ($envConfig.EnvironmentVariables.User) {
                foreach ($key in $envConfig.EnvironmentVariables.User.Keys) {
                    $result.Status.EnvironmentVariables.User[$key] = [Environment]::GetEnvironmentVariable($key, 'User')
                }
            }
            if ($envConfig.EnvironmentVariables.Process) {
                foreach ($key in $envConfig.EnvironmentVariables.Process.Keys) {
                    $result.Status.EnvironmentVariables.Process[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
                }
            }
        }
        
        # Get PATH configuration
        if ($Category -in @('All', 'Path')) {
            $result.Status.Path = @{
                User = [Environment]::GetEnvironmentVariable('PATH', 'User') -split [IO.Path]::PathSeparator
                System = [Environment]::GetEnvironmentVariable('PATH', 'Machine') -split [IO.Path]::PathSeparator
                Process = $env:PATH -split [IO.Path]::PathSeparator
            }
        }
        
        # Get Unix configuration
        if ($Category -in @('All', 'Unix') -and ($IsLinux -or $IsMacOS)) {
            $result.Status.Unix = @{
                Shell = $env:SHELL
                ShellConfigFiles = @()
            }
            
            # Detect shell config files
            $shellConfigs = @('.bashrc', '.zshrc', '.config/fish/config.fish')
            foreach ($shellConfigFile in $shellConfigs) {
                $path = Join-Path $env:HOME $shellConfigFile
                if (Test-Path $path) {
                    $result.Status.Unix.ShellConfigFiles += $path
                }
            }
        }
        
        return $result
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Error retrieving environment configuration: $($_.Exception.Message)" -Level Error -Source 'Get-AitherEnvironmentConfig' -Exception $_
        } else {
            Write-Error "Error retrieving environment configuration: $($_.Exception.Message)"
        }
        throw
    }
}


}

