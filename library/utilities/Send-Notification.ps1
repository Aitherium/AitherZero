<#
.SYNOPSIS
    Sends a Windows Toast Notification.

.DESCRIPTION
    Uses PowerShell to display a toast notification. 
    Attempts to use BurntToast module if available, otherwise uses .NET classes.

.PARAMETER Title
    The title of the notification.

.PARAMETER Message
    The message body of the notification.

.EXAMPLE
    Send-Notification -Title "Reminder" -Message "Meeting at 12:00"
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Title,

    [Parameter(Mandatory=$true)]
    [string]$Message
)

# Try BurntToast first
if (Get-Module -ListAvailable -Name BurntToast) {
    try {
        New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
        return
    } catch {
        Write-Warning "BurntToast failed: $_"
    }
}

# Fallback to .NET System.Drawing / Windows.Forms (Balloon Tip)
# Note: Toast is harder without BurntToast or Windows Runtime API in pure PS without external deps.
# Using a simple BalloonTip as fallback.

Add-Type -AssemblyName System.Windows.Forms
$icon = New-Object System.Windows.Forms.NotifyIcon
$icon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
$icon.BalloonTipIcon = "Info"
$icon.BalloonTipTitle = $Title
$icon.BalloonTipText = $Message
$icon.Visible = $true
$icon.ShowBalloonTip(10000)

# Keep script running briefly to show the tip
Start-Sleep -Seconds 2
$icon.Dispose()


