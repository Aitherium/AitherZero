#Requires -Version 7.0
<#
.SYNOPSIS
    Scaffolds a new expedition (customer app) with Docker, compose, and tunnel-ready config.

.DESCRIPTION
    Creates the full directory structure and boilerplate for a new customer expedition:
      1. Creates expeditions/<name>/backend/ with docker-compose.yml, Dockerfile, .env.example
      2. Generates a FastAPI/Express/static template based on -Stack
      3. Configures shared network for AitherOS tunnel
      4. Optionally deploys immediately via 3060_Deploy-Expedition.ps1

    Designed for Atlas to call when planning a new customer project.

    Exit Codes:
      0 - Success
      1 - Validation failure
      2 - Scaffold error

.PARAMETER Name
    Short expedition name (e.g. "acme-crm", "wildroot"). Used for directory and container naming.

.PARAMETER Stack
    Application stack template. Default: "fastapi"
      - "fastapi"  : Python 3.11 + FastAPI + PostgreSQL + Alembic
      - "express"   : Node.js 20 + Express + PostgreSQL
      - "static"    : Nginx serving static files (SPA/landing page)
      - "custom"    : Empty docker-compose.yml for manual setup

.PARAMETER Hostname
    Public hostname(s) for the tunnel route (comma-separated).

.PARAMETER Port
    Internal app port. Default: 8000

.PARAMETER HostPort
    Host-mapped port. Default: auto-assigned from 8400-8499 range.

.PARAMETER Deploy
    Immediately deploy after scaffolding (calls 3060_Deploy-Expedition.ps1).

.PARAMETER Force
    Overwrite existing expedition directory.

.EXAMPLE
    # Scaffold a new FastAPI expedition
    .\3061_New-Expedition.ps1 -Name acme-crm -Stack fastapi -Hostname "app.acmecrm.io"

.EXAMPLE
    # Scaffold and immediately deploy
    .\3061_New-Expedition.ps1 -Name mybrand -Stack fastapi -Hostname "mybrand.co,www.mybrand.co" -Deploy

.NOTES
    Stage: Deploy
    Order: 3061
    Dependencies: 3060
    Tags: scaffold, expedition, customer-app, new-project
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string]$Name,

    [ValidateSet("fastapi", "express", "static", "custom")]
    [string]$Stack = "fastapi",

    [string]$Hostname,

    [int]$Port = 8000,

    [int]$HostPort = 0,

    [switch]$Deploy,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Paths ─────────────────────────────────────────────────────────────────
$ProjectRoot    = (Resolve-Path "$PSScriptRoot/../../../../").Path
$ExpeditionsDir = Join-Path $ProjectRoot "expeditions"
$TemplatesDir   = Join-Path $ExpeditionsDir ".templates"
$ExpDir         = Join-Path $ExpeditionsDir $Name
$BackendDir     = Join-Path $ExpDir "backend"

# ── Helpers ───────────────────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Good  { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Bad   { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  ℹ $Msg" -ForegroundColor DarkGray }
function Write-Title { param([string]$Msg) Write-Host "`n═══ $Msg ═══" -ForegroundColor Yellow }

# ══════════════════════════════════════════════════════════════════════════
Write-Title "New Expedition: $Name"
Write-Host ""
Write-Host "  Name:       $Name" -ForegroundColor Gray
Write-Host "  Stack:      $Stack" -ForegroundColor Gray
Write-Host "  Hostname:   $(if ($Hostname) { $Hostname } else { '(none yet)' })" -ForegroundColor Gray
Write-Host "  Port:       $Port" -ForegroundColor Gray
Write-Host ""

# ── Validate ──────────────────────────────────────────────────────────────
if ((Test-Path $ExpDir) -and -not $Force) {
    Write-Bad "Expedition directory already exists: $ExpDir"
    Write-Info "Use -Force to overwrite."
    exit 1
}

# ── Auto-assign host port ────────────────────────────────────────────────
if ($HostPort -eq 0) {
    # Scan existing expedition compose files for used ports
    $usedPorts = @(8420) # wildroot is known
    Get-ChildItem $ExpeditionsDir -Recurse -Filter "docker-compose.yml" -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $portMatches = [regex]::Matches($content, '"(\d{4,5}):\d+"')
        foreach ($m in $portMatches) {
            $usedPorts += [int]$m.Groups[1].Value
        }
    }
    # Find first available in 8400-8499
    for ($p = 8400; $p -le 8499; $p++) {
        if ($p -notin $usedPorts) {
            $HostPort = $p
            break
        }
    }
    if ($HostPort -eq 0) { $HostPort = 8450 }
    Write-Info "Auto-assigned host port: $HostPort"
}

