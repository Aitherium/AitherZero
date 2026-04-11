<#
.SYNOPSIS
    Enhanced Windows Toast Notifications with Action Buttons

.DESCRIPTION
    Sends rich Windows Toast notifications with:
    - Actionable buttons
    - Protocol handlers (aither://)
    - Custom icons and sounds
    - Priority/severity levels
    - Action Center persistence
    
    Uses BurntToast if available, falls back to .NET if not.

.PARAMETER Title
    The notification title

.PARAMETER Message
    The notification body text

.PARAMETER Severity
    Notification severity: Info, Warning, Error, Critical

.PARAMETER Actions
    Array of action buttons. Each is a hashtable with 'Label' and 'Action' keys.
    Action can be a URL, aither:// protocol, or PowerShell command.

.PARAMETER Sound
    Custom sound: Default, IM, Mail, Reminder, Alarm, Call, or None

.PARAMETER Silent
    Suppress the notification sound

.PARAMETER Persistent
    Keep notification in Action Center until dismissed

.EXAMPLE
    Send-AitherNotification -Title "Service Down" -Message "Moltbook is offline" -Severity Error -Actions @(
        @{ Label = "Restart"; Action = "aither://restart/moltbook" }
        @{ Label = "Dashboard"; Action = "http://localhost:3000" }
    )

.EXAMPLE
    Send-AitherNotification -Title "Task Complete" -Message "Training finished!" -Severity Info

.NOTES
    Author: AitherOS
    Requires: Windows 10/11
    Optional: BurntToast module for enhanced features
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter()]
    [ValidateSet('Info', 'Warning', 'Error', 'Critical')]
    [string]$Severity = 'Info',

    [Parameter()]
    [hashtable[]]$Actions,

    [Parameter()]
    [ValidateSet('Default', 'IM', 'Mail', 'Reminder', 'Alarm', 'Call', 'None')]
    [string]$Sound = 'Default',

    [Parameter()]
    [switch]$Silent,

    [Parameter()]
    [switch]$Persistent,

    [Parameter()]
    [string]$Icon
)

# ============================================================================
# PROTOCOL HANDLER REGISTRATION
# ============================================================================
# Ensure aither:// protocol is registered (runs once, idempotent)

function Register-AitherProtocol {
    $protocolKey = "HKCU:\Software\Classes\aither"
    if (-not (Test-Path $protocolKey)) {
        try {
            # Get the CLI handler path
            $handlerPath = Join-Path $PSScriptRoot "Invoke-AitherProtocol.ps1"
            if (-not (Test-Path $handlerPath)) {
                # Create the handler if it doesn't exist
                $handlerContent = @'
# Aither Protocol Handler
# Called when aither://command/args is invoked
param([string]$Uri)

$Uri -match 'aither://(?<cmd>[^/]+)/(?<args>.*)' | Out-Null
$command = $Matches.cmd
$arguments = $Matches.args

switch ($command) {
    'restart' { 
        $service = $arguments
        Write-Host "Restarting service: $service"
        docker restart "aither-$service"
    }
    'open' {
        $target = $arguments
        Start-Process "http://localhost:3000/$target"
    }
    'run' {
        # Run a named routine
        Invoke-RestMethod -Uri "http://localhost:8109/routines/$arguments/trigger" -Method POST
    }
    default {
        Write-Warning "Unknown aither:// command: $command"
    }
}
'@
                Set-Content -Path $handlerPath -Value $handlerContent -Force
            }

            # Register the protocol
            New-Item -Path $protocolKey -Force | Out-Null
            Set-ItemProperty -Path $protocolKey -Name "(Default)" -Value "URL:Aither Protocol"
            Set-ItemProperty -Path $protocolKey -Name "URL Protocol" -Value ""
            
            New-Item -Path "$protocolKey\shell\open\command" -Force | Out-Null
            $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source ?? "powershell.exe"
            Set-ItemProperty -Path "$protocolKey\shell\open\command" -Name "(Default)" -Value "`"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$handlerPath`" `"%1`""
            
            Write-Verbose "Registered aither:// protocol handler"
        }
        catch {
            Write-Warning "Could not register aither:// protocol: $_"
        }
    }
}

# ============================================================================
# NOTIFICATION IMPLEMENTATION
# ============================================================================

