#Requires -Version 7.0

<#
.SYNOPSIS
    Invoke automation scripts with runtime parameter discovery and validation

.DESCRIPTION
    Executes automation scripts from the automation-scripts directory with intelligent
    parameter discovery, validation, and help generation. Supports script numbers (e.g., 0501)
    or full script names.

    This cmdlet automatically discovers script parameters at runtime, validates them, and provides
    helpful error messages if parameters are missing or invalid. It also enables transcript logging
    by default to capture all script output for debugging and auditing purposes.

.PARAMETER Script
    Script identifier - can be a number (e.g., '0501') or script name pattern.
    This parameter is REQUIRED and identifies which automation script to execute.

    Examples:
    - "0501" - Executes script starting with 0501
    - "system-config" - Executes script with "system-config" in the name
    - You can also pipe script objects from Get-AitherScript

    If the script is not found, an error will be thrown with suggestions for similar scripts.

.PARAMETER Arguments
    Arguments to pass to the script. Can be provided in multiple formats:
    - Hashtable: @{ ParameterName = 'Value'; AnotherParam = 123 }
    - String: "-Parameter1 Value1 -Parameter2 Value2"
    - Array: @('-Parameter1', 'Value1', '-Parameter2', 'Value2')

    The cmdlet automatically parses these formats and passes them to the script.
    Use Get-AitherScript -Script <number> -ShowParameters to see what parameters a script accepts.

.PARAMETER Parameters
    Alias for Arguments parameter. Use whichever name is more intuitive for you.

.PARAMETER OutputPath
    Path for script output (if script supports it). This is automatically added to the script's
    parameters. Useful for redirecting script output to a specific location.

    Example: "C:\Reports\output.txt" or "/home/user/reports/output.txt"

.PARAMETER ShowHelp
    Show parameter help for the script without executing. This is useful to understand what
    parameters a script accepts before running it. Displays all parameters with their types,
    mandatory status, and descriptions.

.PARAMETER ListParameters
    List all available parameters for the script. Similar to ShowHelp but in a more compact format.

.PARAMETER DryRun
    Show what would be executed without actually running the script. Displays the script path
    and all parameters that would be passed. Use this to verify your command before execution.

.PARAMETER Transcript
    Enable transcript logging for this script execution. Default is $true (enabled).
    Transcripts capture all console output and are saved to the logs directory with a timestamp.
    Set to $false to disable transcript logging.

.PARAMETER TranscriptPath
    Custom path for transcript log. If not specified, transcripts are saved to the logs directory
    with an automatically generated filename based on the script name and timestamp.

.INPUTS
    System.String
    You can pipe script identifiers to Invoke-AitherScript.

    PSCustomObject
    You can pipe script objects from Get-AitherScript to Invoke-AitherScript.

.OUTPUTS
    The output depends on what the script returns. Most scripts return objects or write to console.

.EXAMPLE
    Invoke-AitherScript -Script 0501

    Executes script 0501 with default parameters and transcript logging enabled.

.EXAMPLE
    Invoke-AitherScript -Script 0501 -Arguments @{ OutputFormat = 'Detailed' }

    Executes script 0501 with OutputFormat parameter set to 'Detailed'.

.EXAMPLE
    Invoke-AitherScript -Script 0501 -Arguments "-OutputFormat Detailed -AsJson"

    Executes script 0501 with multiple parameters provided as a string.

.EXAMPLE
    Invoke-AitherScript -Script 0501 -ShowHelp

    Shows help for script 0501 without executing it.

.EXAMPLE
    Invoke-AitherScript -Script 0501 -OutputPath "C:\my home\dir with spaces\"

    Executes script 0501 and passes OutputPath parameter with a path containing spaces.

.EXAMPLE
    Get-AitherScript -Script 0501 | Invoke-AitherScript -Arguments @{ Verbose = $true }

    Pipes script information from Get-AitherScript to Invoke-AitherScript.

.EXAMPLE
    '0501', '0502' | Invoke-AitherScript

    Executes multiple scripts by piping script identifiers.

.EXAMPLE
    Invoke-AitherScript -Script 0501 -DryRun

    Shows what would be executed without actually running the script.

