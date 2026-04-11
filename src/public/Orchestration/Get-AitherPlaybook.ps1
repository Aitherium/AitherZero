#Requires -Version 7.0

<#
.SYNOPSIS
    Get playbook definitions and information

.DESCRIPTION
    Retrieves playbook definitions from the playbooks directory.
    Can list all playbooks, get a specific playbook, or search playbooks.

    Playbooks define automation workflows including scripts, execution order,
    dependencies, and success criteria. This cmdlet helps discover and load
    playbooks for execution or inspection.

.PARAMETER Name
    Name of the playbook to retrieve (without extension). This parameter is REQUIRED
    when using the Get parameter set. The playbook file must exist in the playbooks directory.

    Examples:
    - "test-orchestration"
    - "pr-validation"
    - "deployment"

    The name should match the playbook file name (without .psd1 extension).

.PARAMETER List
    List all available playbooks. This is the default behavior if no parameters are provided.
    Returns a summary of all playbooks with their names, descriptions, and versions.

    Use this to discover available playbooks or verify playbook availability.

.PARAMETER Search
    Search playbooks by name or description. Uses pattern matching to find playbooks
    containing the search term. Case-insensitive search.

    Examples:
    - "validation" - Finds playbooks with "validation" in name or description
    - "test" - Finds all test-related playbooks
    - "deploy" - Finds deployment playbooks

.PARAMETER Path
    Return only the file path to the playbook instead of loading its contents.
    Useful when you need the file path for other operations or file manipulation.

    Returns the full path to the playbook file (e.g., "C:\...\library\playbooks\playbook.psd1").

.INPUTS
    System.String
    You can pipe playbook names to Get-AitherPlaybook.

.OUTPUTS
    PSCustomObject
    Returns playbook objects with properties:
    - Name: Playbook name
    - Description: Playbook description
    - Version: Playbook version
    - Path: File path (when -List or -Search)
    - FileName: File name (when -List or -Search)

    When -Path is used, returns System.String (the file path).

    When a specific playbook is retrieved, returns the full playbook hashtable.

.EXAMPLE
    Get-AitherPlaybook -List

    Lists all available playbooks with their basic information.

.EXAMPLE
    $playbook = Get-AitherPlaybook -Name 'test-orchestration'

    Loads a specific playbook and stores it in a variable for execution.

.EXAMPLE
    Get-AitherPlaybook -Search 'validation'

    Searches for playbooks containing "validation" in their name or description.

.EXAMPLE
    Get-AitherPlaybook -Name 'deployment' -Path

    Gets only the file path to the deployment playbook.

.EXAMPLE
    "test-orchestration", "pr-validation" | Get-AitherPlaybook

    Gets multiple playbooks by piping playbook names.

.EXAMPLE
    $playbook = Get-AitherPlaybook -Name 'deployment'
    $playbook.Scripts

    Loads a playbook and inspects its scripts property.

.NOTES
    Playbooks are stored in library/playbooks/ directory as PowerShell Data (.psd1) files.
    Each playbook file contains a hashtable defining:
    - Name: Playbook identifier
    - Description: What the playbook does
    - Version: Playbook version
    - Scripts: Array of scripts to execute
    - ExecutionMode: Parallel, Sequential, or Mixed
    - Dependencies: Script dependencies
    - SuccessCriteria: What constitutes success

    Playbooks can be created manually or using New-AitherPlaybook and Save-AitherPlaybook.

.LINK
    Invoke-AitherPlaybook
    Save-AitherPlaybook
    New-AitherPlaybook
#>
function Get-AitherPlaybook {
[OutputType([PSCustomObject], [Hashtable], [System.String])]
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
    [Parameter(ParameterSetName = 'Get', Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName, HelpMessage = "Name of the playbook to retrieve (e.g., 'pr-validation').")]
    [ValidateNotNullOrEmpty()]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        if (Get-Command Get-AitherPlaybook -ErrorAction SilentlyContinue) {
            Get-AitherPlaybook -List | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ParameterValue', $_.Description)
            }
        }
    })]
    [string]$Name,

    [Parameter(ParameterSetName = 'List', HelpMessage = "List all available playbooks.")]
    [switch]$List,

    [Parameter(ParameterSetName = 'Search', HelpMessage = "Search playbooks by name or description.")]
    [string]$Search,

    [Parameter(ParameterSetName = 'Get', HelpMessage = "Return only the file path to the playbook.")]
    [switch]$Path,

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

    # Use environment variable set by module initialization instead of calling private function
    $moduleRoot = if ($env:AITHERZERO_ROOT) {
        $env:AITHERZERO_ROOT
    } else {
        Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    }
    $playbooksPath = Join-Path $moduleRoot 'library' 'playbooks'
}

process {
    try {
        try {
        if (-not (Test-Path $playbooksPath)) {
            Write-AitherLog -Level Warning -Message "Playbooks directory not found: $playbooksPath" -Source 'Get-AitherPlaybook'
            return @()
        }

        $playbooks = Get-ChildItem -Path $playbooksPath -Filter '*.psd1' -ErrorAction SilentlyContinue

        # List all playbooks
        if ($List -or $PSCmdlet.ParameterSetName -eq 'List') {
            return $playbooks | ForEach-Object {
                try {
                    $content = Get-Content $_.FullName -Raw
                    $scriptBlock = [scriptblock]::Create($content)
                    $playbook = & $scriptBlock

                    [PSCustomObject]@{
                        Name = $playbook.Name
                        Description = $playbook.Description
                        Version = $playbook.Version
                        Path = $_.FullName
                        FileName = $_.Name
                    }
                }
                catch {
                    [PSCustomObject]@{
                        Name = $_.BaseName
                        Description = "Error loading playbook"
                        Version = $null
                        Path = $_.FullName
                        FileName = $_.Name
                    }
                }
            }
        }

        # Search playbooks
        if ($Search) {
            return $playbooks | ForEach-Object {
                try {
                    $content = Get-Content $_.FullName -Raw
                    $scriptBlock = [scriptblock]::Create($content)
                    $playbook = & $scriptBlock

                    $searchText = "$($playbook.Name) $($playbook.Description)" -replace '-', ' '
                    if ($searchText -match $Search) {
                        [PSCustomObject]@{
                            Name = $playbook.Name
                            Description = $playbook.Description
                            Version = $playbook.Version
                            Path = $_.FullName
                            FileName = $_.Name
                        }
                    }
                }
                catch {
                    # Skip playbooks that can't be loaded
                }
            } | Where-Object { $_ }
        }

        # Get specific playbook
        if ($Name) {
            $playbookFile = $playbooks | Where-Object {
                $_.BaseName -eq $Name -or $_.BaseName -like "*$Name*"
            } | Select-Object -First 1

            if (-not $playbookFile) {
                throw "Playbook not found: $Name"
            }

            if ($Path) {
                return $playbookFile.FullName
            }

            $content = Get-Content $playbookFile.FullName -Raw
            $scriptBlock = [scriptblock]::Create($content)
            return & $scriptBlock
        }
    }
    catch {
        Invoke-AitherErrorHandler -ErrorRecord $_ -Operation "Getting playbook: $Name" -Parameters $PSBoundParameters -ThrowOnError
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}
}

