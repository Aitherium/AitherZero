#Requires -Version 7.0

<#
.SYNOPSIS
    Scaffolds a new AitherZero PowerShell module.

.DESCRIPTION
    Creates a standard PowerShell module structure compatible with AitherZero's build system.
    Includes source directories (public/private), manifest, and build script.

.PARAMETER Name
    The name of the module.

.PARAMETER Path
    The parent directory where the module folder will be created. Defaults to current location.

.PARAMETER Description
    Module description for the manifest.

.PARAMETER Author
    Module author. Defaults to current user or git config.

.PARAMETER Version
    Initial version. Defaults to '0.0.1'.

.PARAMETER Force
    Overwrite existing module files.

.EXAMPLE
    New-AitherModule -Name "MyFeature" -Path "./library/modules"
#>
function New-AitherModule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string]$Name,

        [Parameter(Position = 1)]
        [string]$Path = '.',

        [string]$Description = "AitherZero module for $Name",
        [string]$Author = $env:USERNAME,
        [string]$Version = "0.0.1",
        [switch]$Force
    )

    process {
        $modulePath = Join-Path $Path $Name
        
        if (Test-Path $modulePath) {
            if (-not $Force) {
                Write-AitherLog -Level Error -Message "Module directory '$modulePath' already exists. Use -Force to overwrite." -Source 'New-AitherModule'
                throw "Module directory '$modulePath' already exists. Use -Force to overwrite."
            }
            Write-AitherLog -Level Warning -Message "Overwriting existing module at '$modulePath'" -Source 'New-AitherModule'
        }

        if ($PSCmdlet.ShouldProcess($modulePath, "Create module structure")) {
            # Create directories
            $dirs = @(
                "src/public",
                "src/private",
                "tests",
                "bin"
            )

            foreach ($dir in $dirs) {
                New-Item -Path (Join-Path $modulePath $dir) -ItemType Directory -Force | Out-Null
            }

            # Create Module Manifest (.psd1)
            $manifestPath = Join-Path $modulePath "$Name.psd1"
            $manifestContent = @{
                RootModule = "$Name.psm1"
                ModuleVersion = $Version
                GUID = [Guid]::NewGuid().ToString()
                Author = $Author
                CompanyName = "AitherZero"
                Copyright = "(c) $(Get-Date -Format 'yyyy') $Author. All rights reserved."
                Description = $Description
                PowerShellVersion = '7.0'
                FunctionsToExport = @('*')
                CmdletsToExport = @()
                VariablesToExport = @('*')
                AliasesToExport = @()
                PrivateData = @{
                    PSData = @{
                        Tags = @('AitherZero', 'Module')
                        ProjectUri = ''
                        LicenseUri = ''
                    }
                }
            }

            # Convert hashtable to string manually or use New-ModuleManifest for proper formatting
            # New-ModuleManifest is safer and cleaner
            if (Test-Path $manifestPath) {
                if ($Force) {
                    Remove-Item -Path $manifestPath -Force
                } else {
                    Write-Error "Manifest file '$manifestPath' already exists. Use -Force to overwrite."
                    return
                }
            }
            
            New-ModuleManifest -Path $manifestPath -RootModule "$Name.psm1" -ModuleVersion $Version -Author $Author -Description $Description -PowerShellVersion '7.0' -FunctionsToExport '*'

            # Create Module Script (.psm1) - Loader logic
            $psm1Path = Join-Path $modulePath "$Name.psm1"
            $psm1Content = @"
# AitherZero Module Loader
# Auto-loads functions from src/public and src/private

\$publicFunctions = Get-ChildItem -Path (Join-Path \$PSScriptRoot 'src/public') -Filter '*.ps1' -Recurse
\$privateFunctions = Get-ChildItem -Path (Join-Path \$PSScriptRoot 'src/private') -Filter '*.ps1' -Recurse

foreach (\$script in \$privateFunctions) {
    . \$script.FullName
}

foreach (\$script in \$publicFunctions) {
    . \$script.FullName
    Export-ModuleMember -Function \$script.BaseName
}
"@
            Set-Content -Path $psm1Path -Value $psm1Content

            # Create Build Script (basic)
            $buildPath = Join-Path $modulePath "build.ps1"
            $buildContent = @"
# Basic Build Script
param([string]\$OutputPath = './bin')

\$moduleName = '$Name'
Write-Host "Building \$moduleName..."

# Copy to bin (simulation of build)
Copy-Item -Path "./\$moduleName.psm1" -Destination "\$OutputPath/\$moduleName.psm1" -Force
Copy-Item -Path "./\$moduleName.psd1" -Destination "\$OutputPath/\$moduleName.psd1" -Force

Write-Host "Build complete."
"@
            Set-Content -Path $buildPath -Value $buildContent

            # Create Sample Function
            $sampleFuncPath = Join-Path $modulePath "src/public/Get-$Name.ps1"
            $sampleFuncContent = @"
function Get-$Name {
    <#
    .SYNOPSIS
        Sample function for $Name
    #>
    [CmdletBinding()]
    param()
    
    Write-Output "Hello from $Name"
}
"@
            Set-Content -Path $sampleFuncPath -Value $sampleFuncContent

            Write-AitherLog -Level Information -Message "Module '$Name' created successfully at '$modulePath'" -Source 'New-AitherModule'
            
            return Get-Item $modulePath
        }
    }
}