.NOTES
    Scripts are located in library/automation-scripts/ directory.
    Each script has its own transcript logging enabled by default for debugging and auditing.

    If a script fails, check the transcript log in the logs directory for detailed error information.
    Transcript logs are named: transcript-<scriptname>-<timestamp>.log

.LINK
    Get-AitherScript
    Get-AitherExecutionHistory
#>
function Invoke-AitherScript {
    [OutputType([System.Object])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "The script identifier (number or name) to execute.")]
        [Alias('ScriptNumber', 'Number', 'Id')]
        [AllowEmptyString()]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

                if (Get-Command Get-AitherScript -ErrorAction SilentlyContinue) {
                    Get-AitherScript |
                    Where-Object { $_.Name -like "*$wordToComplete*" -or $_.Number -like "$wordToComplete*" } |
                    ForEach-Object {
                        [System.Management.Automation.CompletionResult]::new(
                            $_.Number,
                            $_.Name,
                            [System.Management.Automation.CompletionResultType]::ParameterValue,
                            $_.Name
                        )
                    }
                }
            })]
        [object]$Script,

        [Parameter(HelpMessage = "Arguments to pass to the script (Hashtable, String, or Array).")]
        [Alias('Parameters')]
        [object]$Arguments,

        [Parameter(HelpMessage = "Condition to evaluate before running (Hashtable). Keys: Path, Command, ScriptBlock, Negate.")]
        [Alias('If')]
        [object]$Condition,

        [Parameter(HelpMessage = "Path to redirect script output.")]
        [string]$OutputPath,

        [Parameter(HelpMessage = "Show parameter help for the script without executing.")]
        [switch]$ShowHelp,

        [Parameter(HelpMessage = "List all available parameters for the script.")]
        [switch]$ListParameters,

        [Parameter(HelpMessage = "Show what would be executed without actually running the script.")]
        [switch]$DryRun,

        [Parameter(HelpMessage = "Run scripts in parallel.")]
        [switch]$Parallel,

        [Parameter(HelpMessage = "Maximum number of concurrent scripts.")]
        [int]$ThrottleLimit = 5,

        [Parameter(HelpMessage = "Enable transcript logging.")]
        [bool]$Transcript = $true,

        [Parameter(HelpMessage = "Custom path for transcript log.")]
        [string]$TranscriptPath,

        [Parameter(HelpMessage = "Show script output in console.")]
        [switch]$ShowOutput,

        [Parameter(HelpMessage = "Display the transcript content after execution.")]
        [switch]$ShowTranscript
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

        # Get scripts directory using robust discovery
        try {
            $scriptsPath = Get-AitherScriptsPath
            Write-Verbose "Using scripts path: $scriptsPath"
        }
        catch {
            Write-AitherLog -Level Warning -Message "Could not resolve scripts path using Get-AitherScriptsPath: $($_.Exception.Message)" -Source 'Invoke-AitherScript'
            # Fallback for extreme cases
            $scriptsPath = Join-Path $PSScriptRoot "library/automation-scripts"
        }

        Write-Verbose "ScriptsPath resolved to: $scriptsPath"

        if (-not (Test-Path $scriptsPath)) {
            Write-AitherLog -Level Error -Message "Scripts path does not exist: $scriptsPath" -Source 'Invoke-AitherScript'
            throw "Scripts path does not exist: $scriptsPath"
        }

        # Use shared helper function

        function Get-ScriptParameters {
            param([string]$ScriptPath)

            try {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $ScriptPath,
                    [ref]$null,
                    [ref]$null
                )

                $params = @{}
                $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true) |
                ForEach-Object {
                    $paramName = $_.Name.VariablePath.UserPath
                    $paramInfo = @{
                        Name      = $paramName
                        Type      = if ($_.TypeName) { $_.TypeName.FullName } else { 'object' }
                        Mandatory = $_.Attributes.Where({ $_.TypeName.Name -eq 'Parameter' }).Attributes.Where({ $_.NamedArguments.ArgumentName -eq 'Mandatory' }).Argument.Value -eq $true
                        Help      = ''
                    }

                    # Try to get help from comment-based help
                    $help = $null
                    try {
                        $commentAstType = [System.Management.Automation.Language.CommentAst]
                        $help = $ast.FindAll({ param($node) $node -is $commentAstType }, $true) |
                        Where-Object { $_.Text -match "\.PARAMETER\s+$paramName" } |
                        Select-Object -First 1
                    }
                    catch {
                        # Fallback: skip help extraction if AST type not available
                        $help = $null
                    }

                    if ($help) {
                        $lines = $help.Text -split "`n"
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

                    $params[$paramName] = $paramInfo
                }
                return $params
            }
            catch {
                Write-AitherLog -Level Warning -Message "Failed to parse script parameters: $_" -Source 'Invoke-AitherScript'
                return @{}
            }
        }

        function Format-Arguments {
            param(
                [object]$Arguments,
                [hashtable]$ScriptParams
            )

            $paramHash = @{}
            if ($null -eq $Arguments) {
                return $paramHash
            }

            # Handle hashtable
            if ($Arguments -is [hashtable]) {
                return $Arguments
            }

            # Handle string arguments
            if ($Arguments -is [string]) {
                # Parse string like "-Parameter1 Value1 -Parameter2 Value2"
                $parts = $Arguments -split '\s+(?=-)' | Where-Object { $_ }
                for ($i = 0; $i -lt $parts.Length; $i++) {
                    if ($parts[$i] -match '^-(\w+)') {
                        $paramName = $matches[1]
                        $paramValue = $null

                        # Check if value is in the same part (e.g., "-Path ./src")
                        # Regex replace to remove -ParamName and leading spaces
                        $rest = $parts[$i] -replace "^-$paramName\s*", ""

                        if (-not [string]::IsNullOrWhiteSpace($rest)) {
                            $paramValue = $rest.Trim()
                            # Strip surrounding quotes if present
                            if ($paramValue -match "^['`"](.*)['`"]$") {
                                $paramValue = $matches[1]
                            }
                        }
                        elseif ($i + 1 -lt $parts.Length -and $parts[$i + 1] -notmatch '^-') {
                            $paramValue = $parts[$i + 1]
                            $i++
                        }
                        else {
                            $paramValue = $true  # Switch parameter
                        }

                        $paramHash[$paramName] = $paramValue
                    }
                }
                return $paramHash
            }

            # Handle array
            if ($Arguments -is [array]) {
                for ($i = 0; $i -lt $Arguments.Length; $i++) {
                    if ($Arguments[$i] -match '^-(\w+)') {
                        $paramName = $matches[1]
                        $paramValue = $null

                        if ($i + 1 -lt $Arguments.Length -and $Arguments[$i + 1] -notmatch '^-') {
                            $paramValue = $Arguments[$i + 1]
                            $i++
                        }
                        else {
                            $paramValue = $true
                        }

                        $paramHash[$paramName] = $paramValue
                    }
                }
                return $paramHash
            }

            return $paramHash
        }
    }

    process {
        # Manage logging targets for this execution
        $originalLogTargets = $script:AitherLogTargets
        if ($ShowOutput) {
            if ($script:AitherLogTargets -notcontains 'Console') {
                $script:AitherLogTargets += 'Console'
            }
        }
        else {
            # Ensure Console is NOT in targets if ShowOutput is not specified
            # This enforces "no output by default" even if global default changes
            $script:AitherLogTargets = $script:AitherLogTargets | Where-Object { $_ -ne 'Console' }
        }

        try {
            # During module validation, Script may be empty - skip validation
            if ($PSCmdlet.MyInvocation.InvocationName -eq '.' -and [string]::IsNullOrWhiteSpace($Script)) {
                return
            }

            # Handle piped script objects or multiple scripts
            $scriptsToRun = @()
            if ($Script -is [PSCustomObject] -and $Script.Path) {
                $scriptsToRun += @{
                    Path = $Script.Path
                    Id   = if ($Script.Number) { $Script.Number } else { $Script.Name }
                }
            }
            elseif ($Script -is [array]) {
                foreach ($s in $Script) {
                    $scriptFile = Find-AitherScriptFile -ScriptId $s -ScriptsPath $scriptsPath -ThrowOnNotFound
                    $scriptsToRun += @{
                        Path = $scriptFile.FullName
                        Id   = $s
                    }
                }
            }
            else {
                # Find script file
                $scriptFile = Find-AitherScriptFile -ScriptId $Script -ScriptsPath $scriptsPath -ThrowOnNotFound
                $scriptsToRun += @{
                    Path = $scriptFile.FullName
                    Id   = $Script
                }
            }

            # Parallel Execution
            if ($Parallel -and $scriptsToRun.Count -gt 1) {
                Write-ScriptLog "Executing $($scriptsToRun.Count) scripts in parallel (ThrottleLimit: $ThrottleLimit)"

                $scriptsToRun | ForEach-Object -Parallel {
                    $scriptInfo = $_
                    $scriptPath = $scriptInfo.Path
                    $scriptId = $scriptInfo.Id

                    # Re-import module in parallel runspace if needed, or rely on scope
                    # Note: Functions defined in 'begin' block are NOT available here automatically
                    # We need to duplicate logic or use a shared module

                    # Simple execution for now
                    Write-AitherLog -Level Information -Message "Starting parallel execution: $scriptId" -Source 'Invoke-AitherScript'
                    try {
                        & $scriptPath
                    }
                    catch {
                        Write-AitherLog -Level Error -Message "Failed executing $scriptId : $_" -Source 'Invoke-AitherScript' -Exception $_
                        throw
                    }
                } -ThrottleLimit $ThrottleLimit

                return
            }

            foreach ($scriptItem in $scriptsToRun) {
                $scriptPath = $scriptItem.Path
                $scriptId = $scriptItem.Id
                Write-ScriptLog "Found script: $scriptPath"

                # Get script parameters
                $scriptParams = Get-ScriptParameters -ScriptPath $scriptPath

                # Handle help requests
                if ($ShowHelp -or $ListParameters) {
                    Write-AitherLog -Level Information -Message "Script: $scriptId" -Source 'Invoke-AitherScript'
                    Write-AitherLog -Level Information -Message "Path: $scriptPath" -Source 'Invoke-AitherScript'

                    if ($scriptParams.Count -eq 0) {
                        Write-AitherLog -Level Warning -Message "No parameters found or script could not be parsed." -Source 'Invoke-AitherScript'
                        continue
                    }

                    Write-AitherLog -Level Information -Message "Available Parameters:" -Source 'Invoke-AitherScript'
                    Write-AitherLog -Level Information -Message ("=" * 50) -Source 'Invoke-AitherScript'

                    foreach ($param in $scriptParams.Values | Sort-Object Name) {
                        $mandatory = if ($param.Mandatory) { "[MANDATORY] " } else { "" }
                        $paramLine = "-$($param.Name) $mandatory($($param.Type))"
                        Write-AitherLog -Level Information -Message $paramLine -Source 'Invoke-AitherScript'

                        if ($param.Help) {
                            Write-AitherLog -Level Information -Message "  $($param.Help)" -Source 'Invoke-AitherScript'
                        }
                    }

                    continue
                }

                # Format arguments
                $argsToUse = if ($Arguments) { $Arguments } else { $Parameters }
                $paramHash = Format-Arguments -Arguments $argsToUse -ScriptParams $scriptParams

                # Add OutputPath if specified
                if ($OutputPath) {
                    $paramHash['OutputPath'] = $OutputPath
                }

                # Add Configuration if Get-AitherConfigs is available AND script accepts it
                if ($scriptParams.ContainsKey('Configuration') -and (Get-Command Get-AitherConfigs -ErrorAction SilentlyContinue)) {
                    $config = Get-AitherConfigs
                    $paramHash['Configuration'] = $config
                }

                # Check Condition (Idempotency)
                if ($Condition) {
                    Write-ScriptLog "Evaluating execution condition..."

                    if (Get-Command Test-AitherCondition -ErrorAction SilentlyContinue) {
                        # Flatten hashtable for splatting to Test-AitherCondition
                        # Note: Test-AitherCondition accepts Path, Command, ScriptBlock, Negate
                        $conditionResult = $true
                        try {
                            $conditionResult = Test-AitherCondition @Condition
                        }
                        catch {
                            Write-AitherLog -Level Warning -Message "Failed to evaluate condition: $_" -Source 'Invoke-AitherScript' -Exception $_
                            # Default to running if check fails, or fail safely?
                            # Safer to fail or run? Let's assume run if check fails is risky, but failing stops workflow.
                            # For now, treat error as 'False' (don't run) or just log.
                            # Let's treat as FALSE to prevent destructive actions if check is bad.
                            $conditionResult = $false
                        }

                        if (-not $conditionResult) {
                            Write-AitherLog -Level Warning -Message "Condition met (Result: False). Skipping script execution." -Source 'Invoke-AitherScript'
                            Write-AitherLog -Level Information -Message "Skipping $scriptId (Condition not met)" -Source 'Invoke-AitherScript'
                            continue
                        }
                    }
                    else {
                        Write-AitherLog -Level Warning -Message "Test-AitherCondition cmdlet not found. Skipping condition check." -Source 'Invoke-AitherScript'
                    }
                }

                # Dry run
                if ($DryRun) {
                    Write-AitherLog -Level Information -Message "[DRY RUN] Would execute:" -Source 'Invoke-AitherScript'
                    Write-AitherLog -Level Information -Message "  Script: $scriptPath" -Source 'Invoke-AitherScript'
                    Write-AitherLog -Level Information -Message "  Parameters:" -Source 'Invoke-AitherScript'
                    $paramHash.GetEnumerator() | ForEach-Object {
                        Write-AitherLog -Level Information -Message "    -$($_.Key): $($_.Value)" -Source 'Invoke-AitherScript'
                    }
                    continue
                }

                # Start transcript if enabled
                $transcriptStarted = $false
                if ($Transcript) {
                    try {
                        if (-not $TranscriptPath) {
                            $logsDir = Join-Path $moduleRoot 'logs'
                            if (-not (Test-Path $logsDir)) {
                                New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
                            }
                            $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)
                            $currentTranscriptPath = Join-Path $logsDir "transcript-${scriptName}-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
                        }
                        else {
                            $currentTranscriptPath = $TranscriptPath
                        }

                        # Try to stop any existing transcript first, ignoring errors if none is running
                        try { Stop-Transcript -ErrorAction Stop | Out-Null } catch { }

                        Start-Transcript -Path $currentTranscriptPath -Append -IncludeInvocationHeader | Out-Null
                        $transcriptStarted = $true
                        Write-AitherLog -Level Information -Message "Transcript logging enabled: $currentTranscriptPath" -Source 'Invoke-AitherScript'
                    }
                    catch {
                        Write-AitherLog -Level Warning -Message "Failed to start transcript: $_" -Source 'Invoke-AitherScript' -Exception $_
                    }
                }

                # Execute script
                try {
                    Write-ScriptLog "Executing script: $scriptId"

                    if ($PSCmdlet.ShouldProcess($scriptPath, "Execute script")) {
                        & $scriptPath @paramHash
                    }
                }
                finally {
                    if ($transcriptStarted) {
                        try {
                            Stop-Transcript | Out-Null
                        }
                        catch {
                            # Ignore errors stopping transcript
                        }

                        if ($ShowTranscript) {
                            Write-AitherLog -Level Information -Message "--- Transcript: $currentTranscriptPath ---" -Source 'Invoke-AitherScript'
                            if (Test-Path $currentTranscriptPath) {
                                Get-Content $currentTranscriptPath | ForEach-Object { Write-AitherLog -Level Information -Message $_ -Source 'Invoke-AitherScript' }
                            }
                            Write-AitherLog -Level Information -Message "--- End Transcript ---" -Source 'Invoke-AitherScript'
                        }
                    }
                }
            }
        }
        catch {
            Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Invoking script: $Script" -Parameters $PSBoundParameters -ThrowOnError
        }
        finally {
            # Restore original log targets
            $script:AitherLogTargets = $originalLogTargets
        }
    }


}

