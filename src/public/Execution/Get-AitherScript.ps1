#Requires -Version 7.0

<#
.SYNOPSIS
    Get automation script information and metadata

.DESCRIPTION
    Discovers and retrieves information about automation scripts in the automation-scripts directory.
    Can list all scripts, search by number or name, get script metadata, and show parameter information.

    This cmdlet is essential for discovering available automation scripts and understanding their
    parameters before execution. It parses script files to extract metadata including parameters,
    descriptions, and help information.

.PARAMETER Script
    Script identifier - can be a number (e.g., '0501') or script name pattern.
    This parameter is required when using Get, Parameters, Help, Path, or Metadata parameter sets.

    Examples:
    - "0501" - Finds script starting with 0501
    - "system" - Finds scripts with "system" in the name
    - "0501_System-Config" - Exact script name match

.PARAMETER List
    List all available automation scripts. This is the default behavior if no parameters are provided.
    Returns a list of all scripts with their numbers, names, descriptions, and paths.

.PARAMETER Search
    Search scripts by number, name, or description. Useful for finding scripts when you only
    remember part of the name or description. The search is case-insensitive.

.PARAMETER ShowParameters
    Show parameters for the specified script. Displays all parameters with their types,
    mandatory status, and help text. Use this to understand what parameters a script accepts
    before running it.

.PARAMETER ShowHelp
    Show full help for the specified script. Displays comprehensive help information including
    synopsis, description, and all parameters with their descriptions.

.PARAMETER Path
    Return only the file path to the script. Useful when you need the full path for other
    operations or when piping to other cmdlets.

.PARAMETER Metadata
    Return script metadata as a PowerShell object. Includes number, name, description, path,
    and all parameters with their details. Useful for programmatic access to script information.

.INPUTS
    System.String
    You can pipe script identifiers (numbers or names) to Get-AitherScript.

.OUTPUTS
    PSCustomObject
    Returns script information objects with properties: Number, Name, Description, Path, FileName, Parameters

    When -Path is used, returns System.String (the file path)

    When -Metadata is used, returns PSCustomObject with detailed metadata

.EXAMPLE
    Get-AitherScript -List

    Lists all available automation scripts with their basic information.

.EXAMPLE
    Get-AitherScript -Script 0501

    Gets information about script 0501, including its path and description.

.EXAMPLE
    Get-AitherScript -Script 0501 -ShowParameters

    Shows all parameters that script 0501 accepts, including which are mandatory.

.EXAMPLE
    Get-AitherScript -Script 0501 -ShowHelp

    Displays full help information for script 0501.

.EXAMPLE
    Get-AitherScript -Search 'system'

    Searches for all scripts containing "system" in their name or description.

.EXAMPLE
    Get-AitherScript -Script 0501 -Metadata

    Returns detailed metadata object for script 0501, useful for programmatic access.

.EXAMPLE
    '0501', '0502' | Get-AitherScript

    Gets information for multiple scripts by piping script identifiers.

.EXAMPLE
    Get-AitherScript -Script 0501 -Path

    Returns only the file path to script 0501.

.NOTES
    Scripts are located in library/automation-scripts/ directory.
    Scripts follow the naming pattern: NNNN_Description.ps1 where NNNN is a 4-digit number.

    This cmdlet uses PowerShell AST (Abstract Syntax Tree) parsing to extract script metadata,
    so it can provide accurate parameter information even without executing the script.

.LINK
    Invoke-AitherScript
    Get-AitherScriptMetadata
