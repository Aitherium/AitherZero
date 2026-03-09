#Requires -Version 7.0

<#
.SYNOPSIS
    Generate dashboard HTML from template and metrics

.DESCRIPTION
    Renders HTML dashboard using templates and collected metrics.
    Supports template variable replacement for dynamic content.

.PARAMETER TemplateName
    Name of the HTML template file (without .html extension, default: 'dashboard')

.PARAMETER OutputFile
    Output filename for the generated HTML (default: 'dashboard.html')

.PARAMETER Data
    Optional hashtable of additional data for template replacement

.EXAMPLE
    New-AitherDashboard

    Generate dashboard HTML using default template and filename

.EXAMPLE
    New-AitherDashboard -TemplateName 'main' -OutputFile 'dashboard.html'

    Generate dashboard HTML using main template

.OUTPUTS
    Boolean - True if dashboard was generated successfully, False otherwise

.NOTES
    Templates should be located in library/templates/dashboard/ directory.
    Template variables use {{VariableName}} syntax for replacement.

.LINK
    Initialize-AitherDashboard
    Register-AitherMetrics
    Export-AitherMetrics
#>
function New-AitherDashboard {
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$TemplateName = 'dashboard',

    [Parameter(Mandatory=$false)]
    [string]$OutputFile = 'dashboard.html',

    [hashtable]$Data = @{},

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

    # During module validation, skip check
    if ($PSCmdlet.MyInvocation.InvocationName -ne '.') {
        if (-not $script:DashboardConfig) {
            throw "Dashboard session not initialized. Call Initialize-AitherDashboard first."
        }
    }
}

process { try {
        # During module validation, skip execution
        if ($PSCmdlet.MyInvocation.InvocationName -eq '.') {
            return $false
        }

        $hasWriteAitherLog = Get-Command Write-AitherLog -ErrorAction SilentlyContinue

        $moduleRoot = Get-AitherModuleRoot
        $templatePath = Join-Path $moduleRoot 'library' 'templates' 'dashboard' "$TemplateName.html"

        if (-not (Test-Path $templatePath)) {
            if ($hasWriteAitherLog) {
                Write-AitherLog -Message "Template not found: $templatePath" -Level Warning -Source 'New-AitherDashboard'
            } else {
                Write-AitherLog -Level Warning -Message "Template not found: $templatePath" -Source 'New-AitherDashboard'
            }
            return $false
        }

        $template = Get-Content -Path $templatePath -Raw

        # Simple template variable replacement
        foreach ($key in $Data.Keys) {
            $template = $template -replace "\{\{$key\}\}", $Data[$key]
        }

        # Replace metrics placeholder if present
        if ($script:CollectedMetrics) {
            $metricsJson = $script:CollectedMetrics | ConvertTo-Json -Depth 10 -Compress
            $template = $template -replace '\{\{Metrics\}\}', $metricsJson
        }

        $outputPath = Join-Path $script:DashboardConfig.OutputPath $OutputFile
        $template | Out-File -FilePath $outputPath -Encoding utf8 -Force

        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Generated HTML: $outputPath" -Level Information -Source 'New-AitherDashboard'
        }
        return $true
    }
    catch {
        if ($hasWriteAitherLog) {
            Write-AitherLog -Message "Failed to generate HTML from template: $($_.Exception.Message)" -Level Error -Source 'New-AitherDashboard' -Exception $_
        } else {
            Write-AitherLog -Level Error -Message "Failed to generate HTML from template: $($_.Exception.Message)" -Source 'New-AitherDashboard' -Exception $_
        }
        return $false
    }
    finally {
        # Restore original log targets
        $script:AitherLogTargets = $originalLogTargets
    }
}

}

