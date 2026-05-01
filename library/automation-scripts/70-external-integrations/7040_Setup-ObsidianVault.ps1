<#
.SYNOPSIS
    Easy-button Obsidian + AitherOS plugin deployment.
    Auto-detects vault, builds/installs plugin, seeds config, scaffolds folders, loads data.

.DESCRIPTION
    One command to get a fully wired Obsidian vault connected to AitherOS:
    1. Auto-detect Obsidian vault (or create one)
    2. Build the obsidian-aitheros plugin from source
    3. Install + auto-enable the plugin
    4. Seed plugin settings (data.json) with correct ports/folders
    5. Scaffold vault folder structure (Wiki, KnowledgeGraph, Memories, Scope)
    6. Optionally sync existing data from LyraWiki, KG, MemoryHub
    7. Restart Obsidian to pick up everything

.PARAMETER VaultPath
    Explicit vault path. If not set, auto-detects from Obsidian config or uses repo root.

.PARAMETER SyncData
    Pull existing wiki/KG/memory data into the vault after install.

.PARAMETER SkipBuild
    Skip npm install + build (use existing main.js).

.PARAMETER SkipRestart
    Don't restart Obsidian after install.

.PARAMETER CreateVault
    Create a new vault at the specified path if it doesn't exist.

.PARAMETER BaseUrl
    AitherOS host (default: localhost).

.PARAMETER ApiKey
    API key for authenticated access. If empty, tries AitherSecrets vault.

.EXAMPLE
    # Simplest — auto-detect everything
    pwsh -File 7040_Setup-ObsidianVault.ps1

    # Point at a specific vault + sync data
    pwsh -File 7040_Setup-ObsidianVault.ps1 -VaultPath "D:\MyVault" -SyncData

    # From npm shortcut
    npm run setup:obsidian
    npm run setup:obsidian -- -SyncData
#>

[CmdletBinding()]
param(
    [string]$VaultPath,
    [switch]$SyncData,
    [switch]$SkipBuild,
    [switch]$SkipRestart,
    [switch]$CreateVault,
    [string]$BaseUrl = "localhost",
    [string]$ApiKey
)

$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# ─── Resolve paths ────────────────────────────────────────────────────────
$repoRoot   = (Get-Item "$PSScriptRoot/../../../../").FullName
$pluginSrc  = Join-Path $repoRoot "AitherOS/apps/obsidian-aitheros"

function Write-Step  { param([string]$m) Write-Host "`n━━━ $m ━━━" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "  ✅ $m" -ForegroundColor Green }
function Write-Fail  { param([string]$m) Write-Host "  ❌ $m" -ForegroundColor Red }
function Write-Info  { param([string]$m) Write-Host "  ℹ️  $m" -ForegroundColor Yellow }
function Write-Dim   { param([string]$m) Write-Host "     $m" -ForegroundColor DarkGray }

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0: Auto-detect or create Obsidian vault
# ═══════════════════════════════════════════════════════════════════════════
Write-Step "STEP 0: Locate Obsidian Vault"

if (-not $VaultPath) {
    # Try reading Obsidian's own config to find vaults
    $obsConfig = $null
    $obsConfigPaths = @(
        "$env:APPDATA/obsidian/obsidian.json",                         # Windows
        "$env:HOME/.config/obsidian/obsidian.json",                    # Linux
        "$env:HOME/Library/Application Support/obsidian/obsidian.json"  # macOS
    )

    foreach ($p in $obsConfigPaths) {
        if (Test-Path $p) {
            try {
                $obsConfig = Get-Content $p -Raw | ConvertFrom-Json
                Write-Info "Found Obsidian config at: $p"
                break
            } catch { }
        }
    }

    if ($obsConfig -and $obsConfig.vaults) {
        # Pick the first open vault, or first vault overall
        $vaultEntries = $obsConfig.vaults.PSObject.Properties
        $picked = $vaultEntries | Where-Object { $_.Value.open -eq $true } | Select-Object -First 1
        if (-not $picked) { $picked = $vaultEntries | Select-Object -First 1 }

        if ($picked -and $picked.Value.path) {
            $VaultPath = $picked.Value.path
            Write-Ok "Auto-detected vault: $VaultPath"
        }
    }

    # Fallback: use repo root (it has .obsidian/ already)
    if (-not $VaultPath) {
        if (Test-Path "$repoRoot/.obsidian") {
            $VaultPath = $repoRoot
            Write-Info "Using repo root as vault (has .obsidian/): $VaultPath"
        } else {
            $VaultPath = Join-Path $repoRoot "AitherVault"
            $CreateVault = $true
            Write-Info "No vault found. Will create: $VaultPath"
        }
    }
}

