#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Manage infrastructure request approvals in the Genesis approval queue.

.DESCRIPTION
    Get-AitherInfraApproval provides infrastructure admins with tools to review,
    approve, or reject pending infrastructure requests. It's the human gate in
    the infrastructure-as-code workflow.

.PARAMETER Action
    What to do: List (pending requests), Approve, Reject, Details.

.PARAMETER RequestId
    The infrastructure request ID to act on (required for Approve/Reject/Details).

.PARAMETER Comment
    Approver/rejector comment (optional, shown in audit trail).

.PARAMETER StatusFilter
    Filter requests by status when listing: pending, approved, active, all.

.PARAMETER GenesisUrl
    Genesis API URL.

.PARAMETER PassThru
    Return raw API response.

.EXAMPLE
    # List all pending requests
    Get-AitherInfraApproval -Action List

.EXAMPLE
    # View request details before approving
    Get-AitherInfraApproval -Action Details -RequestId 'infra-abc123'

.EXAMPLE
    # Approve a request
    Get-AitherInfraApproval -Action Approve -RequestId 'infra-abc123' -Comment 'Looks good, approved for staging'

.EXAMPLE
    # Reject with reason
    Get-AitherInfraApproval -Action Reject -RequestId 'infra-abc123' -Comment 'Missing health checks on 2 services'
