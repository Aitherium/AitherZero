@{
    # ===================================================================
    # REPORTING - Reports and Analytics
    # ===================================================================
    Reporting                = @{
        # Report generation
        AutoGenerateReports  = $true
        DefaultFormat        = 'HTML'
        ReportPath           = './library/reports'
        ExportFormats        = @('HTML', 'JSON', 'CSV', 'PDF', 'Markdown')
        CompressReports      = $false
        IncludeSystemInfo    = $true
        IncludeExecutionLogs = $true
        IncludeScreenshots   = $false
        MetricsCollection    = $true
        MetricsRetentionDays = 90
        TemplateEngine       = 'Default'

        # Dashboard
        DashboardEnabled     = $true
        DashboardPort        = 8080
        DashboardAutoOpen    = $false
        ClearScreenOnStart   = $false

        # Tech debt tracking
        TechDebtReporting    = @{
            Enabled    = $true
            AutoTrack  = $true
            Schedule   = 'Weekly'
            Thresholds = @{
                CodeQuality   = 70
                Documentation = 80
                Security      = 90
                ConfigUsage   = 80
            }
        }
    }

    # ===================================================================
    # LOGGING - Logging and Audit Configuration
    # ===================================================================
    Logging                  = @{
        # General logging
        Level         = 'Information'
        Path          = './library/logs'
        File          = 'library/logs/aitherzero.log'
        Console       = $true
        MaxFileSize   = '10MB'
        RetentionDays = 30
        Targets       = @('Console', 'File')

        # Audit logging
        AuditLogging  = @{
            Enabled              = $true
            Level                = 'All'
            ComplianceMode       = $true
            IncludeUserInfo      = $true
            IncludeSystemInfo    = $true
            IncludeCorrelationId = $true
            RetentionDays        = 90
        }
    }

    # ===================================================================
    # ERROR REPORTING - Error Collection and Debugging Configuration
    # ===================================================================
    ErrorReporting              = @{
        # Error log storage
        ErrorLogPath            = './library/logs/error-reports'

        # Error collection settings
        CollectStackTraces     = $true
        CollectEnvironmentInfo  = $true
        CollectParameters       = $true

        # Error retention
        RetentionDays          = 30
        MaxErrorLogSize         = 100MB

        # Error reporting formats
        SupportedFormats       = @('JSON', 'HTML', 'Text')
        DefaultFormat          = 'JSON'

        # Error notification (future)
        NotifyOnCritical        = $false
        NotificationChannels    = @()
    }
}