#>
function Get-AitherScript {
    [OutputType([PSCustomObject], [System.String])]
    [CmdletBinding(DefaultParameterSetName = 'List')]
    param(
        [Parameter(ParameterSetName = 'Get', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Script identifier (number or name).")]
        [Parameter(ParameterSetName = 'Parameters', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Script identifier (number or name).")]
        [Parameter(ParameterSetName = 'Help', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Script identifier (number or name).")]
        [Parameter(ParameterSetName = 'Path', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Script identifier (number or name).")]
        [Parameter(ParameterSetName = 'Metadata', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Script identifier (number or name).")]
        [ValidateNotNullOrEmpty()]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
                if (Get-Command Get-AitherScript -ErrorAction SilentlyContinue) {
                    Get-AitherScript -List | Where-Object { $_.Name -like "$wordToComplete*" -or $_.Number -like "$wordToComplete*" } | ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new($_.Number, "$($_.Number) - $($_.Name)", 'ParameterValue', $_.Description)
                    }
                }
            })]
        [string]$Script,

        [Parameter(ParameterSetName = 'List', HelpMessage = "List all available automation scripts.")]
        [switch]$List,

        [Parameter(ParameterSetName = 'Search', HelpMessage = "Search scripts by number, name, or description.")]
        [string]$Search,

        [Parameter(ParameterSetName = 'Parameters', Mandatory = $true, HelpMessage = "Show parameters for the specified script.")]
        [switch]$ShowParameters,

        [Parameter(ParameterSetName = 'Help', Mandatory = $true, HelpMessage = "Show full help for the specified script.")]
        [switch]$ShowHelp,

        [Parameter(ParameterSetName = 'Path', Mandatory = $true, HelpMessage = "Return only the file path to the script.")]
        [switch]$Path,

        [Parameter(ParameterSetName = 'Metadata', Mandatory = $true, HelpMessage = "Return script metadata as a PowerShell object.")]
        [switch]$Metadata
    )

    begin {
        # Get scripts directory using robust discovery
        try {
            $scriptsPath = Get-AitherScriptsPath
        }
        catch {
            Write-AitherLog -Level Warning -Message "Could not resolve scripts path: $($_.Exception.Message)" -Source 'Get-AitherScript'
            $scriptsPath = $null
        }

        # Use shared helper function

        function Get-ScriptMetadata {
            param([System.IO.FileInfo]$ScriptFile)

            $metadata = @{
                Number      = $null
                Name        = $null
                FullName    = $ScriptFile.Name
                Path        = $ScriptFile.FullName
                Description = ''
                Parameters  = @{}
                Synopsis    = ''
                Help        = ''
                Stage       = 'Unknown'
            }

            # Extract number from filename
            if ($ScriptFile.Name -match '^(\d{4})_') {
                $metadata.Number = $matches[1]
                $metadata.Name = $ScriptFile.BaseName -replace '^\d{4}_', ''
            }
            else {
                $metadata.Name = $ScriptFile.BaseName
            }

            try {
                # Parse script AST for metadata
                $tokens = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $ScriptFile.FullName,
                    [ref]$tokens,
                    [ref]$null
                )

                # Extract comment-based help
                $helpComments = $tokens | Where-Object { $_.Kind -eq 'Comment' }
                $synopsis = $helpComments | Where-Object { $_.Text -match '\.SYNOPSIS' } | Select-Object -First 1
                if ($synopsis) {
                    $lines = $synopsis.Text -split "`n"
                    $inSynopsis = $false
                    $synopsisText = @()
                    foreach ($line in $lines) {
                        if ($line -match '\.SYNOPSIS') {
                            $inSynopsis = $true
                            continue
                        }
                        if ($inSynopsis -and $line -match '^\s*\.') {
                            break
                        }
                        if ($inSynopsis) {
                            $synopsisText += $line.Trim()
                        }
                    }
                    $metadata.Synopsis = ($synopsisText -join ' ').Trim()
                    $metadata.Description = $metadata.Synopsis
                }

                # Extract description
                $description = $helpComments | Where-Object { $_.Text -match '\.DESCRIPTION' } | Select-Object -First 1
                if ($description) {
                    $lines = $description.Text -split "`n"
                    $inDescription = $false
                    $descText = @()
                    foreach ($line in $lines) {
                        if ($line -match '\.DESCRIPTION') {
                            $inDescription = $true
                            continue
                        }
                        if ($inDescription -and $line -match '^\s*\.') {
                            break
                        }
                        if ($inDescription) {
                            $descText += $line.Trim()
                        }
                    }
                    if ($descText.Count -gt 0) {
                        $metadata.Description = ($descText -join ' ').Trim()
                    }
                }

                # Extract NOTES for Stage
                $notes = $helpComments | Where-Object { $_.Text -match '\.NOTES' } | Select-Object -First 1
                if ($notes) {
                    Write-Verbose "Found NOTES length: $($notes.Text.Length)"
                    if ($notes.Text -match 'Stage:\s*([a-zA-Z0-9-]+)') {
                        $metadata.Stage = $matches[1]
                    }
                    else {
                        Write-Verbose "Regex did not match for Stage in NOTES"
                    }
                }
                else {
                    Write-Verbose "No NOTES found"
                }

                # Extract parameters
                $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true) |
                ForEach-Object {
                    $paramName = $_.Name.VariablePath.UserPath
                    $paramInfo = @{
                        Name      = $paramName
                        Type      = if ($_.TypeName) { $_.TypeName.FullName } else { 'object' }
                        Mandatory = $false
                        Help      = ''
                    }

                    # Check if mandatory
                    $paramAttr = $_.Attributes.Where({ $_.TypeName.Name -eq 'Parameter' })
                    if ($paramAttr) {
                        $mandatoryAttr = $paramAttr.Attributes.Where({
                                $_.NamedArguments.ArgumentName -eq 'Mandatory'
                            })
                        if ($mandatoryAttr) {
                            $paramInfo.Mandatory = $mandatoryAttr.Argument.Value -eq $true
                        }
                    }

                    # Get parameter help
                    $paramHelp = $helpComments | Where-Object {
                        $_.Text -match "\.PARAMETER\s+$paramName"
                    } | Select-Object -First 1

                    if ($paramHelp) {
                        $lines = $paramHelp.Text -split "`n"
                        $inParam = $false
                        $helpText = @()
                        foreach ($line in $lines) {
                            if ($line -match "\.PARAMETER\s+$paramName") {
                                $inParam = $true
                                continue
                            }
                            if ($inParam -and $line -match '^\s*\.') {
                                break
                            }
                            if ($inParam) {
                                $helpText += $line.Trim()
                            }
                        }
                        $paramInfo.Help = ($helpText -join ' ').Trim()
                    }

                    $metadata.Parameters[$paramName] = $paramInfo
                }
            }
            catch {
                Write-AitherLog -Level Warning -Message "Failed to parse script metadata: $_" -Source 'Get-AitherScript' -Exception $_
                return $metadata
            }

            return $metadata
        }
    }

    process {
        try {
            if (-not (Test-Path $scriptsPath)) {
                Write-AitherLog -Level Warning -Message "Automation scripts directory not found: $scriptsPath" -Source 'Get-AitherScript'
                return @()
            }

            # List all scripts
            if ($List -or ($PSCmdlet.ParameterSetName -eq 'List' -and -not $Script)) {
                $scripts = Get-ChildItem -Path $scriptsPath -Filter '*.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{4}_' } |
                Sort-Object Name

                return $scripts | ForEach-Object {
                    $meta = Get-ScriptMetadata -ScriptFile $_
                    [PSCustomObject]@{
                        Number       = $meta.Number
                        ScriptNumber = $meta.Number
                        Name         = $meta.Name
                        Description  = $meta.Synopsis
                        Path         = $meta.Path
                        FileName     = $meta.FullName
                    }
                }
            }

            # Search scripts
            if ($Search) {
                $scripts = Get-ChildItem -Path $scriptsPath -Filter '*.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{4}_' }

                return $scripts | ForEach-Object {
                    $meta = Get-ScriptMetadata -ScriptFile $_
                    $searchText = "$($meta.Number) $($meta.Name) $($meta.Description)" -replace '-', ' '
                    if ($searchText -match $Search) {
                        [PSCustomObject]@{
                            Number       = $meta.Number
                            ScriptNumber = $meta.Number
                            Name         = $meta.Name
                            Description  = $meta.Synopsis
                            Path         = $meta.Path
                            FileName     = $meta.FullName
                        }
                    }
                } | Where-Object { $_ }
            }

            # Get specific script
            if ($Script) {
                $scriptFile = Find-AitherScriptFile -ScriptId $Script -ScriptsPath $scriptsPath

                if (-not $scriptFile) {
                    Invoke-AitherErrorHandler -ErrorRecord ([System.Management.Automation.ErrorRecord]::new(
                            [System.Exception]::new("Script not found: $Script"),
                            "ScriptNotFound",
                            [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                            $Script
                        )) -Operation "Getting script: $Script" -Parameters $PSBoundParameters -ErrorAction Continue
                    return $null
                }

                $meta = Get-ScriptMetadata -ScriptFile $scriptFile

                # Return path only
                if ($Path) {
                    return $meta.Path
                }

                # Show parameters
                if ($ShowParameters) {
                    Write-AitherLog -Level Information -Message "Script: $($meta.Number) - $($meta.Name)" -Source 'Get-AitherScript'
                    Write-AitherLog -Level Information -Message "Path: $($meta.Path)" -Source 'Get-AitherScript'

                    if ($meta.Parameters.Count -eq 0) {
                        Write-AitherLog -Level Warning -Message "No parameters found." -Source 'Get-AitherScript'
                        return
                    }

                    Write-AitherLog -Level Information -Message "Parameters:" -Source 'Get-AitherScript'
                    Write-AitherLog -Level Information -Message ("=" * 50) -Source 'Get-AitherScript'

                    foreach ($param in $meta.Parameters.Values | Sort-Object Name) {
                        $mandatory = if ($param.Mandatory) { "[MANDATORY] " } else { "" }
                        $paramLine = "-$($param.Name) $mandatory($($param.Type))"
                        Write-AitherLog -Level Information -Message $paramLine -Source 'Get-AitherScript'

                        if ($param.Help) {
                            Write-AitherLog -Level Information -Message "  $($param.Help)" -Source 'Get-AitherScript'
                        }
                    }

                    return
                }

                # Show full help
                if ($ShowHelp) {
                    Write-AitherLog -Level Information -Message "=== Script Help ===" -Source 'Get-AitherScript'
                    Write-AitherLog -Level Information -Message "Number: $($meta.Number)" -Source 'Get-AitherScript'
                    Write-AitherLog -Level Information -Message "Name: $($meta.Name)" -Source 'Get-AitherScript'
                    Write-AitherLog -Level Information -Message "Path: $($meta.Path)" -Source 'Get-AitherScript'

                    if ($meta.Synopsis) {
                        Write-AitherLog -Level Information -Message "SYNOPSIS" -Source 'Get-AitherScript'
                        Write-AitherLog -Level Information -Message $meta.Synopsis -Source 'Get-AitherScript'
                    }
                    if ($meta.Description -and $meta.Description -ne $meta.Synopsis) {
                        Write-AitherLog -Level Information -Message "DESCRIPTION" -Source 'Get-AitherScript'
                        Write-AitherLog -Level Information -Message $meta.Description -Source 'Get-AitherScript'
                    }
                    if ($meta.Parameters.Count -gt 0) {
                        Write-AitherLog -Level Information -Message "PARAMETERS" -Source 'Get-AitherScript'
                        foreach ($param in $meta.Parameters.Values | Sort-Object Name) {
                            $mandatory = if ($param.Mandatory) { "[MANDATORY] " } else { "" }
                            $paramLine = "  -$($param.Name) $mandatory($($param.Type))"
                            Write-AitherLog -Level Information -Message $paramLine -Source 'Get-AitherScript'

                            if ($param.Help) {
                                Write-AitherLog -Level Information -Message "    $($param.Help)" -Source 'Get-AitherScript'
                            }
                        }
                        return
                    }
                }

                # Return metadata object
                if ($Metadata) {
                    return [PSCustomObject]$meta
                }

                # Default: return script info object
                return [PSCustomObject]@{
                    Number      = $meta.Number
                    Name        = $meta.Name
                    Description = $meta.Synopsis
                    Stage       = $meta.Stage
                    Path        = $meta.Path
                    FileName    = $meta.FullName
                    Parameters  = $meta.Parameters.Keys
                }
            }
        }
        catch {
            Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Getting script information" -Parameters $PSBoundParameters -ThrowOnError
        }
    }
}

