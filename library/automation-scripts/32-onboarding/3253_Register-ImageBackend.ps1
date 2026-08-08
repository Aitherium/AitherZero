#Requires -Version 7.0

<#
.SYNOPSIS
    Register this node's ComfyUI as the caller's image backend so Canvas/Iris route jobs to it.

.DESCRIPTION
    The last step of the self-hosted image path: tell the fleet that THIS node serves ComfyUI, so a
    subscriber's Canvas/Iris generation runs on their own hardware instead of the platform pool.

    THE CONTRACT (must match the Canvas/Iris resolver):
      POST /api/compute?action=register-node with:
        node_type    = "gpu_node"
        capabilities = ["comfyui"]                 <- the resolver filters on this exact tag
        metadata.comfyui_url = "http://<addr>:<port>"   <- the resolver reads this first
      The resolver then GETs /compute/nodes?node_type=gpu_node under the CALLER's auth (scoped to
      the caller's tenant, fail-closed on empty tenant), keeps nodes whose capabilities
      include "comfyui" and whose comfyui_url is set, and health-checks GET <comfyui_url>/system_stats
      on a 3s timeout before routing a job there.

    AUTH (FAIL-CLOSED): registration is tenant-scoped. It goes through the authenticated portal edge
    (portal.aitherium.com) — an unauthenticated register lands in a fabricated 'public' tenant that
    the caller's own session will never discover, so the node would look registered and never receive
    a job. This script fails LOUD if the register response is not tenant-owned, and VERIFIES by reading
    the node back through the SAME authenticated listing the resolver uses (a POST 200 proves nothing
    about whether the caller can see it).

    IDEMPOTENT: re-run to reconcile; the system keys the node on name+tenant, so a repeat register
    updates rather than duplicates.

    Exit codes: 0 registered+visible | 1 register failed | 2 not visible in the caller's listing
                (the auth/tenant trap) | 3 ComfyUI not reachable at the advertised address | 5 param
                invalid | 10 no auth material (need -PortalUrl + -SessionCookie).

.PARAMETER Address
    The ComfyUI address advertised to the fleet (the SAME one 3252 bound). Default: auto-detect
    tailnet/LAN IP. Must be reachable by the Veil node that will proxy jobs.

.PARAMETER Port
    ComfyUI port (from 3252). Default: 8188.

.PARAMETER NodeName
    Friendly node name. Default: the machine hostname. The system keys on name+tenant.

