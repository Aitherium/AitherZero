<#
.SYNOPSIS
    Imports secrets from a local .env file into the Vault.

.DESCRIPTION
    Reads KEY=VALUE pairs from a file and pushes them to AitherSecrets.
    Useful for bootstrapping a new environment.

.PARAMETER Path
    Path to the .env file.

.EXAMPLE
    ./6003_Import-Secrets.ps1 -Path ./.env.production
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)

if (-not (Test-Path $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$AddScript = Join-Path $PSScriptRoot "6001_Add-Secret.ps1"

Write-Host "Importing secrets from $Path..." -ForegroundColor Cyan

Get-Content $Path | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        try {
            # Split only on first '='
            $parts = $line.Split("=", 2)
            if ($parts.Count -eq 2) {
                $key = $parts[0].Trim()
                $val = $parts[1].Trim()
                
                # Remove quotes if present
                if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1, $val.Length-2) }
                elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1, $val.Length-2) }

                Write-Host "Processing $key..." -NoNewline
                
                # Call Add-Secret script
                # We use -Access internal by default for bulk imports
                & $AddScript -Name $key -Value $val -Type "generic" -Access "internal" | Out-Null
                
                Write-Host " [OK]" -ForegroundColor Green
            }
        } catch {
            Write-Host " [ERROR] $_" -ForegroundColor Red
        }
    }
}

Write-Host "Import complete." -ForegroundColor Green
