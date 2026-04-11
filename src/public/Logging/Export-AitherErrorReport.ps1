#Requires -Version 7.0

<#
.SYNOPSIS
    Generate comprehensive error reports for debugging and support

.DESCRIPTION
    Generates detailed error reports in multiple formats (JSON, HTML, Text) suitable for
    debugging, support tickets, or documentation. Includes all context, stack traces,
    parameters, and environment information needed to diagnose issues.

.PARAMETER Since
    Include errors since this date/time. Default is last 24 hours.

.PARAMETER Until
    Include errors until this date/time.

.PARAMETER Cmdlet
    Filter errors by cmdlet name(s).

.PARAMETER OutputPath
    Path where the error report will be saved. Default is library/logs/error-reports/ directory.

.PARAMETER Format
    Report format: JSON (machine-readable), HTML (human-readable), Text (plain text), or All (all formats).

.PARAMETER IncludeEnvironment
    Include environment information (PowerShell version, OS, modules, etc.) in the report.

.PARAMETER IncludeStackTraces
    Include full stack traces in the report. Useful for deep debugging.

.INPUTS
    System.String
    You can pipe cmdlet names to Export-AitherErrorReport.

.OUTPUTS
    System.String
    Returns the path to the generated report file(s).

.EXAMPLE
    Export-AitherErrorReport

    Generates an error report for the last 24 hours in JSON format.

.EXAMPLE
    Export-AitherErrorReport -Since (Get-Date).AddDays(-7) -Format HTML

    Generates an HTML report for the last week.

.EXAMPLE
    Export-AitherErrorReport -Cmdlet "Invoke-AitherScript" -Format All -IncludeStackTraces

    Generates all format reports for Invoke-AitherScript errors with stack traces.

.EXAMPLE
    Export-AitherErrorReport -OutputPath "C:\Reports\errors.json" -Format JSON

    Generates a JSON report in a custom location.

.NOTES
    Error reports are comprehensive and include:
    - All error details (message, exception, stack trace)
    - Parameters that were passed
    - Environment information
    - System configuration
    - Timeline of errors

    Use these reports for:
    - Submitting bug reports
    - Internal debugging
    - Documentation of issues
    - Performance analysis

.LINK
    Get-AitherErrorLog
    Write-AitherLog
#>
function Export-AitherErrorReport {
[OutputType([System.String])]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [DateTime]$Since = (Get-Date).AddDays(-1),

    [Parameter()]
    [DateTime]$Until,

    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$Cmdlet,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateSet('JSON', 'HTML', 'Text', 'All')]
    [string]$Format = 'JSON',

    [switch]$IncludeEnvironment,

    [switch]$IncludeStackTraces,

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

    if (-not $OutputPath) {
        $OutputPath = Join-Path $moduleRoot 'AitherZero/library/logs' 'error-reports'
    }
        if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $errors = @()
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return
        }

        # Check if Write-AitherLog is available
        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue
        # Collect errors
        $errorParams = @{
            Since = $Since
            Count = -1
        }
        if ($Until) {
            $errorParams.Until = $Until
        }
        if ($Cmdlet) {
            $errorParams.Cmdlet = $Cmdlet
        }

        $errors = Get-AitherErrorLog @errorParams
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Level Warning -Message "Error collecting errors for report: $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name
        } else {
            Write-Warning "Error collecting errors for report: $($_.Exception.Message)"
        }
    }
}

