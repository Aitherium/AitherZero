#Requires -Version 7.0
# Stage: Automation
# Dependencies: None
# Description: Configure ADK Credentials (API Key)
# Tags: ai, agent, security, config

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$AgentName,

    [Parameter()]
    [string]$ParentPath = "agents",

    [Parameter()]
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_init.ps1"
$targetDir = Join-Path $projectRoot $ParentPath $AgentName
$envFile = Join-Path $targetDir ".env"

try {
    if (-not (Test-Path $envFile)) {
        throw "Environment file not found at $envFile. Run 0750_New-ADKAgentProject.ps1 first."
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        # Check Environment Variables
        if ($env:GEMINI_API_KEY) {
            $ApiKey = $env:GEMINI_API_KEY
            Write-Host "[Information] Using API Key from environment variable GEMINI_API_KEY"
        } elseif ($env:GOOGLE_API_KEY) {
            $ApiKey = $env:GOOGLE_API_KEY
            Write-Host "[Information] Using API Key from environment variable GOOGLE_API_KEY"
        } else {
            Write-Host "[Warning] No API key found in environment variables (GEMINI_API_KEY or GOOGLE_API_KEY)"
            Write-Host "[Information] You can set it later by editing: $envFile"
            return
        }
    }

    if ($PSCmdlet.ShouldProcess($envFile, "Update API Key")) {
        $content = Get-Content $envFile
        $newContent = @()
        $found = $false

        foreach ($line in $content) {
            if ($line -match "^GOOGLE_API_KEY=") {
                $newContent += "GOOGLE_API_KEY=$ApiKey"
                $found = $true
            } else {
                $newContent += $line
            }
        }

        if (-not $found) {
            $newContent += "GOOGLE_API_KEY=$ApiKey"
        }

        Set-Content -Path $envFile -Value $newContent
        Write-Host "[Success] Updated API Key in $envFile"
    }

} catch {
    Write-Host "[Error] Configuration failed: $_"
    exit 1
}
