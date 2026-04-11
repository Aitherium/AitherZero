<#
.SYNOPSIS
    Auto-generates OpenAPI documentation from FastAPI services.

.DESCRIPTION
    Scans all AitherOS services defined in services.yaml, fetches their OpenAPI
    schemas (from /openapi.json endpoint), and generates consolidated API
    documentation. Outputs include:
    - Individual service OpenAPI JSON files
    - Merged OpenAPI specification
    - ReDoc/Swagger HTML documentation

.PARAMETER OutputDir
    Directory to write generated documentation (default: docs_build/api).

.PARAMETER Services
    Comma-separated list of specific services to document. If not provided,
    documents all running services.

.PARAMETER Format
    Output format: 'json', 'yaml', 'html', or 'all' (default: all).

.PARAMETER Serve
    Start a simple HTTP server to browse the generated docs.

.PARAMETER Port
    Port for the documentation server (default: 8888).

.PARAMETER ShowOutput
    Show detailed output (scripts are silent by default for pipelines).

.EXAMPLE
    .\0522_Generate-APIDocs.ps1
    Generates API docs for all running services

.EXAMPLE
    .\0522_Generate-APIDocs.ps1 -Services "Pulse,Watch,Node" -Format html
    Generates HTML docs for specific services

.EXAMPLE
    .\0522_Generate-APIDocs.ps1 -Serve
    Generates docs and starts a server to browse them

.NOTES
    Script ID: 0522
    Category: Reporting/Documentation
    Exit Codes: 0 = Success, 1 = Failure
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputDir,

    [Parameter()]
    [string]$Services,

    [Parameter()]
    [ValidateSet('json', 'yaml', 'html', 'all')]
    [string]$Format = 'all',

    [Parameter()]
    [switch]$Serve,

    [Parameter()]
    [int]$Port = 8888,

    [Parameter()]
    [switch]$ShowOutput
)

# Initialize script
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot "docs_build/api"
}

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

function Get-ServicePorts {
    <#
    .SYNOPSIS
        Gets service port mappings from services.yaml
    #>
    $servicesYaml = Join-Path $repoRoot "AitherOS/config/services.yaml"
    
    if (-not (Test-Path $servicesYaml)) {
        Write-Status "services.yaml not found, using known defaults" -Type Warning
        return @{
            Node = 8080
            Pulse = 8081
            Watch = 8082
            LLM = 8118
            Chronicle = 8121
            Mesh = 8125
            SensoryBuffer = 8129
            Sense = 8096
            Faculties = 8138
            Cortex = 8139
        }
    }
    
    # Parse YAML (simplified - just extract port lines)
    $content = Get-Content $servicesYaml -Raw
    $services = @{}
    
    # Match patterns like "  ServiceNamD:\n    port: 8080" (indented under services key)
    $regex = '(?m)^\s{2}(\w+):\s*\n\s+port:\s*(\d+)'
    $yamlMatches = [regex]::Matches($content, $regex)
    
    foreach ($match in $yamlMatches) {
        $name = $match.Groups[1].Value
        $port = [int]$match.Groups[2].Value
        $services[$name] = $port
    }
    
    if ($services.Count -eq 0) {
        Write-Status "Could not parse services.yaml, using defaults" -Type Warning
        return @{
            Node = 8080
            Pulse = 8081
            Watch = 8082
            LLM = 8118
            Chronicle = 8121
            Mesh = 8125
            SensoryBuffer = 8129
            Sense = 8096
            Faculties = 8138
            Cortex = 8139
        }
    }
    
    return $services
}

function Test-ServiceRunning {
    param([string]$Name, [int]$Port)
    
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:$Port/health" -TimeoutSec 5 -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        try {
            $response = Invoke-WebRequest -Uri "http://localhost:$Port/" -TimeoutSec 5 -ErrorAction Stop
            return $response.StatusCode -eq 200
        }
        catch {
            return $false
        }
    }
}

function Get-OpenAPISpec {
    param([string]$Name, [int]$Port)
    
    try {
        $response = Invoke-RestMethod -Uri "http://localhost:$Port/openapi.json" -TimeoutSec 15 -ErrorAction Stop
        return $response
    }
    catch {
        Write-Status "Could not fetch OpenAPI from $Name (port $Port): $_" -Type Warning
        return $null
    }
}