end {
    try {
        try {
        $reportData = @{
            ReportGenerated = Get-Date
            ReportPeriod = @{
                Since = $Since
                Until = if ($Until) { $Until }
    else { Get-Date }
            }
            TotalErrors = $errors.Count
            Errors = $errors
        }
        if ($IncludeEnvironment) {
            $reportData.Environment = @{
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                OS = if ($IsWindows) { "Windows" }
    elseif ($IsLinux) { "Linux" }
    elseif ($IsMacOS) { "macOS" }
    else { "Unknown" }
                ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME }
    else { $env:HOSTNAME }
                UserName = if ($IsWindows) { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    else { $env:USER }
                ModuleVersion = (Get-Module AitherZero -ErrorAction SilentlyContinue).Version.ToString()
            }
        }

        $generatedFiles = @()

        # Generate JSON report
        if ($Format -in @('JSON', 'All')) {
            $jsonFile = Join-Path $OutputPath "error-report-${timestamp}.json"

            if ($PSCmdlet.ShouldProcess($jsonFile, "Generate JSON error report")) {
                $reportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonFile -Encoding UTF8 -Force
                $generatedFiles += $jsonFile

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Information -Message "Generated JSON error report: $jsonFile" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
            }
        }

        # Generate HTML report
        if ($Format -in @('HTML', 'All')) {
            $htmlFile = Join-Path $OutputPath "error-report-${timestamp}.html"

            if ($PSCmdlet.ShouldProcess($htmlFile, "Generate HTML error report")) {
                $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AitherZero Error Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #d32f2f; }
        .error { border: 1px solid #ccc; margin: 10px 0; padding: 10px; background: #fff3cd; }
        .error-header { font-weight: bold; color: #d32f2f; }
        .timestamp { color: #666; font-size: 0.9em; }
        pre { background: #f5f5f5; padding: 10px; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>AitherZero Error Report</h1>
    <p><strong>Generated:</strong> $($reportData.ReportGenerated)</p>
    <p><strong>Period:</strong> $($reportData.ReportPeriod.Since) to $($reportData.ReportPeriod.Until)</p>
    <p><strong>Total Errors:</strong> $($reportData.TotalErrors)</p>

    $(if ($IncludeEnvironment) {
        "<h2>Environment</h2><pre>$($reportData.Environment | ConvertTo-Json -Depth 10)</pre>"
    })

    <h2>Errors</h2>
    $(foreach ($err in $errors) {
        $stackTrace = if ($IncludeStackTraces -and $err.StackTrace) { "<pre>$($err.StackTrace)</pre>" }
    else { "" }
        @"
    <div class="error">
        <div class="error-header">$($err.Cmdlet) - $($err.Message)</div>
        <div class="timestamp">$($err.Timestamp)</div>
        <p><strong>Error ID:</strong> $($err.ErrorId)</p>
        $(if ($err.Parameters) { "<p><strong>Parameters:</strong> <pre>$($err.Parameters | ConvertTo-Json -Compress)</pre></p>" })
        $stackTrace
    </div>
"@
    })
</body>
</html>
"@
                $html | Out-File -FilePath $htmlFile -Encoding UTF8 -Force
                $generatedFiles += $htmlFile

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Information -Message "Generated HTML error report: $htmlFile" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
            }
        }

        # Generate Text report
        if ($Format -in @('Text', 'All')) {
            $textFile = Join-Path $OutputPath "error-report-${timestamp}.txt"

            if ($PSCmdlet.ShouldProcess($textFile, "Generate text error report")) {
                $text = @"
AitherZero Error Report
========================

Generated: $($reportData.ReportGenerated)
Period: $($reportData.ReportPeriod.Since) to $($reportData.ReportPeriod.Until)
Total Errors: $($reportData.TotalErrors)

$(if ($IncludeEnvironment) {
    "Environment Information:
$(($reportData.Environment | ConvertTo-Json -Depth 10))
"
})

Errors:
-------

$(foreach ($err in $errors) {
    @"
[$($err.Timestamp)] $($err.Cmdlet)
  Error ID: $($err.ErrorId)
  Message: $($err.Message)
  $(if ($err.Parameters) { "Parameters: $($err.Parameters | ConvertTo-Json -Compress)`n  " })
  $(if ($IncludeStackTraces -and $err.StackTrace) { "Stack Trace:`n  $($err.StackTrace -replace "`n", "`n  ")`n  " })

"@
})
"@
                $text | Out-File -FilePath $textFile -Encoding UTF8 -Force
                $generatedFiles += $textFile

                if ($hasWriteAitherLog) {
                    Write-AitherLog -Level Information -Message "Generated text error report: $textFile" -Source $PSCmdlet.MyInvocation.MyCommand.Name
                }
                }
                }return $generatedFiles
        }
    catch {
        # Use centralized error handling
        $errorScript = Join-Path $PSScriptRoot '..' 'Private' 'Write-AitherError.ps1'
        if (Test-Path $errorScript) {
            . $errorScript -ErrorRecord $_ -CmdletName $PSCmdlet.MyInvocation.MyCommand.Name -Operation "Generating error report" -Parameters $PSBoundParameters -ThrowOnError
        }
    else {
            $errorObject = [PSCustomObject]@{
                PSTypeName = 'AitherZero.Error'
                Success = $false
                ErrorId = [System.Guid]::NewGuid().ToString()
                Cmdlet = $PSCmdlet.MyInvocation.MyCommand.Name
                Operation = "Generating error report"
                Error = $_.Exception.Message
                Timestamp = Get-Date
            }
            Write-Output $errorObject

            if ($hasWriteAitherLog) {
                Write-AitherLog -Level Error -Message "Failed to generate error report: $($_.Exception.Message)" -Source $PSCmdlet.MyInvocation.MyCommand.Name -Exception $_
            } else {
                Write-AitherLog -Level Error -Message "Failed to generate error report: $($_.Exception.Message)" -Source 'Export-AitherErrorReport' -Exception $_
            }
        }
        throw
    }
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}


}

