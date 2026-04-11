<#
.SYNOPSIS
    Retrieves the status of GitHub Actions workflows for the repository.
.DESCRIPTION
    Uses the GitHub CLI (gh) to fetch the status of recent workflow runs.
    If gh is not installed or not authenticated, returns a warning status.
.EXAMPLE
    ./0705_Get-WorkflowStatus.ps1
#>
param(
    [Parameter()]
    [switch]$AsJson,

    [Parameter()]
    [switch]$ShowOutput
)

$ErrorActionPreference = "Stop"

function Get-WorkflowStatus {
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        try {
            # Check auth status first
            # Redirect stderr to null to avoid noise
            gh auth status 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                # Get recent runs
                $runs = gh run list --limit 5 --json name,status,conclusion,databaseId,url | ConvertFrom-Json
                
                # Calculate aggregate health
                $failed = $runs | Where-Object { $_.conclusion -eq "failure" }
                
                $health = "healthy"
                if ($failed.Count -gt 0) { $health = "degraded" }
                
                return @{
                    status = "online"
                    health = $health
                    runs = $runs
                    message = "GitHub Actions connected"
                }
            } else {
                return @{
                    status = "offline"
                    health = "unknown"
                    message = "GitHub CLI not authenticated"
                }
            }
        } catch {
            return @{
                status = "error"
                health = "critical"
                message = "Failed to retrieve workflow status: $_"
            }
        }
    } else {
        return @{
            status = "offline"
            health = "unknown"
            message = "GitHub CLI (gh) not installed"
        }
    }
}

$result = Get-WorkflowStatus

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} elseif ($ShowOutput) {
    Write-Host "Status: $($result.status)" -ForegroundColor Cyan
    Write-Host "Health: $($result.health)" -ForegroundColor ($result.health -eq 'healthy' ? 'Green' : 'Red')
    Write-Output $result
}
