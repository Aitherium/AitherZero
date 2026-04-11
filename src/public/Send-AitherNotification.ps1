function Send-AitherNotification {
    <#
    .SYNOPSIS
        Sends rich Windows toast notifications with AitherOS branding and actions.
    
    .DESCRIPTION
        Leverages BurntToast to send actionable Windows notifications that integrate
        with AitherOS services. Supports:
        - Service status alerts
        - Task completions
        - Agent messages
        - Scheduled reminders
        - Custom actions with deep linking
    
    .PARAMETER Title
        The notification title (first line, bold).
    
    .PARAMETER Message
        The main notification message.
    
    .PARAMETER Type
        Notification type: Info, Success, Warning, Error, Critical, Agent
    
    .PARAMETER Service
        Optional service name for service-related notifications.
    
    .PARAMETER Actions
        Array of hashtables with 'Label' and 'Url' keys for action buttons.
    
    .PARAMETER Silent
        If specified, no sound plays with the notification.
    
    .EXAMPLE
        Send-AitherNotification -Title "Build Complete" -Message "AitherVeil built successfully" -Type Success
    
    .EXAMPLE
        Send-AitherNotification -Title "Moltbook Down" -Message "Service health check failed" -Type Critical -Service "Moltbook" -Actions @(@{Label="Restart"; Url="aither://restart/moltbook"}, @{Label="Logs"; Url="aither://logs/moltbook"})
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Critical', 'Agent')]
        [string]$Type = 'Info',
        
        [Parameter()]
        [string]$Service,
        
        [Parameter()]
        [hashtable[]]$Actions,
        
        [Parameter()]
        [switch]$Silent
    )
    
    # Ensure BurntToast is available
    if (-not (Get-Module -ListAvailable -Name BurntToast)) {
        Write-Warning "BurntToast not installed. Installing..."
        Install-Module -Name BurntToast -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module BurntToast -ErrorAction SilentlyContinue
    
    # Type-based emoji prefixes
    $typeEmoji = switch ($Type) {
        'Info'     { 'ℹ️' }
        'Success'  { '✅' }
        'Warning'  { '⚠️' }
        'Error'    { '❌' }
        'Critical' { '🚨' }
        'Agent'    { '🤖' }
    }
    
    # Build notification text
    $fullTitle = "$typeEmoji $Title"
    $textLines = @($fullTitle, $Message)
    if ($Service) {
        $textLines += "Service: $Service"
    }
    
    # Build action buttons
    $buttons = @()
    if ($Actions) {
        foreach ($action in $Actions) {
            $buttons += New-BTButton -Content $action.Label -Arguments $action.Url
        }
    }
    
    # Auto-generate actionable buttons for service alerts (if no custom actions)
    if ($Service -and $buttons.Count -eq 0) {
        $svcId = ($Service -replace '^Aither', '').ToLower()
        # View Logs button — opens live container logs in Windows Terminal
        $buttons += New-BTButton -Content "📋 View Logs" -Arguments "aither://logs/$svcId"
        # Restart button — for Error/Critical only
        if ($Type -in 'Error', 'Critical') {
            $buttons += New-BTButton -Content "🔄 Restart" -Arguments "aither://service/$svcId/restart"
        }
        # Dashboard log viewer
        $notifyCtx = Get-AitherLiveContext
        $dashUrl = if ($notifyCtx.DashboardURL) { $notifyCtx.DashboardURL } else { "http://localhost:3000" }
        $buttons += New-BTButton -Content "📊 Dashboard" -Arguments "$dashUrl/logs?service=$svcId"
    }

    # Add default dashboard button for critical alerts without service context
    if ($Type -eq 'Critical' -and $buttons.Count -eq 0) {
        if (-not $notifyCtx) { $notifyCtx = Get-AitherLiveContext }
        $dashUrl = if ($notifyCtx.DashboardURL) { $notifyCtx.DashboardURL } else { "http://localhost:3000" }
        $buttons += New-BTButton -Content "📊 Open Dashboard" -Arguments $dashUrl
        $buttons += New-BTButton -Content "Dismiss" -Dismiss
    }
    
    # Sound based on type
    $sound = if ($Silent) { $null } else {
        switch ($Type) {
            'Critical' { 'Alarm' }
            'Error'    { 'Alarm2' }
            'Warning'  { 'Reminder' }
            'Success'  { 'SMS' }
            default    { 'Default' }
        }
    }
    
    # Build notification parameters
    $params = @{
        Text = $textLines
    }
    
    if ($buttons.Count -gt 0) {
        $params.Button = $buttons
    }
    
    if ($sound -and -not $Silent) {
        $params.Sound = $sound
    }
    
    # Send the notification
    try {
        New-BurntToastNotification @params
        Write-Verbose "Notification sent: $Title"
    }
    catch {
        Write-Warning "Failed to send notification: $_"
    }
}

# Export handled by build.ps1
