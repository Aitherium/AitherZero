#Requires -Version 7.0

<#
.SYNOPSIS
    Get execution history for scripts and playbooks

.DESCRIPTION
    Retrieves execution history, results, and logs from previous script/playbook runs.

.PARAMETER Script
    Filter by script number or name

.PARAMETER Playbook
    Filter by playbook name

.PARAMETER Last
    Get last N executions

.PARAMETER Since
    Get executions since this date

.PARAMETER Status
    Filter by status: Success, Failed, Running

.PARAMETER ShowLogs
    Include log content in output

.EXAMPLE
    Get-AitherExecutionHistory -Last 10

.EXAMPLE
    Get-AitherExecutionHistory -Script 0501 -Status Failed

.EXAMPLE
    Get-AitherExecutionHistory -Playbook 'pr-validation' -Since (Get-Date).AddDays(-7)

.NOTES
    Execution history is stored in library/reports/execution-history/
#>
function Get-AitherExecutionHistory {
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Script,

    [Parameter()]
    [string]$Playbook,

    [Parameter()]
    [int]$Last,

    [Parameter()]
    [datetime]$Since,

    [Parameter()]
    [ValidateSet('Success', 'Failed', 'Running', 'Cancelled')]
    [string]$Status,

    [Parameter()]
    [switch]$ShowLogs
)

begin {
    $moduleRoot = Get-AitherModuleRoot
    $historyPath = Join-Path $moduleRoot 'library' 'reports' 'execution-history'
    
    if (-not (Test-Path $historyPath)) {
        New-Item -ItemType Directory -Path $historyPath -Force | Out-Null
    }
}

process { try {
        $historyFiles = Get-ChildItem -Path $historyPath -Filter '*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

        $results = @()

        foreach ($file in $historyFiles) {
            try {
                $history = Get-Content $file.FullName | ConvertFrom-Json

                # Apply filters
                if ($Script -and $history.Script -notlike "*$Script*") { continue }
        if ($Playbook -and $history.Playbook -ne $Playbook) { continue }
        if ($Status -and $history.Status -ne $Status) { continue }
        if ($Since -and [datetime]$history.StartTime -lt $Since) { continue }

                $result = [PSCustomObject]@{
                    Id = $history.Id
                    Type = $history.Type
                    Script = $history.Script
                    Playbook = $history.Playbook
                    Status = $history.Status
                    StartTime = [datetime]$history.StartTime
                    EndTime = if ($history.EndTime) { [datetime]$history.EndTime } else { $null }
                    Duration = if ($history.Duration) { [TimeSpan]::Parse($history.Duration) } else { $null }
                    LogPath = $history.LogPath
                }
                
                if ($ShowLogs -and $history.LogPath -and (Test-Path $history.LogPath)) {
                    $result | Add-Member -NotePropertyName 'LogContent' -NotePropertyValue (Get-Content $history.LogPath -Raw)
                }

                $results += $result
            }
            catch {
                Write-AitherLog -Level Warning -Message "Failed to parse history file $($file.Name): $_" -Source 'Get-AitherExecutionHistory' -Exception $_
            }
        }

        # Apply Last filter
        if ($Last -gt 0) {
            $results = $results | Select-Object -First $Last
        }
        
        return $results
    }
    catch {
        Write-AitherLog -Level Error -Message "Failed to get execution history: $_" -Source 'Get-AitherExecutionHistory' -Exception $_
        throw
    }
}

}

