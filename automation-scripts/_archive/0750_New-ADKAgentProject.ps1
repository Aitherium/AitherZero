#Requires -Version 7.0
# Stage: Automation
# Dependencies: None
# Description: Scaffolds a new ADK Agent project from templates
# Tags: ai, agent, scaffolding

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory=$true)]
    [string]$AgentName,

    [Parameter()]
    [string]$ParentPath = "agents"
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_init.ps1"
$targetDir = Join-Path $projectRoot $ParentPath $AgentName
$templateDir = Join-Path $projectRoot "library" "templates" "adk-agent"

Write-Host "[Information] Scaffolding ADK Agent '$AgentName' in '$targetDir'..."

try {
    # 1. Create Directory
    if (-not (Test-Path $targetDir)) {
        if ($PSCmdlet.ShouldProcess($targetDir, "Create Directory")) {
            New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
        }
    }

    # 2. Copy Templates
    $files = Get-ChildItem -Path $templateDir -Force
    foreach ($file in $files) {
        $dest = Join-Path $targetDir $file.Name
        if ($PSCmdlet.ShouldProcess($dest, "Copy Template")) {
            Copy-Item -Path $file.FullName -Destination $dest -Force
            Write-Host "[Information] Created $dest"
        }
    }
    
    # Ensure run.sh is executable on Linux
    $runScript = Join-Path $targetDir "run.sh"
    if ($IsLinux -and (Test-Path $runScript)) {
        if (Get-Command chmod -ErrorAction SilentlyContinue) {
            chmod +x $runScript
        }
    }

    # 3. Rename .env.example to .env if it doesn't exist
    $envPath = Join-Path $targetDir ".env"
    $envExample = Join-Path $targetDir ".env.example"
    if (-not (Test-Path $envPath) -and (Test-Path $envExample)) {
         if ($PSCmdlet.ShouldProcess($envPath, "Create .env from example")) {
            Copy-Item -Path $envExample -Destination $envPath
         }
    }

    Write-Host "[Success] Agent project scaffolded successfully at $targetDir"

} catch {
    Write-Host "[Error] Scaffolding failed: $_"
    exit 1
}
