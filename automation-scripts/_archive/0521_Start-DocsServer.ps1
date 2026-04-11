<#
.SYNOPSIS
    Starts the MkDocs documentation server for local preview.

.DESCRIPTION
    This script starts the MkDocs documentation server, syncing all markdown
    files from the repository into the docs_build directory and serving them
    locally for preview.

.PARAMETER Port
    Port for the documentation server (default: 8000).

.PARAMETER Build
    Build static site instead of serving.

.PARAMETER ShowOutput
    Show detailed output (scripts are silent by default for pipelines).

.EXAMPLE
    .\0521_Start-DocsServer.ps1
    Starts documentation server at http://localhost:8000

.EXAMPLE
    .\0521_Start-DocsServer.ps1 -Port 8080
    Starts documentation server at http://localhost:8080

.EXAMPLE
    .\0521_Start-DocsServer.ps1 -Build
    Builds static site to ./site directory

.NOTES
    Script ID: 0521
    Category: Reporting/Documentation
    Exit Codes: 0 = Success, 1 = Failure
#>

[CmdletBinding()]
param(
    [Parameter()]
    [int]$Port = 8000,

    [Parameter()]
    [switch]$Build,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'

# Delegate to the main documentation script
$scriptPath = Join-Path $PSScriptRoot '0520_Build-Documentation.ps1'

$params = @{
    Port = $Port
    ShowOutput = $ShowOutput
}

if ($Build) {
    $params['Build'] = $true
} else {
    $params['Serve'] = $true
}

& $scriptPath @params