#>
function Get-AitherInfraApproval {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('List', 'Approve', 'Reject', 'Details')]
        [string]$Action,

        [string]$RequestId,

        [string]$Comment = '',

        [ValidateSet('pending', 'approved', 'active', 'rejected', 'all')]
        [string]$StatusFilter = 'pending',

        [string]$GenesisUrl,

        [switch]$PassThru
    )

    # ── Resolve Genesis URL ──────────────────────────────────────────────
    $BaseUrl = if ($GenesisUrl) { $GenesisUrl }
    elseif ($env:AITHER_GENESIS_URL) { $env:AITHER_GENESIS_URL }
    else { 'http://localhost:8001' }

    switch ($Action) {
        'List' {
            Write-Host "📋 Infrastructure Requests ($StatusFilter)" -ForegroundColor Cyan
            Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray

            $queryParams = if ($StatusFilter -ne 'all') { "?status=$StatusFilter" } else { '' }

            try {
                $resp = Invoke-RestMethod -Uri "$BaseUrl/infra/requests$queryParams" -Method Get -ErrorAction Stop

                if ($resp.requests.Count -eq 0) {
                    Write-Host "  No requests found with status '$StatusFilter'" -ForegroundColor DarkGray
                    return
                }

                foreach ($req in $resp.requests) {
                    $statusColor = switch ($req.status) {
                        'pending'  { 'Yellow' }
                        'approved' { 'Cyan' }
                        'active'   { 'Green' }
                        'rejected' { 'Red' }
                        default    { 'White' }
                    }

                    Write-Host ""
                    Write-Host "  [$($req.id)]" -ForegroundColor Cyan -NoNewline
                    Write-Host " $($req.name)" -ForegroundColor White
                    Write-Host "    Provider:    $($req.provider)" -ForegroundColor DarkGray
                    Write-Host "    Environment: $($req.environment)" -ForegroundColor DarkGray
                    Write-Host "    Status:      $($req.status)" -ForegroundColor $statusColor
                    Write-Host "    Requested:   $($req.requested_by) @ $($req.requested_at)" -ForegroundColor DarkGray
                    Write-Host "    Services:    $($req.service_count)" -ForegroundColor DarkGray
                }

                Write-Host ""
                Write-Host "  Total: $($resp.total) request(s)" -ForegroundColor DarkGray
                Write-Host "─────────────────────────────────────────" -ForegroundColor DarkGray

                if ($PassThru) { return $resp }

            } catch {
                Write-Error "Failed to list requests: $($_.Exception.Message)"
            }
        }

        'Details' {
            if (-not $RequestId) {
                Write-Error "RequestId is required for Details action"
                return
            }

            try {
                $resp = Invoke-RestMethod -Uri "$BaseUrl/infra/requests/$RequestId" -Method Get -ErrorAction Stop

                Write-Host ""
                Write-Host "📦 Infrastructure Request Details" -ForegroundColor Cyan
                Write-Host "═════════════════════════════════════════" -ForegroundColor DarkGray
                Write-Host "  ID:             $($resp.id)" -ForegroundColor White
                Write-Host "  Name:           $($resp.name)" -ForegroundColor White
                Write-Host "  Provider:       $($resp.provider)" -ForegroundColor White
                Write-Host "  Environment:    $($resp.environment)" -ForegroundColor White
                Write-Host "  Profile:        $($resp.profile)" -ForegroundColor White
                if ($resp.region) {
                    Write-Host "  Region:         $($resp.region)" -ForegroundColor White
                }
                Write-Host "  Status:         $($resp.status)" -ForegroundColor $(if ($resp.status -eq 'pending') { 'Yellow' } else { 'White' })
                Write-Host "  Requested by:   $($resp.requested_by)" -ForegroundColor White
                Write-Host "  Requested at:   $($resp.requested_at)" -ForegroundColor White

                if ($resp.justification) {
                    Write-Host ""
                    Write-Host "  Justification:" -ForegroundColor Cyan
                    Write-Host "    $($resp.justification)" -ForegroundColor White
                }

                if ($resp.auto_destroy_hours) {
                    Write-Host "  Auto-destroy:   $($resp.auto_destroy_hours)h" -ForegroundColor Yellow
                }

                # Show services
                if ($resp.services -and $resp.services.Count -gt 0) {
                    Write-Host ""
                    Write-Host "  Services ($($resp.services.Count)):" -ForegroundColor Cyan
                    foreach ($svc in $resp.services) {
                        Write-Host "    - $($svc.name): $($svc.image)" -ForegroundColor White
                        if ($svc.ports) {
                            Write-Host "      Ports: $($svc.ports -join ', ')" -ForegroundColor DarkGray
                        }
                        if ($svc.replicas -gt 1) {
                            Write-Host "      Replicas: $($svc.replicas)" -ForegroundColor DarkGray
                        }
                    }
                }

                # Show history
                if ($resp.history -and $resp.history.Count -gt 0) {
                    Write-Host ""
                    Write-Host "  History:" -ForegroundColor Cyan
                    foreach ($h in $resp.history) {
                        Write-Host "    [$($h.at)] $($h.action) by $($h.by)" -ForegroundColor DarkGray
                        if ($h.comment) {
                            Write-Host "      → $($h.comment)" -ForegroundColor DarkGray
                        }
                    }
                }

                Write-Host "═════════════════════════════════════════" -ForegroundColor DarkGray

                if ($PassThru) { return $resp }

            } catch {
                Write-Error "Failed to get request details: $($_.Exception.Message)"
            }
        }

        'Approve' {
            if (-not $RequestId) {
                Write-Error "RequestId is required for Approve action"
                return
            }

            Write-Host "✅ Approving request $RequestId..." -ForegroundColor Green

            $body = @{ comment = $Comment } | ConvertTo-Json

            if ($PSCmdlet.ShouldProcess($RequestId, "Approve infrastructure request")) {
                try {
                    $resp = Invoke-RestMethod -Uri "$BaseUrl/infra/requests/$RequestId/approve" `
                        -Method Post `
                        -Body $body `
                        -ContentType 'application/json' `
                        -ErrorAction Stop

                    Write-Host "  Status: $($resp.status)" -ForegroundColor Green
                    Write-Host "  $($resp.message)" -ForegroundColor White

                    if ($PassThru) { return $resp }

                } catch {
                    $errorMsg = $_.Exception.Message
                    if ($_.ErrorDetails.Message) {
                        try {
                            $err = $_.ErrorDetails.Message | ConvertFrom-Json
                            $errorMsg = $err.detail ?? $errorMsg
                        } catch { }
                    }
                    Write-Error "Approval failed: $errorMsg"
                }
            }
        }

        'Reject' {
            if (-not $RequestId) {
                Write-Error "RequestId is required for Reject action"
                return
            }

            if (-not $Comment) {
                Write-Warning "Consider providing a -Comment explaining the rejection reason"
            }

            Write-Host "❌ Rejecting request $RequestId..." -ForegroundColor Red

            $body = @{ comment = $Comment } | ConvertTo-Json

            if ($PSCmdlet.ShouldProcess($RequestId, "Reject infrastructure request")) {
                try {
                    $resp = Invoke-RestMethod -Uri "$BaseUrl/infra/requests/$RequestId/reject" `
                        -Method Post `
                        -Body $body `
                        -ContentType 'application/json' `
                        -ErrorAction Stop

                    Write-Host "  Status: $($resp.status)" -ForegroundColor Red

                    if ($PassThru) { return $resp }

                } catch {
                    Write-Error "Rejection failed: $($_.Exception.Message)"
                }
            }
        }
    }
}

Export-ModuleMember -Function Get-AitherInfraApproval
