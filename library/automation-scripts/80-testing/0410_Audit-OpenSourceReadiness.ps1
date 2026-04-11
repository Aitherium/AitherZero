#Requires -Version 7.0

<#
.SYNOPSIS
    Audits the AitherZero codebase for content that should not be in the public repo.
.DESCRIPTION
    Scans for secrets, internal URLs, hardcoded paths, AitherOS-specific references,
    and other content that needs to be removed or abstracted before open-source extraction.

    Run this BEFORE creating the public repo.
.EXAMPLE
    ./library/automation-scripts/80-testing/0410_Audit-OpenSourceReadiness.ps1
.NOTES
    Category: Testing
    Purpose: Open-source readiness audit
#>

[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot '../../..'),
    [switch]$FixMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$findings = @()
$scanPaths = @(
    'src/'
    'library/automation-scripts/00-bootstrap/'
    'library/automation-scripts/10-devtools/'
    'library/automation-scripts/80-testing/'
    'library/integrations/mcp-server/src/'
    'config/config.psd1'
    'config/config.windows.psd1'
    'config/config.linux.psd1'
    'config/config.macos.psd1'
    'plugins/'
)

# Patterns to check
$secretPatterns = @(
    @{ Name = 'API Key'; Pattern = '(?i)(api[_-]?key|apikey)\s*[:=]\s*["\x27][A-Za-z0-9_\-]{20,}["\x27]' }
    @{ Name = 'Token'; Pattern = '(?i)(token|bearer)\s*[:=]\s*["\x27][A-Za-z0-9_\-\.]{20,}["\x27]' }
    @{ Name = 'Password'; Pattern = '(?i)(password|passwd|pwd)\s*[:=]\s*["\x27][^\x27"]{4,}["\x27]' }
    @{ Name = 'Private Key'; Pattern = '(?i)-----BEGIN (RSA |EC |DSA )?PRIVATE KEY-----' }
    @{ Name = 'Connection String'; Pattern = '(?i)(connection_?string|connstr)\s*[:=]\s*["\x27][^\x27"]{10,}["\x27]' }
)

$aitherOSPatterns = @(
    @{ Name = 'AitherOS compose file'; Pattern = 'docker-compose\.aitheros\.yml' }
    @{ Name = 'AitherOS container prefix'; Pattern = "aitheros-[a-z]+-\d" }
    @{ Name = 'AitherOS network'; Pattern = 'aitheros-net' }
    @{ Name = 'AitherOS registry'; Pattern = 'ghcr\.io/aitheros' }
    @{ Name = 'Genesis port'; Pattern = 'localhost:8001' }
    @{ Name = 'Pulse port'; Pattern = 'localhost:8081' }
    @{ Name = 'Chronicle port'; Pattern = 'localhost:8121' }
    @{ Name = 'Strata port'; Pattern = 'localhost:8136' }
    @{ Name = 'Hardcoded Windows path'; Pattern = '[A-Z]:\\\\?AitherOS' }
    @{ Name = 'Internal domain'; Pattern = '(?i)aitherium\.com(?!/aitherzero)' }
    @{ Name = 'AitherOS config path'; Pattern = 'AitherOS/config/' }
    @{ Name = 'services.yaml ref'; Pattern = 'services\.yaml' }
)

$resolvedBase = Resolve-Path $Path

Write-Host "=== AitherZero Open Source Readiness Audit ===" -ForegroundColor Cyan
Write-Host "Scanning: $resolvedBase" -ForegroundColor Gray
Write-Host ""

foreach ($scanPath in $scanPaths) {
    $fullPath = Join-Path $resolvedBase $scanPath
    if (-not (Test-Path $fullPath)) {
        Write-Host "  SKIP: $scanPath (not found)" -ForegroundColor DarkGray
        continue
    }

    $files = Get-ChildItem -Path $fullPath -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.ts', '*.js', '*.json', '*.md', '*.yml', '*.yaml' |
        Where-Object { $_.Name -ne 'node_modules' -and $_.FullName -notlike '*node_modules*' -and $_.FullName -notlike '*dist*' }

    foreach ($file in $files) {
        $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $relativePath = $file.FullName.Replace($resolvedBase.ToString(), '').TrimStart('\', '/')

        # Check for secrets
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern.Pattern) {
                $findings += [PSCustomObject]@{
                    Severity = 'CRITICAL'
                    Category = 'Secret'
                    Type     = $pattern.Name
                    File     = $relativePath
                    Match    = ($Matches[0] | Select-Object -First 1).Substring(0, [Math]::Min(60, $Matches[0].Length)) + '...'
                }
            }
        }

        # Check for AitherOS-specific references
        foreach ($pattern in $aitherOSPatterns) {
            $matches = [regex]::Matches($content, $pattern.Pattern)
            if ($matches.Count -gt 0) {
                $findings += [PSCustomObject]@{
                    Severity = 'WARNING'
                    Category = 'AitherOS-Specific'
                    Type     = $pattern.Name
                    File     = $relativePath
                    Match    = "$($matches.Count) occurrence(s)"
                }
            }
        }
    }
}

# Report
Write-Host ""
Write-Host "=== RESULTS ===" -ForegroundColor Cyan
Write-Host ""

$critical = $findings | Where-Object { $_.Severity -eq 'CRITICAL' }
$warnings = $findings | Where-Object { $_.Severity -eq 'WARNING' }

if ($critical.Count -gt 0) {
    Write-Host "🚨 CRITICAL: $($critical.Count) potential secret(s) found" -ForegroundColor Red
    $critical | Format-Table -AutoSize
}

if ($warnings.Count -gt 0) {
    Write-Host "⚠️  WARNING: $($warnings.Count) AitherOS-specific reference(s) to abstract" -ForegroundColor Yellow
    $warnings | Group-Object Type | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Count) file(s)" -ForegroundColor Yellow
        $_.Group | ForEach-Object {
            Write-Host "    - $($_.File) ($($_.Match))" -ForegroundColor DarkYellow
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host "✅ No issues found — ready for open-source extraction!" -ForegroundColor Green
}

Write-Host ""
Write-Host "Total: $($critical.Count) critical, $($warnings.Count) warnings across $(($findings | Select-Object -Unique File).Count) files" -ForegroundColor Gray

# Return findings for programmatic use
return $findings
