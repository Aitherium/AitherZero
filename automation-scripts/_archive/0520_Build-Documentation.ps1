<#
.SYNOPSIS
    Builds and optionally serves the MkDocs documentation.

.DESCRIPTION
    This script manages the documentation build process using MkDocs Material.
    It can install dependencies, build the static site, serve locally for preview,
    or deploy to GitHub Pages. Automatically collects markdown files from the
    entire repository into a build directory.

.PARAMETER Serve
    Start a local development server with live reload.

.PARAMETER Build
    Build the static documentation site.

.PARAMETER Deploy
    Deploy documentation to GitHub Pages.

.PARAMETER Install
    Install documentation dependencies.

.PARAMETER Port
    Port for the development server (default: 8000).

.PARAMETER ShowOutput
    Show detailed output (scripts are silent by default for pipelines).

.EXAMPLE
    .\0520_Build-Documentation.ps1 -Serve
    Starts local documentation server at http://localhost:8000

.EXAMPLE
    .\0520_Build-Documentation.ps1 -Build
    Builds static site to ./site directory

.EXAMPLE
    .\0520_Build-Documentation.ps1 -Deploy
    Deploys documentation to GitHub Pages

.NOTES
    Script ID: 0520
    Category: Reporting/Documentation
    Exit Codes: 0 = Success, 1 = Failure
#>

[CmdletBinding(DefaultParameterSetName = 'Serve')]
param(
    [Parameter(ParameterSetName = 'Serve')]
    [switch]$Serve,

    [Parameter(ParameterSetName = 'Build')]
    [switch]$Build,

    [Parameter(ParameterSetName = 'Deploy')]
    [switch]$Deploy,

    [Parameter()]
    [switch]$Install,

    [Parameter()]
    [int]$Port = 8000,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

function Write-Status {
    param([string]$Message, [string]$Type = 'Info')
    if ($ShowOutput) {
        $color = switch ($Type) {
            'Success' { 'Green' }
            'Warning' { 'Yellow' }
            'Error' { 'Red' }
            default { 'Cyan' }
        }
        Write-Host "[$Type] $Message" -ForegroundColor $color
    }
}

function Test-PythonCommand {
    $commands = @('python', 'python3', 'py')
    foreach ($cmd in $commands) {
        try {
            $version = & $cmd --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                return $cmd
            }
        } catch { }
    }
    return $null
}