# ══════════════════════════════════════════════════════════════════════════
# Create directory structure
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Scaffolding Directory"

$dirs = @($BackendDir)
if ($Stack -eq "fastapi") { $dirs += Join-Path $BackendDir "app"; $dirs += Join-Path $BackendDir "app/auth" }
if ($Stack -eq "express") { $dirs += Join-Path $BackendDir "src" }

foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Step "Created: $d"
    }
}

$containerName = "$Name-backend"
$dbContainerName = "$Name-db"
$dbPassword = "$Name-secret-$(Get-Date -Format 'yyyy')"
$sharedNetworkName = 'aitheros-fresh_aither-network'

# Detect actual shared network name
$existingNets = docker network ls --format '{{.Name}}' 2>&1
$detected = $existingNets | Where-Object { $_ -match 'aither.*network' } | Select-Object -First 1
if ($detected) { $sharedNetworkName = $detected }

# ══════════════════════════════════════════════════════════════════════════
# Generate docker-compose.yml
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Generating docker-compose.yml"

$composeYaml = @"
services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: $containerName
    ports:
      - "${HostPort}:${Port}"
    environment:
      - DATABASE_URL=postgresql+asyncpg://${Name}:${dbPassword}@db:5432/${Name}
      - SECRET_KEY=change-me-in-production-$(New-Guid)
      - JWT_ALGORITHM=HS256
      - ACCESS_TOKEN_EXPIRE_MINUTES=60
      - PUBLIC_BASE_URL=https://$(if ($Hostname) { ($Hostname -split ',')[0].Trim() } else { 'localhost' })
      - CORS_ORIGINS=["https://$(if ($Hostname) { ($Hostname -split ',')[0].Trim() } else { 'localhost' })","http://localhost:${HostPort}"]
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${Port}${Hostname ? '/health' : '/health'}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    restart: unless-stopped
    networks:
      - ${Name}-net
      - aither-shared-net

  db:
    image: postgres:15-alpine
    container_name: $dbContainerName
    volumes:
      - ${Name}_pgdata:/var/lib/postgresql/data
    environment:
      POSTGRES_USER: $Name
      POSTGRES_PASSWORD: $dbPassword
      POSTGRES_DB: $Name
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $Name"]
      interval: 5s
      timeout: 3s
      retries: 10
    restart: unless-stopped
    networks:
      - ${Name}-net

volumes:
  ${Name}_pgdata:

networks:
  ${Name}-net:
    driver: bridge
  aither-shared-net:
    external: true
    name: `${AITHER_SHARED_NETWORK:-$sharedNetworkName}
"@

# Fix the template literal issue in YAML
$composeYaml = $composeYaml -replace 'healthcheck:.+?test:.+?\n', ''

Set-Content -Path (Join-Path $BackendDir "docker-compose.yml") -Value $composeYaml -Encoding UTF8
Write-Good "docker-compose.yml created"

# ══════════════════════════════════════════════════════════════════════════
# Generate stack-specific files
# ══════════════════════════════════════════════════════════════════════════
Write-Title "Generating $Stack boilerplate"

switch ($Stack) {
    "fastapi" {
        # Dockerfile
        @"
FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE $Port
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "$Port"]
"@ | Set-Content (Join-Path $BackendDir "Dockerfile") -Encoding UTF8

        # requirements.txt
        @"
fastapi>=0.100.0
uvicorn[standard]>=0.22.0
sqlalchemy[asyncio]>=2.0
asyncpg>=0.28.0
alembic>=1.11.0
pydantic>=2.0
pydantic-settings>=2.0
python-jose[cryptography]>=3.3.0
passlib[bcrypt]>=1.7.4
python-multipart>=0.0.6
httpx>=0.24.0
"@ | Set-Content (Join-Path $BackendDir "requirements.txt") -Encoding UTF8

        # app/main.py
        @"
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import os

app = FastAPI(title="$Name API", version="1.0.0")

origins = os.getenv("CORS_ORIGINS", '["http://localhost:3000"]')
import json
try:
    origins = json.loads(origins)
except:
    origins = ["http://localhost:3000"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {"message": "Welcome to $Name API", "version": "1.0.0"}

@app.get("/health")
async def health():
    return {"status": "healthy"}
"@ | Set-Content (Join-Path $BackendDir "app/main.py") -Encoding UTF8

        # app/__init__.py
        "" | Set-Content (Join-Path $BackendDir "app/__init__.py") -Encoding UTF8

        Write-Good "FastAPI boilerplate generated"
    }

    "express" {
        # Dockerfile
        @"
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY . .
EXPOSE $Port
CMD ["node", "src/index.js"]
"@ | Set-Content (Join-Path $BackendDir "Dockerfile") -Encoding UTF8

        # package.json
        @"
{
  "name": "$Name-backend",
  "version": "1.0.0",
  "scripts": { "start": "node src/index.js", "dev": "nodemon src/index.js" },
  "dependencies": {
    "express": "^4.18.0",
    "cors": "^2.8.5",
    "pg": "^8.11.0",
    "dotenv": "^16.3.0"
  }
}
"@ | Set-Content (Join-Path $BackendDir "package.json") -Encoding UTF8

        # src/index.js
        @"
const express = require('express');
const cors = require('cors');
const app = express();
const PORT = process.env.PORT || $Port;

app.use(cors());
app.use(express.json());

app.get('/', (req, res) => res.json({ message: 'Welcome to $Name API', version: '1.0.0' }));
app.get('/health', (req, res) => res.json({ status: 'healthy' }));

app.listen(PORT, '0.0.0.0', () => console.log('$Name running on port ' + PORT));
"@ | Set-Content (Join-Path $BackendDir "src/index.js") -Encoding UTF8

        Write-Good "Express boilerplate generated"
    }

    "static" {
        # Dockerfile
        @"
FROM nginx:alpine
COPY public/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE $Port
"@ | Set-Content (Join-Path $BackendDir "Dockerfile") -Encoding UTF8

        New-Item -ItemType Directory -Path (Join-Path $BackendDir "public") -Force | Out-Null
        "<html><body><h1>$Name</h1></body></html>" | Set-Content (Join-Path $BackendDir "public/index.html") -Encoding UTF8

        @"
server {
    listen $Port;
    location / { root /usr/share/nginx/html; try_files `$uri `$uri/ /index.html; }
    location /health { return 200 '{"status":"healthy"}'; add_header Content-Type application/json; }
}
"@ | Set-Content (Join-Path $BackendDir "nginx.conf") -Encoding UTF8

        Write-Good "Static/Nginx boilerplate generated"
    }

    "custom" {
        Write-Info "Custom stack — empty compose created. Add your own Dockerfile."
    }
}

# ── .env.example ──────────────────────────────────────────────────────────
@"
# $Name Environment Variables
DATABASE_URL=postgresql+asyncpg://${Name}:${dbPassword}@db:5432/${Name}
SECRET_KEY=change-me-in-production
PUBLIC_BASE_URL=https://$(if ($Hostname) { ($Hostname -split ',')[0].Trim() } else { 'localhost' })
AITHER_SHARED_NETWORK=$sharedNetworkName
"@ | Set-Content (Join-Path $BackendDir ".env.example") -Encoding UTF8

# ── .gitignore ────────────────────────────────────────────────────────────
@"
.env
__pycache__/
*.pyc
node_modules/
.venv/
"@ | Set-Content (Join-Path $BackendDir ".gitignore") -Encoding UTF8

# ── README.md ─────────────────────────────────────────────────────────────
@"
# $Name

**Stack:** $Stack
**Port:** $HostPort (host) → $Port (container)
$(if ($Hostname) { "**Domain:** $Hostname" })

## Quick Start

``````bash
cd expeditions/$Name/backend
docker compose up -d --build
``````

## Deploy to Tunnel

``````bash
pwsh AitherZero/library/automation-scripts/30-deploy/3060_Deploy-Expedition.ps1 \
  -Name $Name \
  -Hostname "$Hostname" \
  -Service "http://${containerName}:${Port}"
``````
"@ | Set-Content (Join-Path $ExpDir "README.md") -Encoding UTF8

Write-Good "Scaffold complete: $ExpDir"

# ══════════════════════════════════════════════════════════════════════════
# Optionally deploy immediately
# ══════════════════════════════════════════════════════════════════════════
if ($Deploy -and $Hostname) {
    Write-Title "Auto-deploying via 3060_Deploy-Expedition.ps1"
    $deployScript = Join-Path $PSScriptRoot "3060_Deploy-Expedition.ps1"
    & $deployScript -Name $Name -Hostname $Hostname -Service "http://${containerName}:${Port}" -Build -Force
} elseif ($Deploy -and -not $Hostname) {
    Write-Info "Cannot auto-deploy without -Hostname. Run 3060_Deploy-Expedition.ps1 manually."
}

Write-Title "Done"
Write-Host ""
Write-Host "  Created: $ExpDir" -ForegroundColor Green
Write-Host "  Next:    3060_Deploy-Expedition.ps1 -Name $Name -Hostname <domain> -Service http://${containerName}:$Port" -ForegroundColor Cyan
Write-Host ""

exit 0
