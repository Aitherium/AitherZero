function Get-AvailablePackageManagers {
    <#
    .SYNOPSIS
        Detects available package managers on the current system
    .DESCRIPTION
        Scans for available package managers based on the current platform
        and returns them in priority order
    #>
    [CmdletBinding()]
    param()

    $available = @()

    if ($IsWindows) {
        foreach ($pm in ($script:WindowsPackageManagers.GetEnumerator() | Sort-Object { $_.Value.Priority })) {
            if (Get-Command $pm.Value.Command -ErrorAction SilentlyContinue) {
                $available += @{
                    Name = $pm.Key
                    Config = $pm.Value
                    Platform = 'Windows'
                }
                Write-Verbose "Found package manager: $($pm.Key)"
            }
        }
    } elseif ($IsLinux) {
        foreach ($pm in ($script:LinuxPackageManagers.GetEnumerator() | Sort-Object { $_.Value.Priority })) {
            if (Get-Command $pm.Value.Command -ErrorAction SilentlyContinue) {
                $available += @{
                    Name = $pm.Key
                    Config = $pm.Value
                    Platform = 'Linux'
                }
                Write-Verbose "Found package manager: $($pm.Key)"
            }
        }
    } elseif ($IsMacOS) {
        foreach ($pm in ($script:MacPackageManagers.GetEnumerator() | Sort-Object { $_.Value.Priority })) {
            if (Get-Command $pm.Value.Command -ErrorAction SilentlyContinue) {
                $available += @{
                    Name = $pm.Key
                    Config = $pm.Value
                    Platform = 'macOS'
                }
                Write-Verbose "Found package manager: $($pm.Key)"
            }
        }
    }

    return $available
}

