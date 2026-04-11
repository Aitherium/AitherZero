<#
.SYNOPSIS
    Lists available AitherOS agents and their status.
.DESCRIPTION
    Scans the AitherOS/agents directory and checks for running agent processes.
    Returns a list of agent objects.
.EXAMPLE
    ./0754_List-Agents.ps1 -AsJson
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$AsJson,

    [Parameter()]
    [switch]$ShowOutput
)

$ErrorActionPreference = "Stop"

# Resolve Paths
$RepoRoot = Resolve-Path "$PSScriptRoot/../../.."
$AgentsDir = Join-Path $RepoRoot "AitherOS/agents"

if (-not (Test-Path $AgentsDir)) {
    if ($AsJson) { Write-Output "[]" }
    exit 0
}

$Agents = @()
$AgentFolders = Get-ChildItem -Path $AgentsDir -Directory

foreach ($Folder in $AgentFolders) {
    $AgentName = $Folder.Name
    if ($AgentName -eq "common" -or $AgentName -eq "__pycache__") { continue }

    $Status = "stopped"
    if ($IsWindows) {
        $Proc = Get-CimInstance Win32_Process -Filter "CommandLine like '%$AgentName%'" -ErrorAction SilentlyContinue
        if ($Proc) { $Status = "running" }
    } else {
        try {
            # Try native ps command for Linux/Mac to get full command line
            # PowerShell's Get-Process on Linux might not show full command line arguments in all versions
            if ($IsLinux -or $IsMacOS) {
                # Use sh to bypass PowerShell alias 'ps' -> 'Get-Process'
                $psOut = sh -c "ps -ef" | Select-String $AgentName
                if ($psOut) { $Status = "running" }
            }
        } catch {
            Write-Verbose "Failed to check process status on non-Windows: $_"
        }
    }

    $Category = "general"
    if ($AgentName -match "Automation") { $Category = "automation" }
    elseif ($AgentName -match "Narrative") { $Category = "narrative" }
    elseif ($AgentName -match "Infra") { $Category = "infrastructure" }

    $Agents += [PSCustomObject]@{
        id = $AgentName
        name = $AgentName -replace "Agent", " Agent" -replace "([a-z])([A-Z])", '$1 $2'
        category = $Category
        status = $Status
        workingDirectory = $Folder.FullName
        hasWorkflows = (Test-Path (Join-Path $Folder.FullName "workflows"))
        hasMCPClient = $true
    }
}

if ($AsJson) {
    $Agents | ConvertTo-Json -Depth 3
} elseif ($ShowOutput) {
    $Agents | Format-Table -AutoSize | Out-String | Write-Host
    Write-Output $Agents
}