# Create vault if needed
if ($CreateVault -or -not (Test-Path "$VaultPath/.obsidian")) {
    Write-Info "Creating vault structure at: $VaultPath"
    New-Item -ItemType Directory -Path "$VaultPath/.obsidian/plugins" -Force | Out-Null
    # Create minimal app.json
    @{ livePreview = $true; theme = "obsidian" } | ConvertTo-Json | Set-Content "$VaultPath/.obsidian/app.json" -Encoding UTF8
    Write-Ok "Vault created: $VaultPath"
}

$pluginDest = Join-Path $VaultPath ".obsidian/plugins/obsidian-aitheros"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Build plugin
# ═══════════════════════════════════════════════════════════════════════════
Write-Step "STEP 1: Build Obsidian Plugin"

if (-not $SkipBuild) {
    Push-Location $pluginSrc
    try {
        if (-not (Test-Path "node_modules")) {
            Write-Info "Installing npm dependencies..."
            npm install --silent 2>&1 | Out-Null
        }
        Write-Info "Building plugin..."
        node esbuild.config.mjs production 2>&1

        if (Test-Path "main.js") {
            $sz = (Get-Item "main.js").Length
            Write-Ok "Built main.js ($sz bytes)"
        } else {
            Write-Fail "Build failed — main.js not found"
            exit 1
        }
    } finally {
        Pop-Location
    }
} else {
    if (Test-Path "$pluginSrc/main.js") {
        Write-Info "Skipping build — using existing main.js"
    } else {
        Write-Fail "No main.js found and -SkipBuild set. Run without -SkipBuild."
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Install plugin files
# ═══════════════════════════════════════════════════════════════════════════
Write-Step "STEP 2: Install Plugin to Vault"

New-Item -ItemType Directory -Path $pluginDest -Force | Out-Null
foreach ($f in @("manifest.json", "main.js", "styles.css")) {
    $src = Join-Path $pluginSrc $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $pluginDest $f) -Force
        Write-Dim "$f → $(Join-Path $pluginDest $f)"
    }
}
Write-Ok "Plugin files installed"

# Auto-enable in community-plugins.json
$cpJson = Join-Path $VaultPath ".obsidian/community-plugins.json"
$plugins = @()
if (Test-Path $cpJson) {
    try { $plugins = @(Get-Content $cpJson -Raw | ConvertFrom-Json) } catch { $plugins = @() }
}
if ($plugins -notcontains "obsidian-aitheros") {
    $plugins += "obsidian-aitheros"
}
ConvertTo-Json @($plugins) | Set-Content $cpJson -Encoding UTF8
Write-Ok "Plugin auto-enabled in community-plugins.json"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Seed plugin settings (data.json)
# ═══════════════════════════════════════════════════════════════════════════
Write-Step "STEP 3: Seed Plugin Settings"

# Resolve API key: param → env → AitherSecrets → empty
if (-not $ApiKey) {
    $ApiKey = $env:AITHER_API_KEY
}
if (-not $ApiKey) {
    try {
        $secretResp = Invoke-RestMethod -Uri "http://${BaseUrl}:8115/api/v1/secrets/get" `
            -Method POST -ContentType "application/json" `
            -Body '{"key":"obsidian_api_key"}' -TimeoutSec 5 -ErrorAction Stop
        if ($secretResp.value) { $ApiKey = $secretResp.value }
    } catch { }
}

