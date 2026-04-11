#Requires -Version 7.0

<#
.SYNOPSIS
    Synchronizes AitherOS services.yaml to AitherZero services.psd1.

.DESCRIPTION
    Reads the canonical AitherOS/config/services.yaml and generates an updated
    AitherZero/config/services.psd1 mirror. Detects drift between the two files
    and reports added/removed/changed services.

    This prevents silent config drift between AitherOS (Python) and AitherZero
    (PowerShell) service registries.

.PARAMETER DryRun
    Show what would change without actually updating services.psd1.

.PARAMETER Force
    Overwrite services.psd1 even if no drift is detected.

.PARAMETER ServicesYamlPath
    Path to AitherOS services.yaml. Auto-discovered if not specified.

.PARAMETER OutputPath
    Path for the generated services.psd1. Defaults to AitherZero/config/services.psd1.

.EXAMPLE
    Sync-AitherServiceConfig
    # Auto-sync, report drift

.EXAMPLE
    Sync-AitherServiceConfig -DryRun
    # Show what would change without writing

.NOTES
    Category: Configuration
    Dependencies: Python (for YAML parsing helper)
    Platform: Windows, Linux, macOS
#>
function Sync-AitherServiceConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [string]$ServicesYamlPath,

        [Parameter()]
        [string]$OutputPath
    )

    # Locate services.yaml
    if (-not $ServicesYamlPath) {
        $root = Get-AitherProjectRoot -ErrorAction SilentlyContinue
        if (-not $root) { $root = $projectRoot }
        $candidates = @(
            (Join-Path $root "AitherOS/config/services.yaml"),
            (Join-Path $root "config/services.yaml")
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $ServicesYamlPath = $c; break }
        }
        if (-not $ServicesYamlPath) {
            Write-Error "Cannot find AitherOS/config/services.yaml. Use -ServicesYamlPath."
            return
        }
    }

    # Locate output
    if (-not $OutputPath) {
        $moduleRoot = Get-AitherModuleRoot -ErrorAction SilentlyContinue
        if (-not $moduleRoot) { $moduleRoot = Join-Path $projectRoot "AitherZero" }
        $OutputPath = Join-Path $moduleRoot "config/services.psd1"
    }

    Write-Host "`n  Syncing service registry" -ForegroundColor Cyan
    Write-Host "  Source: $ServicesYamlPath" -ForegroundColor DarkGray
    Write-Host "  Target: $OutputPath" -ForegroundColor DarkGray

    # Parse YAML using Python helper
    $helperScript = @"
import yaml, json, sys
with open(sys.argv[1], 'r') as f:
    data = yaml.safe_load(f)
services = data.get('services', data)
result = {}
for name, svc in services.items():
    result[name] = {
        'port': svc.get('port'),
        'layer': svc.get('layer'),
        'group': svc.get('group', ''),
        'description': svc.get('description', ''),
        'health_path': svc.get('health_path', '/health'),
        'boot_tier': svc.get('boot_tier', 99),
        'absorbed': svc.get('absorbed', False),
        'compound_of': svc.get('compound_of', []),
    }
