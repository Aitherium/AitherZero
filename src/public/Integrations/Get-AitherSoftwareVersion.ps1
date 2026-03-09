function Get-AitherSoftwareVersion {
    <#
    .SYNOPSIS
        Gets the installed version of a software package
    .PARAMETER SoftwareName
        The standard name of the software
    .PARAMETER Command
        Optional custom command to check version (defaults to common patterns)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SoftwareName,

        [string]$Command
    )

    # Common version check patterns
    $versionChecks = @{
        'git' = @('git', '--version')
        'nodejs' = @('node', '--version')
        'python' = @('python', '--version')
        'golang' = @('go', 'version')
        'docker' = @('docker', '--version')
        'powershell' = @('pwsh', '--version')
        'vscode' = @('code', '--version')
        'azure-cli' = @('az', '--version')
    }

    try {
        if ($Command) {
            $versionOutput = Invoke-Expression $Command 2>&1
        } else {
            $checkCmd = $versionChecks[$SoftwareName.ToLower()]
            if ($checkCmd) {
                $versionOutput = & $checkCmd[0] $checkCmd[1] 2>&1
            } else {
                return "Version check not available for $SoftwareName"
            }
        }

        if ($LASTEXITCODE -eq 0) {
            return $versionOutput.ToString().Trim()
        } else {
            return "Could not determine version"
        }
    } catch {
        return "Error checking version: $_"
    }
}