function Get-SeverityIcon {
    param([string]$Severity)
    switch ($Severity) {
        'Info' { return '🔵' }
        'Warning' { return '🟡' }
        'Error' { return '🔴' }
        'Critical' { return '🚨' }
        default { return 'ℹ️' }
    }
}

function Get-BurntToastSound {
    param([string]$Sound)
    switch ($Sound) {
        'IM' { return 'ms-winsoundevent:Notification.IM' }
        'Mail' { return 'ms-winsoundevent:Notification.Mail' }
        'Reminder' { return 'ms-winsoundevent:Notification.Reminder' }
        'Alarm' { return 'ms-winsoundevent:Notification.Looping.Alarm' }
        'Call' { return 'ms-winsoundevent:Notification.Looping.Call' }
        'None' { return $null }
        default { return 'ms-winsoundevent:Notification.Default' }
    }
}

# Register protocol handler
Register-AitherProtocol

# Try BurntToast first (rich features)
$useBurntToast = $false
if (Get-Module -ListAvailable -Name BurntToast) {
    try {
        Import-Module BurntToast -ErrorAction Stop
        $useBurntToast = $true
    }
    catch {
        Write-Verbose "BurntToast import failed: $_"
    }
}

if ($useBurntToast) {
    # ========================================================================
    # BURNT TOAST IMPLEMENTATION (RICH)
    # ========================================================================
    
    $toastParams = @{
        Text = @("$(Get-SeverityIcon $Severity) $Title", $Message)
    }
    
    # Add action buttons
    if ($Actions -and $Actions.Count -gt 0) {
        $buttons = @()
        foreach ($action in $Actions) {
            $btn = New-BTButton -Content $action.Label -Arguments $action.Action
            $buttons += $btn
        }
        $toastParams['Button'] = $buttons
    }
    
    # Add sound
    if ($Silent) {
        $toastParams['Silent'] = $true
    }
    elseif ($Sound -ne 'Default') {
        $soundUri = Get-BurntToastSound $Sound
        if ($soundUri) {
            $toastParams['Sound'] = New-BTAudio -Source $soundUri
        }
    }
    
    # Add icon if specified
    if ($Icon -and (Test-Path $Icon)) {
        $toastParams['AppLogo'] = $Icon
    }
    
    # Set expiration for critical
    if ($Severity -eq 'Critical' -or $Persistent) {
        $toastParams['ExpirationTime'] = [DateTime]::Now.AddDays(1)
    }
    
    try {
        New-BurntToastNotification @toastParams
        Write-Verbose "Sent BurntToast notification: $Title"
    }
    catch {
        Write-Warning "BurntToast failed: $_, falling back to basic notification"
        $useBurntToast = $false
    }
}

if (-not $useBurntToast) {
    # ========================================================================
    # .NET FALLBACK (BASIC)
    # ========================================================================
    
    Add-Type -AssemblyName System.Windows.Forms
    
    # Create NotifyIcon
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
    $notifyIcon.Visible = $true
    
    # Map severity to icon
    $tipIcon = switch ($Severity) {
        'Info' { [System.Windows.Forms.ToolTipIcon]::Info }
        'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
        'Error' { [System.Windows.Forms.ToolTipIcon]::Error }
        'Critical' { [System.Windows.Forms.ToolTipIcon]::Error }
        default { [System.Windows.Forms.ToolTipIcon]::Info }
    }
    
    $notifyIcon.BalloonTipIcon = $tipIcon
    $notifyIcon.BalloonTipTitle = "$(Get-SeverityIcon $Severity) $Title"
    $notifyIcon.BalloonTipText = $Message
    
    # Add click handler for first action (if any)
    if ($Actions -and $Actions.Count -gt 0) {
        $firstAction = $Actions[0].Action
        $notifyIcon.add_BalloonTipClicked({
            param($sender, $e)
            Start-Process $firstAction
        })
    }
    
    $notifyIcon.ShowBalloonTip(10000)
    
    # Keep icon visible briefly
    Start-Sleep -Seconds 3
    $notifyIcon.Dispose()
    
    Write-Verbose "Sent .NET balloon notification: $Title"
}

# ============================================================================
# OUTPUT
# ============================================================================

[PSCustomObject]@{
    Title = $Title
    Message = $Message
    Severity = $Severity
    Timestamp = Get-Date
    Method = if ($useBurntToast) { 'BurntToast' } else { '.NET' }
    ActionsCount = if ($Actions) { $Actions.Count } else { 0 }
}
