#Requires -Version 7.0

<#
.SYNOPSIS
    Display comprehensive project dashboard with logs, tests, and metrics
.DESCRIPTION
    Shows an interactive dashboard with project metrics, test results,
    recent logs, module status, and recent activity.
#>
function Show-AitherDashboard {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ProjectPath,
        [switch]$ShowLogs,
        [switch]$ShowTests,
        [switch]$ShowMetrics,
        [switch]$ShowAll,
        [int]$LogTailLines = 50,
        [switch]$Follow
    )

    begin {
        if (-not $ProjectPath) {
            if (Get-Command Get-AitherProjectRoot -ErrorAction SilentlyContinue) {
                $ProjectPath = Get-AitherProjectRoot
            } else {
                # Fallback if Get-AitherProjectRoot is not available (e.g. during dev)
                # Assume we are in AitherZero/src/public/Dashboard
                $ProjectPath = $PSScriptRoot | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent | Split-Path -Parent
            }
        }
    }

    process {
        # Clear screen for dashboard
        Clear-Host

        function Show-Header {
            # Handle non-interactive environments
            $width = 80  # Default width
            if ($Host.UI.RawUI -and $Host.UI.RawUI.WindowSize) {
                try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
            }
            $line = "=" * $width

            Write-AitherLog -Level Information -Message $line -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message " AitherZero Project Dashboard " -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message $line -Source 'Show-AitherDashboard'
        }

        function Show-ProjectMetrics {
            Write-AitherLog -Level Information -Message "PROJECT METRICS" -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message ("-" * 40) -Source 'Show-AitherDashboard'

            # Get latest report
            $reportPath = Join-Path $ProjectPath "AitherZero/library/tests/reports"
            $latestReport = Get-ChildItem -Path $reportPath -Filter "ProjectReport-*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if ($latestReport) {
                $report = Get-Content $latestReport.FullName | ConvertFrom-Json

                Write-AitherLog -Level Information -Message "Total Files: $($report.FileAnalysis.TotalFiles)" -Source 'Show-AitherDashboard'
                Write-AitherLog -Level Information -Message "Code Files: $($report.Coverage.TotalFiles)" -Source 'Show-AitherDashboard'
                Write-AitherLog -Level Information -Message "Functions: $($report.Coverage.FunctionCount)" -Source 'Show-AitherDashboard'
                Write-AitherLog -Level Information -Message "Lines of Code: $($report.Coverage.CodeLines)" -Source 'Show-AitherDashboard'

                $commentLevel = if ($report.Coverage.CommentRatio -ge 20) { "Information" } elseif ($report.Coverage.CommentRatio -ge 10) { "Warning" } else { "Error" }
                Write-AitherLog -Level $commentLevel -Message "Comment Ratio: $($report.Coverage.CommentRatio)%" -Source 'Show-AitherDashboard'

                $docLevel = if ($report.Documentation.HelpCoverage -ge 80) { "Information" } elseif ($report.Documentation.HelpCoverage -ge 50) { "Warning" } else { "Error" }
                Write-AitherLog -Level $docLevel -Message "Documentation: $($report.Documentation.HelpCoverage)%" -Source 'Show-AitherDashboard'
            } else {
                Write-AitherLog -Level Error -Message "No project report found. Run 0510_Generate-ProjectReport.ps1" -Source 'Show-AitherDashboard'
            }
        }

        function Show-TestResults {
            Write-AitherLog -Level Information -Message "TEST RESULTS" -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message ("-" * 40) -Source 'Show-AitherDashboard'

            $testResultsPath = Join-Path $ProjectPath "AitherZero/library/tests/results"
            if (-not (Test-Path $testResultsPath)) {
                Write-AitherLog -Level Warning -Message "Test results directory not found" -Source 'Show-AitherDashboard'
                return
            }

            $testSummaries = Get-ChildItem -Path $testResultsPath -Filter "*Summary*.json" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5

            if ($testSummaries) {
                foreach ($summary in $testSummaries) {
                    try {
                        $json = Get-Content $summary.FullName | ConvertFrom-Json
                        $passed = $json.PassedCount
                        $failed = $json.FailedCount

                        $testLevel = if ($failed -gt 0) { 'Error' } else { 'Information' }
                        $testMsg = if ($failed -gt 0) { "$($summary.BaseName): $passed passed, $failed failed" } else { "$($summary.BaseName): $passed passed" }
                        Write-AitherLog -Level $testLevel -Message $testMsg -Source 'Show-AitherDashboard'
                    }
                    catch {
                        Write-AitherLog -Level Error -Message "Error reading $($summary.Name)" -Source 'Show-AitherDashboard' -Exception $_
                    }
                }
            } else {
                Write-AitherLog -Level Warning -Message "No test results found" -Source 'Show-AitherDashboard'
            }
        }

        function Show-RecentLogs {
            param([int]$Lines = 20)

            Write-AitherLog -Level Information -Message "RECENT LOGS" -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message ("-" * 40) -Source 'Show-AitherDashboard'

            $logPath = $null
            $searchPaths = @(
                (Join-Path $ProjectPath "AitherZero/library/logs"),
                (Join-Path $ProjectPath "logs")
            )

            foreach ($path in $searchPaths) {
                if (Test-Path $path) {
                    $latestLog = Get-ChildItem -Path $path -Filter "aitherzero*.log" -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 1

                    if ($latestLog) {
                        $logPath = $latestLog.FullName
                        break
                    }
                }
            }

            if ($logPath) {
                $logs = Get-Content $logPath -Tail $Lines -ErrorAction SilentlyContinue
                foreach ($log in $logs) {
                    # Try to parse structured log: [Timestamp] [Level] [Source] Message
                    if ($log -match '^\[(.*?)\] \[(.*?)\] \[(.*?)\] (.*)$') {
                        $timestamp = $matches[1]
                        $level = $matches[2]
                        $source = $matches[3]
                        $message = $matches[4]

                        $logLevel = switch ($level) {
                            'Error' { 'Error' }
                            'Warning' { 'Warning' }
                            'Debug' { 'Debug' }
                            'Success' { 'Information' }
                            default { 'Information' }
                        }

                        Write-AitherLog -Level $logLevel -Message "[$timestamp] [$level] [$source] $message" -Source 'Show-AitherDashboard'
                    } else {
                        # Non-structured log (stack trace, raw output)
                        Write-AitherLog -Level Debug -Message $log -Source 'Show-AitherDashboard'
                    }
                }
            } else {
                Write-AitherLog -Level Warning -Message "No log file found." -Source 'Show-AitherDashboard'
            }
        }

        function Show-ModuleStatus {
            Write-AitherLog -Level Information -Message "MODULE STATUS" -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message ("-" * 40) -Source 'Show-AitherDashboard'

            $domains = Get-ChildItem -Path (Join-Path $ProjectPath "AitherZero/src/public") -Directory -ErrorAction SilentlyContinue

            if (-not $domains) {
                Write-AitherLog -Level Error -Message "No domains found at $(Join-Path $ProjectPath "AitherZero/src/public")" -Source 'Show-AitherDashboard'
            }

            foreach ($domain in $domains) {
                $modules = Get-ChildItem -Path $domain.FullName -Filter "*.ps1" -ErrorAction SilentlyContinue
                Write-AitherLog -Level Information -Message "$($domain.Name): $(@($modules).Count) functions" -Source 'Show-AitherDashboard'
            }
        }

        function Show-RecentActivity {
            Write-AitherLog -Level Information -Message "RECENT ACTIVITY" -Source 'Show-AitherDashboard'
            Write-AitherLog -Level Information -Message ("-" * 40) -Source 'Show-AitherDashboard'

            # Get recent git commits
            if (Get-Command git -ErrorAction SilentlyContinue) {
                $gitLog = git log --oneline -5 2>$null
                if ($gitLog) {
                    Write-AitherLog -Level Information -Message "Recent Commits:" -Source 'Show-AitherDashboard'
                    $gitLog | ForEach-Object { Write-AitherLog -Level Information -Message "  $_" -Source 'Show-AitherDashboard' }
                }
            }

            # Get recently modified files
            Write-AitherLog -Level Information -Message "Recently Modified:" -Source 'Show-AitherDashboard'
            $recentFiles = Get-ChildItem -Path $ProjectPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-24) -and $_.FullName -notlike "*\.git\*" } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 5

            foreach ($file in $recentFiles) {
                $relativePath = $file.FullName.Replace($ProjectPath, '').TrimStart('\', '/')
                $timeAgo = [math]::Round(((Get-Date) - $file.LastWriteTime).TotalMinutes)
                Write-AitherLog -Level Information -Message "  $relativePath ($timeAgo min ago)" -Source 'Show-AitherDashboard'
            }
        }

        # Main Dashboard Display
        Show-Header

        if ($ShowAll -or (!$ShowLogs -and !$ShowTests -and !$ShowMetrics)) {
            # Show everything by default
            $ShowMetrics = $true
            $ShowTests = $true
            $ShowLogs = $true
        }

        if ($ShowMetrics) {
            Show-ProjectMetrics
            Show-ModuleStatus
        }

        if ($ShowTests) {
            Show-TestResults
        }

        if ($ShowLogs) {
            Show-RecentLogs -Lines $LogTailLines
        }

        Show-RecentActivity

        # Footer
        $width = 80
        if ($Host.UI.RawUI -and $Host.UI.RawUI.WindowSize) {
            try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
        }
        Write-AitherLog -Level Information -Message ("=" * $width) -Source 'Show-AitherDashboard'
        Write-AitherLog -Level Information -Message "Commands: 0510 (Generate Report) | 0402 (Run Tests) | 0404 (Analyze Code)" -Source 'Show-AitherDashboard'

        if ($Follow) {
            Write-AitherLog -Level Information -Message "Following logs... Press Ctrl+C to exit" -Source 'Show-AitherDashboard'
            $logPath = Join-Path $ProjectPath "logs/aitherzero.log"
            if (Test-Path $logPath) {
                Get-Content $logPath -Wait -Tail 1 | ForEach-Object { Write-AitherLog -Level Information -Message $_ -Source 'Show-AitherDashboard' }
            }
        }
    }
}

