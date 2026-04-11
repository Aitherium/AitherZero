<#
.SYNOPSIS
    AitherOS Desktop Notification Daemon

.DESCRIPTION
    Connects to Genesis /ws/notifications WebSocket and shows native Windows
    desktop toast notifications (BurntToast) for every inbox message.

    Clicking a notification opens the message in AitherVeil dashboard.

    This is the missing bridge between Docker-containerised services and
    the Windows desktop. It runs natively on the host, not inside Docker.

    Features:
    - Persistent WebSocket connection with auto-reconnect
    - BurntToast rich notifications with action buttons
    - Click-to-open in AitherVeil (inbox deep-link)
    - Priority-based sound and duration
    - Anti-spam dedup (same title within 60s is suppressed)
    - Falls back to .NET balloon if BurntToast unavailable

.PARAMETER GenesisUrl
    Genesis WebSocket URL. Default: ws://localhost:8001

.PARAMETER VeilUrl
    AitherVeil dashboard URL. Default: http://localhost:3000

.PARAMETER ReconnectDelay
    Seconds to wait before reconnecting after disconnect. Default: 5

.PARAMETER Quiet
    Suppress console output (run silently in background)

.EXAMPLE
    # Start the daemon (foreground)
    pwsh -File 4010_Start-NotificationDaemon.ps1

    # Start in background
    Start-Process pwsh -ArgumentList "-NoProfile -File 4010_Start-NotificationDaemon.ps1 -Quiet" -WindowStyle Hidden

.NOTES
    Author: AitherZero
    Category: lifecycle
    Requires: Windows 10/11, PowerShell 7+
    Optional: BurntToast module (Install-Module BurntToast)
#>

[CmdletBinding()]
param(
    [string]$GenesisUrl = "ws://localhost:8001",
    [string]$VeilUrl = "http://localhost:3000",
    [int]$ReconnectDelay = 5,
    [switch]$Quiet
)

# ============================================================================
# INIT
# ============================================================================

$ErrorActionPreference = 'Continue'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    if (-not $Quiet) {
        $ts = Get-Date -Format "HH:mm:ss"
        $colour = switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "OK"    { "Green" }
            default { "Cyan" }
        }
        Write-Host "[$ts] " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$Level] " -NoNewline -ForegroundColor $colour
        Write-Host $Message
    }
}

# ============================================================================
# BURNTTOAST SETUP
# ============================================================================

$UseBurntToast = $false
if (Get-Module -ListAvailable -Name BurntToast) {
    try {
        Import-Module BurntToast -ErrorAction Stop
        $UseBurntToast = $true
        Write-Log "BurntToast loaded — rich notifications enabled" "OK"
    }
    catch {
        Write-Log "BurntToast import failed: $_ — using .NET fallback" "WARN"
    }
}
else {
    Write-Log "BurntToast not installed — using .NET fallback" "WARN"
    Write-Log "Install with: Install-Module BurntToast -Force" "INFO"
}

# Dedup tracking: title -> last-shown timestamp
$script:RecentNotifications = @{}
$DedupWindowSeconds = 60

# ============================================================================
# NOTIFICATION FUNCTIONS
# ============================================================================

function Get-PrioritySound {
    param([string]$Priority)
    switch ($Priority) {
        "critical" { return "Alarm" }
        "high"     { return "Reminder" }
        "normal"   { return "Mail" }
        "low"      { return "IM" }
        default    { return "Default" }
    }
}

function Get-PriorityIcon {
    param([string]$Priority)
    switch ($Priority) {
        "critical" { return [char]0x1F6A8 }  # 🚨
        "high"     { return [char]0x1F534 }  # 🔴
        "normal"   { return [char]0x1F535 }  # 🔵
        "low"      { return [char]0x2139  }  # ℹ
        default    { return [char]0x1F514 }  # 🔔
    }
}

function Test-IsDuplicate {
    param([string]$Key)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($script:RecentNotifications.ContainsKey($Key)) {
        $lastSeen = $script:RecentNotifications[$Key]
        if (($now - $lastSeen) -lt $DedupWindowSeconds) {
            return $true
        }
    }
    $script:RecentNotifications[$Key] = $now
    # Cleanup old entries
    $stale = @()
    foreach ($k in $script:RecentNotifications.Keys) {
        if (($now - $script:RecentNotifications[$k]) -gt 300) { $stale += $k }
    }
    foreach ($k in $stale) { $script:RecentNotifications.Remove($k) }
    return $false
}