$settings = @{
    baseUrl              = $BaseUrl
    lyraWikiPort         = 8270
    knowledgeGraphPort   = 8196
    memoryHubPort        = 8185
    genesisPort          = 8100
    apiKey               = if ($ApiKey) { $ApiKey } else { "" }
    useTLS               = $false
    syncFolder           = "AitherOS/Wiki"
    memoriesFolder       = "AitherOS/Memories"
    kgFolder             = "AitherOS/KnowledgeGraph"
    scopeFolder          = "AitherOS/Scope"
    defaultProject       = "default"
    autoSync             = $true
    syncIntervalMinutes  = 30
}

$dataJsonPath = Join-Path $pluginDest "data.json"
$settings | ConvertTo-Json -Depth 3 | Set-Content $dataJsonPath -Encoding UTF8
Write-Ok "Settings seeded at: $dataJsonPath"
if ($ApiKey) { Write-Ok "API key configured" } else { Write-Info "No API key found — set it in Obsidian settings" }

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Scaffold vault folders
# ═══════════════════════════════════════════════════════════════════════════
Write-Step "STEP 4: Scaffold Vault Folders"

$folders = @(
    "AitherOS/Wiki",
    "AitherOS/KnowledgeGraph",
    "AitherOS/Memories",
    "AitherOS/Scope",
    "AitherOS/Agents",
    "AitherOS/Notebooks"
)

foreach ($dir in $folders) {
    $full = Join-Path $VaultPath $dir
    if (-not (Test-Path $full)) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Write-Dim "Created: $dir/"
    }
}

# Drop a welcome note
$welcomePath = Join-Path $VaultPath "AitherOS/Welcome.md"
if (-not (Test-Path $welcomePath)) {
    @"
# 🧠 AitherOS Knowledge Vault

Welcome to your AitherOS-connected Obsidian vault.

## Folder Structure

| Folder | Purpose |
|--------|---------|
| ``Wiki/`` | LyraWiki pages synced as markdown |
| ``KnowledgeGraph/`` | Knowledge graph entities as linked notes |
| ``Memories/`` | AitherGraph memory entries |
| ``Scope/`` | AitherScope codebase analysis exports |
| ``Agents/`` | Agent configs and playbooks |
| ``Notebooks/`` | Shared computation notebooks |

## Quick Start

1. **Ctrl+P** → ``AitherOS: Check Service Health`` — verify connections
2. **Ctrl+P** → ``AitherOS: Sync Wiki Pages`` — pull wiki content
3. Click the 🧠 **brain icon** in the left ribbon → open the Graph Explorer
4. Click the 🔍 **scan-eye icon** → open AitherScope (codebase visualization)

## Connection

- **Services:** http://$BaseUrl (ports auto-configured)
- **API Key:** $(if ($ApiKey) { "Configured ✅" } else { "Set in plugin settings" })
- **AitherShell:** ``aither --init`` to connect via CLI
"@ | Set-Content $welcomePath -Encoding UTF8
    Write-Ok "Created Welcome.md"
}

