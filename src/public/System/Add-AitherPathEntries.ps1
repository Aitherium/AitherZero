#Requires -Version 7.0

<#
.SYNOPSIS
    Add entries to PATH environment variable

.DESCRIPTION
    Adds one or more directories to the PATH variable at the specified scope.
    Validates that paths exist before adding them and skips duplicates.

.PARAMETER Paths
    Array of directory paths to add to PATH

.PARAMETER Scope
    PATH scope: Process, User, or Machine

.PARAMETER DryRun
    Preview changes without applying

.EXAMPLE
    Add-AitherPathEntries -Paths @('C:\Tools', 'C:\MyApp') -Scope User

    Add multiple directories to user PATH

.EXAMPLE
    Add-AitherPathEntries -Paths '/usr/local/bin' -Scope Process -DryRun

    Preview adding a path to process PATH

.OUTPUTS
    Boolean - True if any paths were added, False otherwise

.NOTES
    Machine scope requires administrator privileges.
    Paths are validated to exist before being added.
    Duplicate paths are automatically skipped.

.LINK
    Set-AitherEnvironmentConfig
    Set-AitherEnvVariable
#>
function Add-AitherPathEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Paths,

        [ValidateSet('Process', 'User', 'Machine')]
        [string]$Scope = 'User',

        [switch]$DryRun,

        [Parameter(HelpMessage = "Show command output in console.")]
        [switch]$ShowOutput
    )

    begin {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Ensure Console is NOT in targets if ShowOutput is not specified
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }
    }

    process {
        try {
            # During module validation, skip execution
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                return $false
            }

            # Check admin for Machine scope
            if ($Scope -eq 'Machine') {
                    $isAdmin = if (Get-Command Test-AitherAdmin -ErrorAction SilentlyContinue) {
                        Test-AitherAdmin
                    }
                    else {
                        $false
                    }
                    if (-not $isAdmin) {
                        Write-AitherLog -Message "Administrator privileges required for Machine scope" -Level Warning -Source 'Add-AitherPathEntries'
                        return $false
                    }
                }

                # Get current PATH
                $currentPath = [Environment]::GetEnvironmentVariable('PATH', $Scope)
                $pathEntries = $currentPath -split [IO.Path]::PathSeparator | Where-Object { $_ }

                $added = 0
                foreach ($path in $Paths) {
                    # Validate path exists
                    if (-not (Test-Path $path)) {
                        Write-AitherLog -Message "Path does not exist: $path (skipping)" -Level Warning -Source 'Add-AitherPathEntries'
                        continue
                    }

                    # Check if already in PATH
                    if ($pathEntries -contains $path) {
                        Write-AitherLog -Message "Path already in $Scope PATH: $path" -Level Debug -Source 'Add-AitherPathEntries'
                        continue
                    }
                    if ($DryRun) {
                        Write-AitherLog -Message "[DRY RUN] Would add to $Scope PATH: $path" -Level Information -Source 'Add-AitherPathEntries'
                    }
                    else {
                        $pathEntries += $path
                        Write-AitherLog -Message "Added to $Scope PATH: $path" -Level Information -Source 'Add-AitherPathEntries'
                    }
                    $added++
                }
                if ($added -gt 0 -and -not $DryRun) {
                    $newPath = $pathEntries -join [IO.Path]::PathSeparator
                    [Environment]::SetEnvironmentVariable('PATH', $newPath, $Scope)
                }

                return ($added -gt 0)
            }
        catch {
            Write-AitherLog -Message "Error adding path entries: $($_.Exception.Message)" -Level Error -Source 'Add-AitherPathEntries' -Exception $_
            throw
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }
}