function Show-DesktopNotification {
    param(
        [string]$Title,
        [string]$Body,
        [string]$Priority = "normal",
        [string]$Category = "system",
        [string]$ActionUrl = "",
        [string]$MailId = "",
        [string]$ServiceName = ""
    )

    # Dedup check
    $dedupKey = "$Title|$($Body.Substring(0, [Math]::Min(50, $Body.Length)))"
    if (Test-IsDuplicate -Key $dedupKey) {
        Write-Log "Suppressed duplicate: $Title" "INFO"
        return
    }

    # Build action URL — default to Veil inbox
    if (-not $ActionUrl) {
        if ($MailId) {
            $ActionUrl = "$VeilUrl/dashboard?widget=mail&mail=$MailId"
        }
        else {
            $ActionUrl = "$VeilUrl/dashboard?widget=mail"
        }
    }

    $icon = Get-PriorityIcon $Priority

    if ($UseBurntToast) {
        try {
            $btParams = @{
                Text = @("$icon AitherOS — $Title", $Body.Substring(0, [Math]::Min(200, $Body.Length)))
            }

            # Action buttons
            $buttons = @()
            $buttons += New-BTButton -Content "Open in Veil" -Arguments $ActionUrl
            if ($ServiceName) {
                $restartUrl = "aither://restart/$($ServiceName.ToLower())"
                $buttons += New-BTButton -Content "Restart $ServiceName" -Arguments $restartUrl
            }
            $buttons += New-BTButton -Content "Dashboard" -Arguments "$VeilUrl/dashboard"
            $btParams['Button'] = $buttons

            # Sound based on priority
            $soundName = Get-PrioritySound $Priority
            if ($soundName -eq "Alarm") {
                $btParams['Sound'] = New-BTAudio -Source "ms-winsoundevent:Notification.Looping.Alarm" -Loop:$false
            }
            elseif ($soundName -eq "Reminder") {
                $btParams['Sound'] = New-BTAudio -Source "ms-winsoundevent:Notification.Reminder"
            }
            elseif ($soundName -eq "Mail") {
                $btParams['Sound'] = New-BTAudio -Source "ms-winsoundevent:Notification.Mail"
            }

            # Critical stays longer
            if ($Priority -in @("critical", "high")) {
                $btParams['ExpirationTime'] = [DateTime]::Now.AddHours(2)
            }

            New-BurntToastNotification @btParams
            Write-Log "Toast sent: $Title (priority=$Priority)" "OK"
        }
        catch {
            Write-Log "BurntToast failed: $_ — trying .NET fallback" "WARN"
            Show-DotNetNotification -Title $Title -Body $Body -ActionUrl $ActionUrl -Priority $Priority
        }
    }
    else {
        Show-DotNetNotification -Title $Title -Body $Body -ActionUrl $ActionUrl -Priority $Priority
    }
}

function Show-DotNetNotification {
    param(
        [string]$Title,
        [string]$Body,
        [string]$ActionUrl,
        [string]$Priority = "normal"
    )
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon((Get-Process -Id $PID).Path)
        $notify.Visible = $true

        $tipIcon = switch ($Priority) {
            "critical" { [System.Windows.Forms.ToolTipIcon]::Error }
            "high"     { [System.Windows.Forms.ToolTipIcon]::Warning }
            default    { [System.Windows.Forms.ToolTipIcon]::Info }
        }

        $notify.BalloonTipIcon = $tipIcon
        $notify.BalloonTipTitle = "AitherOS — $Title"
        $notify.BalloonTipText = $Body.Substring(0, [Math]::Min(200, $Body.Length))

        # Click opens in browser
        if ($ActionUrl) {
            $url = $ActionUrl
            $notify.add_BalloonTipClicked({ Start-Process $url }.GetNewClosure())
        }

        $notify.ShowBalloonTip(10000)

        # Keep alive briefly then clean up
        Start-Sleep -Seconds 5
        $notify.Dispose()
        Write-Log ".NET notification sent: $Title" "OK"
    }
    catch {
        Write-Log ".NET notification failed: $_" "ERROR"
    }
}

# ============================================================================
# WEBSOCKET CLIENT
# ============================================================================

