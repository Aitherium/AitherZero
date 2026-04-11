#Requires -Version 7.0

<#
.SYNOPSIS
    Save a playbook definition to disk

.DESCRIPTION
    Creates or updates a playbook file in the playbooks directory.
    Can create from scratch or save an existing playbook object.

.PARAMETER Name
    Name of the playbook (will be used as filename)

.PARAMETER Description
    Description of the playbook

.PARAMETER Sequence
    Array of script numbers or script definitions to execute

.PARAMETER Variables
    Default variables for the playbook

.PARAMETER Options
    Playbook options (Parallel, MaxConcurrency, etc.)

.PARAMETER Playbook
    Playbook object to save (overrides other parameters)

.PARAMETER Force
    Overwrite existing playbook

.EXAMPLE
    Save-AitherPlaybook -Name 'my-playbook' -Description 'Test playbook' -Sequence @('0407', '0413')

.EXAMPLE
    $playbook = @{
        Name = 'custom-playbook'
        Description = 'Custom validation'
        Sequence = @('0407', '0413', '0402')
        Variables = @{ CI = $true }
        Options = @{ Parallel = $true; MaxConcurrency = 4 }
    }
    Save-AitherPlaybook -Playbook $playbook

.NOTES
    Playbooks are saved as .psd1 files in library/playbooks/
#>
function Save-AitherPlaybook {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'FromObject')]
    param(
        [Parameter(Mandatory = $false, ParameterSetName = 'New')]
        [string]$Name,

        [Parameter(ParameterSetName = 'New')]
        [string]$Description = '',

        [Parameter(ParameterSetName = 'New')]
        [object[]]$Sequence = @(),

        [Parameter(ParameterSetName = 'New')]
        [hashtable]$Variables = @{},

        [Parameter(ParameterSetName = 'New')]
        [hashtable]$Options = @{},

        [Parameter(Mandatory = $false, ParameterSetName = 'FromObject', ValueFromPipeline)]
        [hashtable]$Playbook,

        [Parameter()]
        [switch]$Force,

        [switch]$ShowOutput
    )

    begin {
        # Save original log targets
        $originalLogTargets = $script:AitherLogTargets

        # Set log targets based on ShowOutput parameter
        if ($ShowOutput) {
            # Ensure Console is in the log targets
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Remove Console from log targets if present (default behavior)
            if ($script:AitherLogTargets -contains 'Console') {
                $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
            }
        }

        $moduleRoot = Get-AitherModuleRoot
        $playbooksPath = Join-Path $moduleRoot 'library' 'playbooks'

        if (-not (Test-Path $playbooksPath)) {
            New-Item -ItemType Directory -Path $playbooksPath -Force | Out-Null
        }
    }

    process {
        try {
            try {
                # Build playbook object
                if ($PSCmdlet.ParameterSetName -eq 'New') {
                    $Playbook = @{
                        Name        = $Name
                        Description = $Description
                        Version     = '1.0.0'
                        Sequence    = $Sequence
                        Variables   = $Variables
                        Options     = $Options
                    }
                }

                # Ensure required fields
                if (-not $Playbook -or -not $Playbook.Name) {
                    # During module validation, Playbook may be empty - skip validation
                    if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
                        return
                    }
                    throw "Playbook must have a Name"
                }
                if (-not $Playbook.Version) {
                    $Playbook.Version = '1.0.0'
                }

                # Build file path
                $fileName = "$($Playbook.Name).psd1"
                $filePath = Join-Path $playbooksPath $fileName

                # Check if exists
                if ((Test-Path $filePath) -and -not $Force) {
                    throw "Playbook already exists: $fileName. Use -Force to overwrite."
                }

                # Convert to PowerShell data file format
                $content = "@{`n"
                $content += "    Name = '$($Playbook.Name)'`n"
                $content += "    Description = '$($Playbook.Description)'`n"
                $content += "    Version = '$($Playbook.Version)'`n"
                $content += "`n"

                if ($Playbook.Sequence) {
                    $content += "    Sequence = @("
                    if ($Playbook.Sequence[0] -is [string]) {
                        $content += "'$($Playbook.Sequence -join "', '")'"
                    }
                    else {
                        $seqStrings = $Playbook.Sequence | ForEach-Object {
                            if ($_ -is [hashtable]) {
                                $script = $_.Script -replace '\.ps1$', ''
                                "@{ Script = '$script'; Description = '$($_.Description)' }"
                            }
                            else {
                                "'$_'"
                            }
                        }
                        $content += $seqStrings -join ",`n        "
                    }
                    $content += ")`n"
                    $content += "`n"
                }
                if ($Playbook.Variables -and $Playbook.Variables.Count -gt 0) {
                    $content += "    Variables = @{`n"
                    foreach ($key in $Playbook.Variables.Keys) {
                        $value = $Playbook.Variables[$key]
                        if ($value -is [string]) {
                            $content += "        $key = '$value'`n"
                        }
                        elseif ($value -is [bool]) {
                            $content += "        $key = `$$value`n"
                        }
                        else {
                            $content += "        $key = $value`n"
                        }
                    }
                    $content += "    }`n"
                    $content += "`n"
                }
                if ($Playbook.Options -and $Playbook.Options.Count -gt 0) {
                    $content += "    Options = @{`n"
                    foreach ($key in $Playbook.Options.Keys) {
                        $value = $Playbook.Options[$key]
                        if ($value -is [string]) {
                            $content += "        $key = '$value'`n"
                        }
                        elseif ($value -is [bool]) {
                            $content += "        $key = `$$value`n"
                        }
                        else {
                            $content += "        $key = $value`n"
                        }
                    }
                    $content += "    }`n"
                }

                $content += "}`n"

                # Save file
                if ($PSCmdlet.ShouldProcess($filePath, "Save playbook")) {
                    Set-Content -Path $filePath -Value $content -Encoding UTF8
                    Write-AitherLog -Level Information -Message "Playbook saved: $filePath" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                    return $filePath
                }
            }
            catch {
                Write-AitherLog -Level Error -Message "Failed to save playbook: $_" -Source 'Save-AitherPlaybook' -Exception $_
                throw
            }
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }

}