Write-Ok "Vault scaffolded with $($folders.Count) folders"

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Sync data (if requested)
# ═══════════════════════════════════════════════════════════════════════════
if ($SyncData) {
    Write-Step "STEP 5: Sync Data from AitherOS"

    $wikiDir = Join-Path $VaultPath "AitherOS/Wiki"
    $kgDir   = Join-Path $VaultPath "AitherOS/KnowledgeGraph"
    $memDir  = Join-Path $VaultPath "AitherOS/Memories"

    # 5a: LyraWiki pages
    Write-Info "Pulling LyraWiki pages..."
    try {
        $pages = Invoke-RestMethod -Uri "http://${BaseUrl}:8270/graph/obsidian?project=default" -TimeoutSec 15 -ErrorAction Stop
        if ($pages.pages) {
            $count = 0
            foreach ($page in $pages.pages) {
                $fname = ($page.title -replace '[\\/:*?"<>|]', '_') + ".md"
                $page.content | Set-Content (Join-Path $wikiDir $fname) -Encoding UTF8
                $count++
            }
            Write-Ok "Synced $count wiki pages"
        } else {
            Write-Info "No wiki pages found (empty knowledge base)"
        }
    } catch {
        Write-Info "LyraWiki not reachable — skipping wiki sync"
    }

    # 5b: KnowledgeGraph entities
    Write-Info "Pulling KnowledgeGraph entities..."
    try {
        $entities = Invoke-RestMethod -Uri "http://${BaseUrl}:8196/api/v1/entities?limit=500" -TimeoutSec 15 -ErrorAction Stop
        if ($entities.entities) {
            $count = 0
            foreach ($e in $entities.entities) {
                $fname = ($e.name -replace '[\\/:*?"<>|]', '_') + ".md"
                $body = "---`ntags: [$($e.type)]`n---`n# $($e.name)`n`n$($e.description)`n"
                if ($e.connections) {
                    $body += "`n## Connections`n"
                    foreach ($c in $e.connections) { $body += "- [[$($c.target)]] ($($c.type))`n" }
                }
                $body | Set-Content (Join-Path $kgDir $fname) -Encoding UTF8
                $count++
            }
            Write-Ok "Synced $count KG entities"
        }
    } catch {
        Write-Info "KnowledgeGraph not reachable — skipping KG sync"
    }

    # 5c: Memories
    Write-Info "Pulling recent memories..."
    try {
        $memories = Invoke-RestMethod -Uri "http://${BaseUrl}:8185/api/v1/memories?limit=100" -TimeoutSec 15 -ErrorAction Stop
        if ($memories.memories) {
            $count = 0
            foreach ($m in $memories.memories) {
                $fname = "memory_$($m.id).md"
                $body = "---`ntags: [memory, $($m.type)]`ncreated: $($m.created_at)`n---`n# $($m.summary)`n`n$($m.content)`n"
                $body | Set-Content (Join-Path $memDir $fname) -Encoding UTF8
                $count++
            }
            Write-Ok "Synced $count memories"
        }
    } catch {
        Write-Info "MemoryHub not reachable — skipping memory sync"
    }
} else {
    Write-Info "Skipping data sync (use -SyncData to pull wiki/KG/memories)"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: Restart Obsidian
# ═══════════════════════════════════════════════════════════════════════════
if (-not $SkipRestart) {
    Write-Step "STEP 6: Restart Obsidian"

    $vaultName = Split-Path $VaultPath -Leaf
    $obsProc = Get-Process -Name "Obsidian" -ErrorAction SilentlyContinue

    if ($obsProc) {
        Write-Info "Stopping Obsidian..."
        $obsProc | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    Write-Info "Launching Obsidian vault: $vaultName"
    Start-Process "obsidian://open?vault=$vaultName"
    Start-Sleep -Seconds 3

    $newObs = Get-Process -Name "Obsidian" -ErrorAction SilentlyContinue
    if ($newObs) {
        Write-Ok "Obsidian launched with plugin active"
    } else {
        Write-Info "Obsidian may still be starting..."
    }
} else {
    Write-Info "Skipping restart (use Ctrl+P → Reload in Obsidian)"
}

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  🚀 OBSIDIAN + AITHEROS — READY" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Vault:       $VaultPath" -ForegroundColor White
Write-Host "  Plugin:      $pluginDest" -ForegroundColor White
Write-Host "  Settings:    $dataJsonPath" -ForegroundColor White
Write-Host "  API Key:     $(if ($ApiKey) { 'Configured ✅' } else { '⚠️  Set in plugin settings' })" -ForegroundColor White
Write-Host ""
Write-Host "  COMMANDS (Ctrl+P):" -ForegroundColor Yellow
Write-Dim "  🧠 Brain icon            → Graph Explorer (wiki + KG + memories)"
Write-Dim "  🔍 Scan-eye icon         → AitherScope (codebase visualization)"
Write-Dim "  AitherOS: Sync Wiki      → Pull LyraWiki → markdown notes"
Write-Dim "  AitherOS: Sync KG        → Pull KnowledgeGraph → linked notes"
Write-Dim "  AitherOS: Sync Memories  → Pull MemoryHub → memory notes"
Write-Dim "  AitherOS: Ingest Wikipedia → Add articles to knowledge base"
Write-Host ""
Write-Host "  ALSO AVAILABLE:" -ForegroundColor Yellow
Write-Dim "  aither --init            → Connect CLI (AitherShell)"
Write-Dim "  npm run setup:obsidian   → Re-run this script"
Write-Dim "  npm run setup:obsidian -- -SyncData  → Sync all data"
Write-Host ""
