<#
.SYNOPSIS
    AitherRelay workspace management from AitherShell.

.DESCRIPTION
    Create, manage, and interact with private workspaces on irc.aitherium.com.
    Supports workspace creation, invite generation, member management, and
    sending messages from the command line.

.PARAMETER Action
    Operation to perform: create, list, invite, join, members, send, channels, stats

.PARAMETER WorkspaceSlug
    Workspace identifier (for actions that target a specific workspace)

.PARAMETER Name
    Workspace display name (for 'create' action)

.PARAMETER Description
    Workspace description (for 'create' action)

.PARAMETER Message
    Message content (for 'send' action)

.PARAMETER Channel
    Channel name (for 'send' action, defaults to workspace-general)

.PARAMETER Nick
    Target nick (for member management)

.PARAMETER MaxUses
    Maximum invite uses (for 'invite' action, 0 = unlimited)

.PARAMETER ExpiresHours
    Hours until invite expires (for 'invite' action, 0 = never)

.PARAMETER InviteCode
    Invite code (for 'join' action)

.EXAMPLE
    .\7020_Relay-Workspace.ps1 -Action create -WorkspaceSlug "aitherium" -Name "Aitherium Team" -Description "Private team comms"
    .\7020_Relay-Workspace.ps1 -Action list
    .\7020_Relay-Workspace.ps1 -Action invite -WorkspaceSlug "aitherium" -MaxUses 10 -ExpiresHours 48
    .\7020_Relay-Workspace.ps1 -Action join -InviteCode "abc123"
    .\7020_Relay-Workspace.ps1 -Action members -WorkspaceSlug "aitherium"
    .\7020_Relay-Workspace.ps1 -Action send -WorkspaceSlug "aitherium" -Channel "general" -Message "Hello team!"
    .\7020_Relay-Workspace.ps1 -Action channels -WorkspaceSlug "aitherium"
    .\7020_Relay-Workspace.ps1 -Action stats
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("create", "list", "invite", "join", "members", "send", "channels", "stats")]
    [string]$Action,

    [string]$WorkspaceSlug = "",
    [string]$Name = "",
    [string]$Description = "",
    [string]$Message = "",
    [string]$Channel = "",
    [string]$Nick = "",
    [int]$MaxUses = 0,
    [int]$ExpiresHours = 0,
    [string]$InviteCode = ""
)

# ── Resolve relay URL ───────────────────────────────────────────────────
$relayUrl = $env:AITHERRELAY_URL
if (-not $relayUrl) {
    $relayUrl = "http://localhost:8205"
}

# ── Auth token ──────────────────────────────────────────────────────────
$authToken = $env:AITHER_AUTH_TOKEN
if (-not $authToken) {
    $authToken = $env:AITHER_SYSTEM_TOKEN
}

$headers = @{
    "Content-Type" = "application/json"
}
if ($authToken) {
    $headers["Authorization"] = "Bearer $authToken"
}

function Invoke-RelayApi {
    param(
        [string]$Method = "GET",
        [string]$Path,
        [hashtable]$Body = @{}
    )
    $uri = "$relayUrl$Path"
    try {
        $params = @{
            Uri = $uri
            Method = $Method
            Headers = $headers
            ContentType = "application/json"
            TimeoutSec = 10
        }
        if ($Method -in @("POST", "PUT") -and $Body.Count -gt 0) {
            $params["Body"] = ($Body | ConvertTo-Json -Compress)
        }
        $resp = Invoke-RestMethod @params
        return $resp
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode) {
            Write-Host "[ERROR] HTTP $statusCode - $($_.ErrorDetails.Message)" -ForegroundColor Red
        } else {
            Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
        return $null
    }
}

# ── Actions ─────────────────────────────────────────────────────────────

