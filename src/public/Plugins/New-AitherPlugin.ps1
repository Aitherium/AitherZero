function New-AitherPlugin {
    <#
    .SYNOPSIS
        Scaffolds a new AitherZero plugin from the template.
    .PARAMETER Name
        The name of the new plugin.
    .PARAMETER Path
        The directory to create the plugin in. Defaults to ./plugins/
    .PARAMETER Description
        A short description of the plugin.
    .EXAMPLE
        New-AitherPlugin -Name 'my-webapp' -Description 'Deploy my web application'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Path,

        [string]$Description = "AitherZero plugin for $Name"
    )

    if (-not $Path) {
        $Path = Join-Path $script:ModuleRoot 'plugins'
    }

    $targetPath = Join-Path $Path $Name
    $templatePath = Join-Path $script:ModuleRoot 'plugins' '_template'

    if (Test-Path $targetPath) {
        Write-Error "Plugin directory already exists: $targetPath"
        return
    }

    if (-not (Test-Path $templatePath)) {
        Write-Error "Plugin template not found: $templatePath"
        return
    }

    # Copy template
    Copy-Item -Path $templatePath -Destination $targetPath -Recurse

    # Update manifest
    $manifestPath = Join-Path $targetPath 'plugin.psd1'
    $content = Get-Content $manifestPath -Raw
    $content = $content -replace "Name\s*=\s*'my-plugin'", "Name            = '$Name'"
    $content = $content -replace "Description\s*=\s*'A template plugin for AitherZero'", "Description     = '$Description'"
    Set-Content -Path $manifestPath -Value $content

    Write-Host "Plugin '$Name' created at: $targetPath" -ForegroundColor Green
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Edit $manifestPath with your plugin details"
    Write-Host "  2. Add scripts to $targetPath/scripts/"
    Write-Host "  3. Register: Register-AitherPlugin -Path '$targetPath'"

    return $targetPath
}