function ConvertTo-Yaml {
    param([object]$Object)
    
    # Simple JSON to YAML conversion (for basic cases)
    $json = $Object | ConvertTo-Json -Depth 20
    
    # Try using Python if available
    $pythonPath = Join-Path $repoRoot "AitherOS/agents/NarrativeAgent/.venv/Scripts/python.exe"
    if (Test-Path $pythonPath) {
        $yamlScript = @"
import json, yaml, sys
data = json.loads(sys.stdin.read())
print(yaml.dump(data, default_flow_style=False, sort_keys=False))
"@
        try {
            $yaml = $json | & $pythonPath -c $yamlScript 2>$null
            if ($yaml) { return $yaml }
        }
        catch {}
    }
    
    # Fallback: return JSON with .yaml extension (user can convert manually)
    return $json
}

function New-MergedOpenAPI {
    param([hashtable]$Specs)
    
    $merged = @{
        openapi = "3.1.0"
        info = @{
            title = "AitherOS API"
            description = "Consolidated API documentation for all AitherOS microservices"
            version = "1.0.0"
            contact = @{
                name = "Aitherium"
                url = "https://github.com/Aitherium/AitherZero-Internal"
            }
        }
        servers = @(
            @{ url = "http://localhost"; description = "Local development" }
        )
        tags = @()
        paths = @{}
        components = @{
            schemas = @{}
            securitySchemes = @{}
        }
    }
    
    foreach ($serviceName in $Specs.Keys) {
        $spec = $Specs[$serviceName]
        if (-not $spec) { continue }
        
        # Add service as a tag
        $merged.tags += @{
            name = $serviceName
            description = $spec.info.description ?? "Aither$serviceName Service"
        }
        
        # Merge paths with service prefix
        if ($spec.paths) {
            foreach ($path in $spec.paths.PSObject.Properties) {
                $pathKey = $path.Name
                $pathValue = $path.Value
                
                # Add tag to each operation
                foreach ($method in $pathValue.PSObject.Properties) {
                    if ($method.Value -is [PSCustomObject]) {
                        if (-not $method.Value.tags) {
                            $method.Value | Add-Member -NotePropertyName 'tags' -NotePropertyValue @($serviceName) -Force
                        }
                    }
                }
                
                # Prefix path with service port info
                $merged.paths["/{$serviceName}$pathKey"] = $pathValue
            }
        }
        
        # Merge schemas with service prefix to avoid collisions
        if ($spec.components -and $spec.components.schemas) {
            foreach ($schema in $spec.components.schemas.PSObject.Properties) {
                $schemaKey = "${serviceName}_$($schema.Name)"
                $merged.components.schemas[$schemaKey] = $schema.Value
            }
        }
    }
    
    return $merged
}

function New-ReDocHTML {
    param([string]$SpecPath, [string]$Title = "AitherOS API Documentation")
    
    $specFileName = Split-Path $SpecPath -Leaf
    
    return @"
<!DOCTYPE html>
<html>
<head>
    <title>$Title</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link href="https://fonts.googleapis.com/css?family=Montserrat:300,400,700|Roboto:300,400,700" rel="stylesheet">
    <style>
        body { margin: 0; padding: 0; }
        .top-bar {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            text-align: center;
        }
        .top-bar h1 { margin: 0; font-family: 'Montserrat', sans-serif; }
        .top-bar p { margin: 5px 0 0; opacity: 0.8; }
    </style>
</head>
<body>
    <div class="top-bar">
        <h1>ðŸŒŸ $Title</h1>
        <p>Auto-generated from running services</p>
    </div>
    <redoc spec-url='$specFileName'></redoc>
    <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
</body>
</html>
"@
}

function New-SwaggerHTML {
    param([string]$SpecPath, [string]$Title = "AitherOS API Explorer")
    
    $specFileName = Split-Path $SpecPath -Leaf
    
    return @"
<!DOCTYPE html>
<html>
<head>
    <title>$Title</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" type="text/css" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
    <style>
        body { margin: 0; }
        .topbar { display: none; }
        .swagger-ui .info { margin: 20px 0; }
    </style>
</head>
<body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
        window.onload = function() {
            SwaggerUIBundle({
                url: "$specFileName",
                dom_id: '#swagger-ui',
                deepLinking: true,
                presets: [
                    SwaggerUIBundle.presets.apis,
                    SwaggerUIBundle.SwaggerUIStandalonePreset
                ],
                layout: "BaseLayout"
            });
        };
    </script>
</body>
</html>
"@
}