json.dump(result, sys.stdout)
"@

    try {
        $jsonOutput = $helperScript | python - $ServicesYamlPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Python YAML parser failed: $jsonOutput"
            return
        }
        $yamlServices = $jsonOutput | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-Error "Failed to parse services.yaml: $_"
        return
    }

    # Load current psd1 for drift detection
    $currentServices = @{}
    if (Test-Path $OutputPath) {
        try {
            $currentData = Import-PowerShellDataFile $OutputPath -ErrorAction Stop
            if ($currentData.Services) { $currentServices = $currentData.Services }
        }
        catch {
            Write-Warning "Could not parse current services.psd1: $_"
        }
    }

    # Detect drift
    $added = @()
    $removed = @()
    $changed = @()

    foreach ($name in $yamlServices.Keys) {
        if (-not $currentServices.ContainsKey($name)) {
            $added += $name
        }
        elseif ($currentServices[$name].Port -ne $yamlServices[$name].port) {
            $changed += "$name (port: $($currentServices[$name].Port) -> $($yamlServices[$name].port))"
        }
    }
    foreach ($name in $currentServices.Keys) {
        if (-not $yamlServices.ContainsKey($name)) {
            $removed += $name
        }
    }

    $hasDrift = ($added.Count -gt 0) -or ($removed.Count -gt 0) -or ($changed.Count -gt 0)

    if ($hasDrift) {
        Write-Host "`n  Drift detected:" -ForegroundColor Yellow
        if ($added.Count -gt 0) {
            Write-Host "    + Added ($($added.Count)): $($added -join ', ')" -ForegroundColor Green
        }
        if ($removed.Count -gt 0) {
            Write-Host "    - Removed ($($removed.Count)): $($removed -join ', ')" -ForegroundColor Red
        }
        if ($changed.Count -gt 0) {
            Write-Host "    ~ Changed ($($changed.Count)): $($changed -join ', ')" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "`n  No drift detected" -ForegroundColor Green
        if (-not $Force) { return }
    }

    if ($DryRun) {
        Write-Host "`n  [DryRun] Would update $OutputPath" -ForegroundColor Yellow
        return
    }

    if (-not $PSCmdlet.ShouldProcess($OutputPath, "Update service registry from services.yaml")) {
        return
    }

    # Generate services.psd1
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# ═══════════════════════════════════════════════════════════════════════════════")
    $null = $sb.AppendLine("# AITHER ECOSYSTEM SERVICE REGISTRY")
    $null = $sb.AppendLine("# ═══════════════════════════════════════════════════════════════════════════════")
    $null = $sb.AppendLine("# AUTO-GENERATED from AitherOS/config/services.yaml by Sync-AitherServiceConfig")
    $null = $sb.AppendLine("# Last sync: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine("# Source: $ServicesYamlPath")
    $null = $sb.AppendLine("# ═══════════════════════════════════════════════════════════════════════════════")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("@{")
    $null = $sb.AppendLine("    Version = `"1.2.0`"")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("    Services = @{")

    # Group by layer
    $byLayer = @{}
    foreach ($name in ($yamlServices.Keys | Sort-Object)) {
        $svc = $yamlServices[$name]
        $layer = if ($svc.layer) { $svc.layer } else { 99 }
        if (-not $byLayer.ContainsKey($layer)) { $byLayer[$layer] = @() }
        $byLayer[$layer] += @{ Name = $name; Svc = $svc }
    }

    foreach ($layer in ($byLayer.Keys | Sort-Object)) {
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("        # Layer $layer")
        foreach ($entry in $byLayer[$layer]) {
            $name = $entry.Name
            $svc = $entry.Svc
            $null = $sb.AppendLine("        $name = @{")
            if ($svc.port) { $null = $sb.AppendLine("            Port        = $($svc.port)") }
            $null = $sb.AppendLine("            Layer       = $layer")
            if ($svc.group) { $null = $sb.AppendLine("            Group       = `"$($svc.group)`"") }
            if ($svc.description) { $null = $sb.AppendLine("            Description = `"$($svc.description)`"") }
            if ($svc.health_path) { $null = $sb.AppendLine("            HealthPath  = `"$($svc.health_path)`"") }
            if ($svc.boot_tier -ne $null) { $null = $sb.AppendLine("            BootTier    = $($svc.boot_tier)") }
            if ($svc.absorbed) { $null = $sb.AppendLine("            Absorbed    = `$true") }
            $null = $sb.AppendLine("        }")
        }
    }

    $null = $sb.AppendLine("    }")
    $null = $sb.AppendLine("}")

    $sb.ToString() | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "`n  Updated $OutputPath ($($yamlServices.Count) services)" -ForegroundColor Green

    # Report to Strata
    if (Get-Command Send-AitherStrata -ErrorAction SilentlyContinue) {
        Send-AitherStrata -EventType 'config-sync' -Data @{
            source_file = $ServicesYamlPath
            target_file = $OutputPath
            services_count = $yamlServices.Count
            added = $added.Count
            removed = $removed.Count
            changed = $changed.Count
        }
    }
}