.PARAMETER PortalUrl
    Authenticated Veil edge base (e.g. https://portal.aitherium.com). Preferred path: the register goes
    through the session-authenticated proxy so tenant scoping is correct.

.PARAMETER SessionCookie
    The aither_auth session cookie value for -PortalUrl (from an interactive login). Required with
    -PortalUrl. NEVER logged.

.PARAMETER DryRun
    Plan mode: show the exact request, send nothing.

.EXAMPLE
    ./3253_Register-ImageBackend.ps1 -Address 192.168.1.100 -Port 8188 -PortalUrl https://portal.aitherium.com -SessionCookie $c

.NOTES
    Stage: Onboarding | Order: 3253 | Platform: Windows/pwsh
    Tags: comfyui, register, compute-fabric, byo-backend, canvas, tenant-scoped
    Ends the 3250->3253 image-backend onboarding chain.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Address,
    [int]$Port = 8188,
    [string]$NodeName = [System.Net.Dns]::GetHostName(),
    [string]$PortalUrl,
    [string]$SessionCookie,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Log($m, $c = 'Cyan') { Write-Host ("[3253] " + $m) -ForegroundColor $c }
function LogSuccess($m) { Log $m 'Green' }
function LogWarn($m) { Log $m 'Yellow' }
function LogError($m) { Log $m 'Red' }

function Resolve-Address {
    if ($Address) { return $Address }
    $addrs = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' }).IPAddressToString
    $tailnet = $addrs | Where-Object { $_ -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' } | Select-Object -First 1
    if ($tailnet) { return $tailnet }
    $lan = $addrs | Where-Object { $_ -match '^192\.168\.' } | Select-Object -First 1
    if ($lan) { return $lan }
    LogError "could not auto-detect a tailnet/LAN IP; pass -Address explicitly (a peer must reach it)"
    exit 5
}

# Resolve endpoint configuration for authenticated registration through the Portal.
function Resolve-Endpoint {
    if (-not $PortalUrl) {
        LogError "Missing -PortalUrl (e.g., https://portal.aitherium.com)"
        exit 10
    }
    if (-not $SessionCookie) {
        LogError "-PortalUrl requires -SessionCookie (from an interactive login)"
        exit 10
    }
    return @{
        Base     = $PortalUrl.TrimEnd('/')
        RegPath  = '/api/compute?action=register-node'
        ListPath = '/api/compute?action=discover'
        Headers  = @{ 'Content-Type' = 'application/json'; 'Cookie' = "aither_auth=$SessionCookie" }
        Mode     = 'portal'
    }
}

$addr = Resolve-Address
$comfyUrl = "http://${addr}:${Port}"

# 0. The backend we are about to advertise MUST actually answer — never register a dead endpoint.
#    Skipped under -DryRun so the exact contract body can be previewed offline.
if ($DryRun) {
    Log "DRY RUN — skipping the live $comfyUrl/system_stats reachability probe (would run for real)" 'Magenta'
} else {
    Log "checking ComfyUI at $comfyUrl/system_stats"
    try {
        $r = Invoke-WebRequest -Uri "$comfyUrl/system_stats" -TimeoutSec 5 -UseBasicParsing
        if ($r.StatusCode -ne 200) { throw "HTTP $($r.StatusCode)" }
    } catch {
        LogError "ComfyUI is not answering at $comfyUrl ($_). Start it first (3252_Start-ComfyUI) — registering a dead endpoint would just make Canvas fail loud."
        exit 3
    }
    LogSuccess "ComfyUI reachable at $comfyUrl"
}

$ep = Resolve-Endpoint

$body = @{
    name         = $NodeName
    address      = $addr
    port         = $Port
    node_type    = 'gpu_node'
    location     = 'workstation'
    capabilities = @('comfyui')
    metadata     = @{ comfyui_url = $comfyUrl }
} | ConvertTo-Json -Depth 6

if ($DryRun) {
    Log "DRY RUN — would POST to $($ep.Base)$($ep.RegPath):" 'Magenta'
    Write-Host $body
    exit 0
}

# 1. Register
Log "registering '$NodeName' -> $comfyUrl via $($ep.Mode)"
try {
    $resp = Invoke-RestMethod -Method Post -Uri "$($ep.Base)$($ep.RegPath)" -Headers $ep.Headers -Body $body -TimeoutSec 20
} catch {
    LogError "register POST failed: $_"
    exit 1
}
$nodeId = $resp.node_id
if (-not $nodeId) { LogError "register response had no node_id: $($resp | ConvertTo-Json -Compress)"; exit 1 }

# The auth/tenant trap: a node id ending in '-public' means the register was UNauthenticated and
# landed in the fabricated platform tenant — the caller's own session will never discover it.
if ($nodeId -match '-public$') {
    LogError "node registered under the 'public' tenant ($nodeId) — the register was not tenant-scoped."
    LogError "Canvas will NEVER route to it because the caller's session cannot see it. Fix the auth material and re-run."
    exit 2
}
Log "registered node_id=$nodeId"

# 2. VERIFY through the SAME listing the resolver uses (POST 200 does not prove the caller can see it)
Log "verifying visibility in the caller's node listing..."
Start-Sleep -Seconds 1
try {
    $list = Invoke-RestMethod -Method Get -Uri "$($ep.Base)$($ep.ListPath)" -Headers $ep.Headers -TimeoutSec 15
} catch {
    LogError "could not read back the node listing: $_"
    exit 2
}
# The discovery response may nest nodes differently; normalise to a flat node array.
$nodes = @()
if ($list.nodes) { $nodes = $list.nodes }
elseif ($list.fabric -and $list.fabric.nodes) { $nodes = $list.fabric.nodes }
elseif ($list.gpu_nodes) { $nodes = $list.gpu_nodes }

$mine = $nodes | Where-Object {
    ($_.node_id -eq $nodeId -or $_.name -eq $NodeName) -and
    (($_.capabilities -contains 'comfyui') -or ($_.metadata.comfyui_url))
}
if (-not $mine) {
    LogError "node registered (id=$nodeId) but is NOT visible in the caller's own listing."
    LogError "This is the tenant-scoping trap: Canvas discovers nodes under the caller's tenant only."
    LogError "Confirm the register used the same authenticated identity a real Canvas request will."
    exit 2
}

LogSuccess "image backend registered AND visible: '$NodeName' ($nodeId) -> $comfyUrl"
Log "A Canvas/Iris job from this workspace will now health-check and route to your node."
Log "To force the platform pool for one job, send backend:'platform'; to require your node, backend:'own'."
exit 0