function New-IndexHTML {
    param([array]$Services)
    
    $serviceLinks = $Services | ForEach-Object {
        "<li><a href='$($_.Name.ToLower()).html'>$($_.Name)</a> - Port $($_.Port)</li>"
    }
    
    return @"
<!DOCTYPE html>
<html>
<head>
    <title>AitherOS API Documentation</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0;
            padding: 0;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            min-height: 100vh;
            color: #e0e0e0;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 40px 20px;
        }
        header {
            text-align: center;
            margin-bottom: 40px;
        }
        h1 {
            font-size: 3rem;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin: 0;
        }
        .subtitle {
            font-size: 1.2rem;
            opacity: 0.7;
            margin-top: 10px;
        }
        .cards {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
            margin-top: 30px;
        }
        .card {
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 24px;
            border: 1px solid rgba(255,255,255,0.1);
            transition: transform 0.2s, box-shadow 0.2s;
        }
        .card:hover {
            transform: translateY(-4px);
            box-shadow: 0 10px 40px rgba(102, 126, 234, 0.2);
        }
        .card h3 {
            margin: 0 0 10px;
            color: #667eea;
        }
        .card p {
            margin: 0 0 15px;
            opacity: 0.8;
        }
        .card-links {
            display: flex;
            gap: 10px;
        }
        .card-links a {
            padding: 8px 16px;
            background: rgba(102, 126, 234, 0.2);
            color: #667eea;
            text-decoration: none;
            border-radius: 6px;
            font-size: 0.9rem;
            transition: background 0.2s;
        }
        .card-links a:hover {
            background: rgba(102, 126, 234, 0.4);
        }
        .merged-section {
            text-align: center;
            margin-top: 40px;
            padding: 30px;
            background: rgba(102, 126, 234, 0.1);
            border-radius: 12px;
        }
        .merged-section a {
            display: inline-block;
            padding: 12px 24px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            text-decoration: none;
            border-radius: 8px;
            margin: 10px;
            font-weight: bold;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>ðŸŒŸ AitherOS API</h1>
            <p class="subtitle">Auto-generated documentation for 86 microservices</p>
        </header>

        <div class="merged-section">
            <h2>ðŸ“š Complete API Reference</h2>
            <p>All services merged into a single specification</p>
            <a href="merged-redoc.html">ðŸ“– ReDoc (Readable)</a>
            <a href="merged-swagger.html">ðŸ”§ Swagger UI (Interactive)</a>
            <a href="merged-openapi.json">ðŸ“„ OpenAPI JSON</a>
        </div>

        <h2 style="margin-top: 40px;">Individual Services</h2>
        <div class="cards">
$($Services | ForEach-Object {
@"
            <div class="card">
                <h3>$($_.Name)</h3>
                <p>Port $($_.Port)</p>
                <div class="card-links">
                    <a href="$($_.Name.ToLower())-redoc.html">ReDoc</a>
                    <a href="$($_.Name.ToLower())-swagger.html">Swagger</a>
                    <a href="$($_.Name.ToLower())-openapi.json">JSON</a>
                </div>
            </div>
"@
} | Out-String)
        </div>
    </div>
</body>
</html>
"@
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

Write-Status "ðŸ” AitherOS API Documentation Generator" -Type Info
Write-Status "Output directory: $OutputDir" -Type Info

# Create output directory
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Status "Created output directory" -Type Info
}

# Get service ports
$allServices = Get-ServicePorts

# Filter to requested services if specified
if ($Services) {
    $requestedServices = $Services -split ',' | ForEach-Object { $_.Trim() }
    $filteredServices = @{}
    foreach ($name in $requestedServices) {
        if ($allServices.ContainsKey($name)) {
            $filteredServices[$name] = $allServices[$name]
        }
        else {
            Write-Status "Unknown service: $name" -Type Warning
        }
    }
    $allServices = $filteredServices
}

# Check which services are running
$runningServices = @()
$specs = @{}

Write-Status "Scanning services..." -Type Info