function Test-MkDocsInstalled {
    try {
        $result = & mkdocs --version 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Sync-DocumentationFiles {
    <#
    .SYNOPSIS
        Collects all markdown files into docs_build directory for MkDocs.
    #>
    param([string]$RepoRoot)
    
    $docsBuild = Join-Path $RepoRoot 'docs_build'
    
    # Clean and create docs_build directory
    if (Test-Path $docsBuild) {
        Remove-Item $docsBuild -Recurse -Force
    }
    New-Item -ItemType Directory -Path $docsBuild -Force | Out-Null
    
    # Define source patterns for markdown files
    $sources = @(
        @{ Source = 'README.md'; Dest = 'index.md' }
        @{ Source = 'CONTRIBUTING.md'; Dest = 'CONTRIBUTING.md' }
        @{ Source = 'DOCKER.md'; Dest = 'DOCKER.md' }
        @{ Source = 'docs/QUICKSTART.md'; Dest = 'QUICKSTART.md' }
        @{ Source = 'docs/ARCHITECTURE.md'; Dest = 'ARCHITECTURE.md' }
        @{ Source = 'docs/CONFIGURATION.md'; Dest = 'CONFIGURATION.md' }
        @{ Source = 'docs/AUTOMATED-DOCS.md'; Dest = 'AUTOMATED-DOCS.md' }
        @{ Source = 'AitherOS/README.md'; Dest = 'aitheros/index.md' }
        @{ Source = 'AitherOS/AitherNode/README.md'; Dest = 'aitheros/aithernode/index.md' }
        @{ Source = 'AitherOS/AitherNode/AitherVeil/README.md'; Dest = 'aitheros/aithernode/aitherveil.md' }
        @{ Source = 'AitherOS/AitherNode/tools/README.md'; Dest = 'aitheros/aithernode/tools.md' }
        @{ Source = 'AitherOS/AitherNode/workflows/README.md'; Dest = 'aitheros/aithernode/workflows.md' }
        @{ Source = 'AitherOS/agents/README.md'; Dest = 'aitheros/agents/index.md' }
        @{ Source = 'AitherOS/agents/common/README.md'; Dest = 'aitheros/agents/common.md' }
        @{ Source = 'AitherOS/tests/README.md'; Dest = 'aitheros/tests.md' }
        @{ Source = 'AitherZero/README.md'; Dest = 'aitherzero/index.md' }
        @{ Source = 'AitherZero/src/README.md'; Dest = 'aitherzero/src.md' }
        @{ Source = 'AitherZero/config/README.md'; Dest = 'aitherzero/config.md' }
        @{ Source = 'AitherZero/tests/README.md'; Dest = 'aitherzero/tests.md' }
        @{ Source = 'AitherZero/library/automation-scripts/README.md'; Dest = 'aitherzero/automation-scripts.md' }
        @{ Source = 'AitherZero/library/playbooks/README.md'; Dest = 'aitherzero/playbooks.md' }
    )
    
    foreach ($item in $sources) {
        $srcPath = Join-Path $RepoRoot $item.Source
        $destPath = Join-Path $docsBuild $item.Dest
        
        if (Test-Path $srcPath) {
            # Create destination directory
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            
            if ($item.IsDir) {
                # Copy directory contents
                Copy-Item -Path "$srcPath\*" -Destination $destPath -Recurse -Force
            } else {
                # Copy file and fix relative links
                $content = Get-Content $srcPath -Raw
                
                # Adjust navigation links for docs site structure
                # This is a simplified approach - complex projects may need more sophisticated link rewriting
                
                Set-Content -Path $destPath -Value $content -NoNewline
            }
            Write-Status "Copied: $($item.Source) -> $($item.Dest)"
        } else {
            Write-Status "Skipped (not found): $($item.Source)" -Type Warning
        }
    }
    
    # Copy logo if exists
    $logoPath = Join-Path $RepoRoot 'aitherium_logo.jpg'
    if (Test-Path $logoPath) {
        Copy-Item $logoPath -Destination $docsBuild -Force
    }
    
    # Copy stylesheets
    $stylesheetsPath = Join-Path $RepoRoot 'docs/stylesheets'
    if (Test-Path $stylesheetsPath) {
        $destStylesheets = Join-Path $docsBuild 'stylesheets'
        New-Item -ItemType Directory -Path $destStylesheets -Force | Out-Null
        Copy-Item -Path "$stylesheetsPath/*" -Destination $destStylesheets -Recurse -Force
        Write-Status "Copied: stylesheets"
    }
    
    Write-Status "Documentation files synchronized to docs_build/" -Type Success
}

# Main execution
try {
    Push-Location $repoRoot

    # Check for Python
    $pythonCmd = Test-PythonCommand
    if (-not $pythonCmd) {
        Write-Status "Python not found. Please install Python 3.8+" -Type Error
        exit 1
    }
    Write-Status "Using Python: $pythonCmd"

    # Install dependencies if requested or MkDocs not found
    if ($Install -or -not (Test-MkDocsInstalled)) {
        Write-Status "Installing documentation dependencies..."
        
        $requirementsPath = Join-Path $repoRoot 'requirements-docs.txt'
        if (Test-Path $requirementsPath) {
            & $pythonCmd -m pip install -r $requirementsPath --quiet
        } else {
            & $pythonCmd -m pip install mkdocs-material mkdocs-awesome-pages-plugin --quiet
        }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Failed to install dependencies" -Type Error
            exit 1
        }
        Write-Status "Dependencies installed" -Type Success
    }

    # Check mkdocs.yml exists
    $mkdocsConfig = Join-Path $repoRoot 'mkdocs.yml'
    if (-not (Test-Path $mkdocsConfig)) {
        Write-Status "mkdocs.yml not found at $mkdocsConfig" -Type Error
        exit 1
    }

    # Sync documentation files to docs_build
    Write-Status "Synchronizing documentation files..."
    Sync-DocumentationFiles -RepoRoot $repoRoot

    # Execute requested action
    switch ($PSCmdlet.ParameterSetName) {
        'Serve' {
            Write-Status "Starting documentation server on port $Port..."
            Write-Status "Access at: http://localhost:$Port" -Type Success
            & mkdocs serve --dev-addr "localhost:$Port"
        }
        'Build' {
            Write-Status "Building documentation..."
            & mkdocs build
            if ($LASTEXITCODE -eq 0) {
                $siteDir = Join-Path $repoRoot 'site'
                Write-Status "Documentation built successfully at: $siteDir" -Type Success
            } else {
                Write-Status "Build failed" -Type Error
                exit 1
            }
        }
        'Deploy' {
            Write-Status "Deploying documentation to GitHub Pages..."
            & mkdocs gh-deploy --force
            if ($LASTEXITCODE -eq 0) {
                Write-Status "Documentation deployed successfully" -Type Success
            } else {
                Write-Status "Deployment failed" -Type Error
                exit 1
            }
        }
    }

    exit 0
}
catch {
    Write-Status "Error: $_" -Type Error
    exit 1
}
finally {
    Pop-Location
}