switch ($Action) {
    "create" {
        if (-not $WorkspaceSlug -or -not $Name) {
            Write-Host "[ERROR] -WorkspaceSlug and -Name required for create" -ForegroundColor Red
            exit 1
        }
        $body = @{
            name = $Name
            slug = $WorkspaceSlug.ToLower()
            description = $Description
        }
        $result = Invoke-RelayApi -Method POST -Path "/v1/workspaces" -Body $body
        if ($result) {
            Write-Host "[OK] Workspace '$Name' created (slug: $WorkspaceSlug)" -ForegroundColor Green
            Write-Host "  Default channels: $($result.workspace.channels -join ', ')"
        }
    }

    "list" {
        $result = Invoke-RelayApi -Path "/v1/workspaces"
        if ($result -and $result.workspaces) {
            Write-Host "`nYour Workspaces:" -ForegroundColor Cyan
            foreach ($ws in $result.workspaces) {
                $icon = if ($ws.icon) { $ws.icon } else { "  " }
                $role = $ws.role.ToUpper()
                Write-Host "  $icon $($ws.name) ($($ws.slug)) [$role] - $($ws.member_count) members, $($ws.channel_count) channels"
            }
            if ($result.workspaces.Count -eq 0) {
                Write-Host "  (none)" -ForegroundColor DarkGray
            }
        }
    }

    "invite" {
        if (-not $WorkspaceSlug) {
            Write-Host "[ERROR] -WorkspaceSlug required for invite" -ForegroundColor Red
            exit 1
        }
        $body = @{}
        if ($MaxUses -gt 0) { $body["max_uses"] = $MaxUses }
        if ($ExpiresHours -gt 0) { $body["expires_hours"] = $ExpiresHours }

        $result = Invoke-RelayApi -Method POST -Path "/v1/workspaces/$WorkspaceSlug/invites" -Body $body
        if ($result -and $result.invite_url) {
            Write-Host "`n[OK] Invite created!" -ForegroundColor Green
            Write-Host "  URL: $($result.invite_url)" -ForegroundColor Cyan
            Write-Host "  Code: $($result.invite_code)"
            if ($result.max_uses) { Write-Host "  Max uses: $($result.max_uses)" }
            if ($result.expires_at) { Write-Host "  Expires: $($result.expires_at)" }

            # Copy to clipboard
            try {
                $result.invite_url | Set-Clipboard
                Write-Host "  (copied to clipboard)" -ForegroundColor DarkGray
            } catch { }
        }
    }

    "join" {
        if (-not $InviteCode) {
            Write-Host "[ERROR] -InviteCode required for join" -ForegroundColor Red
            exit 1
        }
        $body = @{ invite_code = $InviteCode }
        $result = Invoke-RelayApi -Method POST -Path "/v1/workspaces/join" -Body $body
        if ($result -and $result.success) {
            Write-Host "[OK] Joined workspace '$($result.workspace.name)'!" -ForegroundColor Green
            if ($result.channels_joined) {
                Write-Host "  Auto-joined channels: $($result.channels_joined -join ', ')"
            }
        }
    }

    "members" {
        if (-not $WorkspaceSlug) {
            Write-Host "[ERROR] -WorkspaceSlug required for members" -ForegroundColor Red
            exit 1
        }
        $result = Invoke-RelayApi -Path "/v1/workspaces/$WorkspaceSlug/members"
        if ($result -and $result.members) {
            Write-Host "`nMembers of $WorkspaceSlug ($($result.count)):" -ForegroundColor Cyan
            foreach ($m in $result.members) {
                $status = if ($m.online) { "[ONLINE]" } else { "[offline]" }
                $roleColor = switch ($m.role) {
                    "owner" { "Yellow" }
                    "admin" { "Magenta" }
                    default { "White" }
                }
                Write-Host "  $status " -NoNewline
                Write-Host "$($m.nick)" -ForegroundColor $roleColor -NoNewline
                Write-Host " ($($m.role))"
            }
        }
    }

    "send" {
        if (-not $WorkspaceSlug -or -not $Message) {
            Write-Host "[ERROR] -WorkspaceSlug and -Message required for send" -ForegroundColor Red
            exit 1
        }
        $ch = if ($Channel) { "#$WorkspaceSlug-$Channel" } else { "#$WorkspaceSlug-general" }
        $nick = if ($env:AITHER_NICK) { $env:AITHER_NICK } else { $env:USERNAME }
        $body = @{ nick = $nick; content = $Message }
        $result = Invoke-RelayApi -Method POST -Path "/v1/channels/$($ch.TrimStart('#'))/messages" -Body $body
        if ($result -and $result.success) {
            Write-Host "[OK] Message sent to $ch" -ForegroundColor Green
        }
    }

    "channels" {
        if (-not $WorkspaceSlug) {
            Write-Host "[ERROR] -WorkspaceSlug required for channels" -ForegroundColor Red
            exit 1
        }
        $result = Invoke-RelayApi -Path "/v1/workspaces/$WorkspaceSlug/channels"
        if ($result -and $result.channels) {
            Write-Host "`nChannels in $WorkspaceSlug:" -ForegroundColor Cyan
            foreach ($ch in $result.channels) {
                $lock = if ($ch.mode -eq "private") { "🔒" } else { "#" }
                Write-Host "  $lock $($ch.name) - $($ch.users_online) online, $($ch.message_count) msgs"
                if ($ch.topic) { Write-Host "    Topic: $($ch.topic)" -ForegroundColor DarkGray }
            }
        }
    }

    "stats" {
        $result = Invoke-RelayApi -Path "/v1/stats"
        if ($result) {
            Write-Host "`nAitherRelay Stats:" -ForegroundColor Cyan
            Write-Host "  Channels:   $($result.channels)"
            Write-Host "  Users:      $($result.users_online) online"
            Write-Host "  Groups:     $($result.groups)"
            Write-Host "  Accounts:   $($result.accounts)"
            if ($result.workspaces) {
                Write-Host "  Workspaces: $($result.workspaces)"
            }
        }
    }
}