foreach ($name in $allServices.Keys) {
    $port = $allServices[$name]
    
    if (Test-ServiceRunning -Name $name -Port $port) {
        Write-Status "✔ $name (port $port) - Running" -Type Success
        
        $spec = Get-OpenAPISpec -Name $name -Port $port
        if ($spec) {
            $runningServices += @{ Name = $name; Port = $port; Spec = $spec }
            $specs[$name] = $spec
            
            # Save individual spec
            if ($Format -in 'json', 'all') {
                $specPath = Join-Path $OutputDir "$($name.ToLower())-openapi.json"
                $spec | ConvertTo-Json -Depth 20 | Set-Content -Path $specPath -Encoding UTF8
                Write-Status "  Saved: $specPath" -Type Info
            }
            
            if ($Format -in 'yaml', 'all') {
                $yamlPath = Join-Path $OutputDir "$($name.ToLower())-openapi.yaml"
                ConvertTo-Yaml -Object $spec | Set-Content -Path $yamlPath -Encoding UTF8
            }
            
            if ($Format -in 'html', 'all') {
                # ReDoc
                $redocPath = Join-Path $OutputDir "$($name.ToLower())-redoc.html"
                New-ReDocHTML -SpecPath "$($name.ToLower())-openapi.json" -Title "Aither$name API" | Set-Content -Path $redocPath -Encoding UTF8
                
                # Swagger UI
                $swaggerPath = Join-Path $OutputDir "$($name.ToLower())-swagger.html"
                New-SwaggerHTML -SpecPath "$($name.ToLower())-openapi.json" -Title "Aither$name API Explorer" | Set-Content -Path $swaggerPath -Encoding UTF8
            }
        }
    }
    else {
        Write-Status "❌— $name (port $port) - Not running" -Type Warning
    }
}

Write-Status "" -Type Info
Write-Status "Found $($runningServices.Count) running services with OpenAPI specs" -Type Info

if ($runningServices.Count -gt 0) {
    # Generate merged spec
    Write-Status "Generating merged OpenAPI specification..." -Type Info
    $mergedSpec = New-MergedOpenAPI -Specs $specs
    
    if ($Format -in 'json', 'all') {
        $mergedPath = Join-Path $OutputDir "merged-openapi.json"
        $mergedSpec | ConvertTo-Json -Depth 20 | Set-Content -Path $mergedPath -Encoding UTF8
        Write-Status "Saved: $mergedPath" -Type Success
    }
    
    if ($Format -in 'yaml', 'all') {
        $mergedYamlPath = Join-Path $OutputDir "merged-openapi.yaml"
        ConvertTo-Yaml -Object $mergedSpec | Set-Content -Path $mergedYamlPath -Encoding UTF8
    }
    
    if ($Format -in 'html', 'all') {
        # Merged ReDoc
        $mergedRedocPath = Join-Path $OutputDir "merged-redoc.html"
        New-ReDocHTML -SpecPath "merged-openapi.json" -Title "AitherOS Complete API" | Set-Content -Path $mergedRedocPath -Encoding UTF8
        
        # Merged Swagger
        $mergedSwaggerPath = Join-Path $OutputDir "merged-swagger.html"
        New-SwaggerHTML -SpecPath "merged-openapi.json" -Title "AitherOS API Explorer" | Set-Content -Path $mergedSwaggerPath -Encoding UTF8
        
        # Index page
        $indexPath = Join-Path $OutputDir "index.html"
        New-IndexHTML -Services $runningServices | Set-Content -Path $indexPath -Encoding UTF8
        Write-Status "Saved index: $indexPath" -Type Success
    }
    
    Write-Status "" -Type Info
    Write-Status "✅ API documentation generated successfully!" -Type Success
    Write-Status "   Location: $OutputDir" -Type Info
    
    if ($Serve) {
        Write-Status "" -Type Info
        Write-Status "Starting documentation server on port $Port..." -Type Info
        
        # Use Python's http.server
        $pythonPath = Join-Path $repoRoot "AitherOS/agents/NarrativeAgent/.venv/Scripts/python.exe"
        if (Test-Path $pythonPath) {
            Push-Location $OutputDir
            Write-Status "ðŸ“š Browse docs at: http://localhost:$Port" -Type Success
            & $pythonPath -m http.server $Port
            Pop-Location
        }
        else {
            Write-Status "Python not found for serving. Open $OutputDir/index.html in a browser." -Type Warning
        }
    }
}
else {
    Write-Status "No running services found. Start some AitherOS services first." -Type Warning
    Write-Status "  Run: pwsh -File ./AitherZero/library/automation-scripts/0800_Start-AitherOS.ps1" -Type Info
    exit 1
}

exit 0