function Start-WebSocketListener {
    $wsUrl = "$GenesisUrl/ws/notifications"
    Write-Log "Connecting to $wsUrl ..." "INFO"

    while ($true) {
        $ws = $null
        try {
            $ws = New-Object System.Net.WebSockets.ClientWebSocket
            $cts = New-Object System.Threading.CancellationTokenSource
            $connectTask = $ws.ConnectAsync([Uri]$wsUrl, $cts.Token)
            $connectTask.Wait(10000)  # 10s connect timeout

            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                throw "WebSocket connection failed (state: $($ws.State))"
            }

            Write-Log "Connected to Genesis WebSocket" "OK"

            # Send initial ping
            $pingBytes = [System.Text.Encoding]::UTF8.GetBytes('{"type":"ping"}')
            $pingSegment = New-Object System.ArraySegment[byte] -ArgumentList @(,$pingBytes)
            $ws.SendAsync($pingSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)

            # Read loop
            $buffer = New-Object byte[] 65536

            while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $segment = New-Object System.ArraySegment[byte] -ArgumentList @(,$buffer)
                $receiveTask = $ws.ReceiveAsync($segment, $cts.Token)

                # Wait with timeout so we can send keepalive pings
                $completed = $receiveTask.Wait(30000)

                if (-not $completed) {
                    # Send keepalive ping
                    try {
                        $ws.SendAsync($pingSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait(5000)
                    }
                    catch {
                        Write-Log "Ping failed, reconnecting..." "WARN"
                        break
                    }
                    continue
                }

                $result = $receiveTask.Result

                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    Write-Log "Server closed connection" "WARN"
                    break
                }

                $messageText = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)

                try {
                    $message = $messageText | ConvertFrom-Json

                    # Handle the notification wrapper: { type: "notification", data: { ... } }
                    $data = if ($message.data) { $message.data } else { $message }

                    # Only process inbox_notification type (from our push endpoint)
                    $notifType = if ($data.type) { $data.type } else { "" }

                    if ($notifType -eq "inbox_notification") {
                        Show-DesktopNotification `
                            -Title ($data.title ?? "AitherOS") `
                            -Body ($data.body ?? "") `
                            -Priority ($data.priority ?? "normal") `
                            -Category ($data.category ?? "system") `
                            -ActionUrl ($data.action_url ?? "") `
                            -MailId ($data.mail_id ?? "") `
                            -ServiceName ($data.service_name ?? "")
                    }
                    elseif ($notifType -eq "assistant_alert" -or $notifType -eq "alarm") {
                        # Also show direct alerts from Genesis
                        Show-DesktopNotification `
                            -Title ($data.title ?? $data.message ?? "Alert") `
                            -Body ($data.body ?? $data.message ?? "") `
                            -Priority ($data.priority ?? "high") `
                            -Category "alert"
                    }
                    elseif ($notifType -eq "pong") {
                        # Ignore pong responses
                    }
                    else {
                        Write-Log "Received event: $notifType" "INFO"
                    }
                }
                catch {
                    Write-Log "Failed to parse message: $_" "WARN"
                }
            }
        }
        catch {
            Write-Log "WebSocket error: $_" "ERROR"
        }
        finally {
            if ($ws -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Reconnecting", [System.Threading.CancellationToken]::None).Wait(5000) } catch {}
            }
            if ($ws) { $ws.Dispose() }
        }

        Write-Log "Reconnecting in ${ReconnectDelay}s..." "WARN"
        Start-Sleep -Seconds $ReconnectDelay
    }
}

# ============================================================================
# MAIN
# ============================================================================

Write-Log "=== AitherOS Desktop Notification Daemon ===" "OK"
Write-Log "Genesis:    $GenesisUrl" "INFO"
Write-Log "Veil:       $VeilUrl" "INFO"
Write-Log "BurntToast: $(if ($UseBurntToast) { 'YES' } else { 'NO (.NET fallback)' })" "INFO"
Write-Log "" "INFO"

# Check Genesis is reachable first
try {
    $health = Invoke-RestMethod -Uri "$($GenesisUrl.Replace('ws://', 'http://').Replace('wss://', 'https://'))/health" -TimeoutSec 5 -ErrorAction Stop
    Write-Log "Genesis is $($health.status) (health: $($health.health))" "OK"
}
catch {
    Write-Log "Genesis not reachable at $GenesisUrl — will retry..." "WARN"
}

# Start the listener (blocks forever, auto-reconnects)
Start-WebSocketListener
