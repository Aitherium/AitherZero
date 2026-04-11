#Requires -Version 7.0
<#
.SYNOPSIS
    Sets up GitHub Agentic Workflows (gh-aw) with all required secrets and compiled workflows.

.DESCRIPTION
    Automated first-time setup for GitHub Agentic Workflows:
    1. Installs/updates the gh-aw CLI extension
    2. Validates COPILOT_GITHUB_TOKEN secret (creates PAT link if missing)
    3. Validates AITHERIUM_API_KEY secret (generates + registers in ACTA if missing)
    4. Compiles all .md workflows to .lock.yml
    5. Optionally runs a connectivity test

    This script is idempotent — safe to run multiple times.

.PARAMETER Repo
    GitHub repository in owner/repo format. Default: auto-detected from git remote.

.PARAMETER CompileOnly
    Only compile workflows, skip secret validation.

.PARAMETER TestRun
    After setup, trigger the test-aitherium-mcp workflow to verify connectivity.

.PARAMETER Force
    Skip confirmation prompts.

.PARAMETER NonInteractive
    Run in CI mode — skip anything requiring user input, fail on missing secrets.

.PARAMETER DryRun
    Show what would be done without making changes.

.EXAMPLE
    .\0708_Setup-AgenticWorkflows.ps1

.EXAMPLE
    .\0708_Setup-AgenticWorkflows.ps1 -TestRun -Force

.EXAMPLE
    .\0708_Setup-AgenticWorkflows.ps1 -CompileOnly

.NOTES
    Category: git
    Script: 0708
    Stage: Development
    Order: 8
    Dependencies: GitHub CLI (gh), git
    Tags: agentic, gh-aw, copilot, mcp, workflows
    AllowParallel: false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$Repo,

    [switch]$CompileOnly,
    [switch]$TestRun,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step  { param([string]$Msg) Write-Host "  ▸ $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }

function Test-CommandExists {
    param([string]$Name)
    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ── Pre-flight ───────────────────────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  GitHub Agentic Workflows — First-Time Setup" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Magenta

# Verify gh CLI
if (-not (Test-CommandExists 'gh')) {
    Write-Fail "GitHub CLI (gh) not found. Install: https://cli.github.com"
    Write-Info "Or run: winget install GitHub.cli"
    exit 1
}

# Verify gh auth
$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail "GitHub CLI not authenticated. Run: gh auth login"
    exit 1
}
Write-Ok "GitHub CLI authenticated"

# Auto-detect repo
if (-not $Repo) {
    $remoteUrl = git remote get-url origin 2>$null
    if ($remoteUrl -match 'github\.com[:/](.+?)(?:\.git)?$') {
        $Repo = $Matches[1]
    } else {
        Write-Fail "Cannot detect GitHub repository. Pass -Repo owner/name explicitly."
        exit 1
    }
}
Write-Ok "Repository: $Repo"

# ── Phase 1: Install gh-aw extension ────────────────────────────────────────

Write-Host "`n─── Phase 1: gh-aw CLI Extension ───" -ForegroundColor White

$awInstalled = $false
try {
    $awVersion = gh aw version 2>$null
    if ($LASTEXITCODE -eq 0 -and $awVersion) { $awInstalled = $true }
} catch { }

if ($awInstalled) {
    Write-Ok "gh-aw already installed: $($awVersion -replace '\n','' | Select-Object -First 1)"

    # Check for updates
    if (-not $DryRun) {
        Write-Step "Checking for updates..."
        $upgradeResult = gh extension upgrade github/gh-aw 2>&1
        if ($upgradeResult -match 'upgraded|updated') {
            Write-Ok "gh-aw updated"
        } else {
            Write-Info "Already at latest version"
        }
    }
} else {
    Write-Step "Installing gh-aw extension..."
    if ($DryRun) {
        Write-Info "[DryRun] Would run: gh extension install github/gh-aw"
    } else {
        gh extension install github/gh-aw 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to install gh-aw. Check: https://github.github.com/gh-aw/setup/quick-start/"
            exit 1
        }
        Write-Ok "gh-aw installed successfully"
    }
}

# ── Phase 2: Validate secrets ───────────────────────────────────────────────

if (-not $CompileOnly) {
    Write-Host "`n─── Phase 2: Repository Secrets ───" -ForegroundColor White

    # Get current secrets
    $existingSecrets = gh secret list --repo $Repo 2>&1
    $secretNames = @()
    if ($existingSecrets -is [array]) {
        $secretNames = $existingSecrets | ForEach-Object { ($_ -split '\s+')[0] }
    } elseif ($existingSecrets -is [string]) {
        $secretNames = $existingSecrets -split "`n" | ForEach-Object { ($_ -split '\s+')[0] }
    }

    # ── 2a: COPILOT_GITHUB_TOKEN ──
    Write-Step "Checking COPILOT_GITHUB_TOKEN..."

    if ($secretNames -contains 'COPILOT_GITHUB_TOKEN') {
        Write-Ok "COPILOT_GITHUB_TOKEN is set"
    } else {
        Write-Warn "COPILOT_GITHUB_TOKEN is NOT set — required for Copilot coding agent"

        if ($NonInteractive) {
            Write-Fail "Missing COPILOT_GITHUB_TOKEN. Cannot proceed in non-interactive mode."
            Write-Info "Set it manually: gh aw secrets set COPILOT_GITHUB_TOKEN --value <PAT>"
            exit 1
        }

        # Guide the user through PAT creation
        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor Yellow
        Write-Host "  │  A fine-grained GitHub PAT is needed with:               │" -ForegroundColor Yellow
        Write-Host "  │    • Resource owner: YOUR personal account               │" -ForegroundColor Yellow
        Write-Host "  │    • Account permissions → Copilot Requests: Read        │" -ForegroundColor Yellow
        Write-Host "  │                                                          │" -ForegroundColor Yellow
        Write-Host "  │  Opening the pre-filled token creation page...           │" -ForegroundColor Yellow
        Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor Yellow
        Write-Host ""

        # Open browser to pre-filled PAT creation
        $patUrl = "https://github.com/settings/personal-access-tokens/new?name=COPILOT_GITHUB_TOKEN&description=GitHub+Agentic+Workflows+-+Copilot+engine+authentication&user_copilot_requests=read"

        if (-not $DryRun) {
            try {
                if ($IsWindows -or $env:OS -match 'Windows') {
                    Start-Process $patUrl
                } elseif ($IsMacOS) {
                    open $patUrl
                } else {
                    xdg-open $patUrl 2>$null
                }
                Write-Info "Browser opened. Create the token, then paste it below."
            } catch {
                Write-Info "Open this URL manually: $patUrl"
            }

            Write-Host ""
            $copilotToken = Read-Host "  Paste your COPILOT_GITHUB_TOKEN (or press Enter to skip)"

            if ($copilotToken -and $copilotToken.Trim() -ne '') {
                $copilotToken | gh secret set COPILOT_GITHUB_TOKEN --repo $Repo 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "COPILOT_GITHUB_TOKEN saved as repository secret"
                } else {
                    Write-Fail "Failed to set COPILOT_GITHUB_TOKEN secret"
                }
            } else {
                Write-Warn "Skipped — Copilot engine workflows will fail until this is set"
                Write-Info "Set later: gh aw secrets set COPILOT_GITHUB_TOKEN --value <PAT>"
            }
        } else {
            Write-Info "[DryRun] Would open browser and prompt for COPILOT_GITHUB_TOKEN"
        }
    }

    # ── 2b: AITHERIUM_API_KEY ──
    Write-Step "Checking AITHERIUM_API_KEY..."

    if ($secretNames -contains 'AITHERIUM_API_KEY') {
        Write-Ok "AITHERIUM_API_KEY is set"
    } else {
        Write-Warn "AITHERIUM_API_KEY is NOT set — required for Aitherium MCP tools"

        if ($NonInteractive) {
            Write-Fail "Missing AITHERIUM_API_KEY. Cannot proceed in non-interactive mode."
            Write-Info "Set it manually: gh secret set AITHERIUM_API_KEY --value <key>"
            exit 1
        }

        # Try to generate via ACTA if it's reachable
        $actaKey = $null
        $actaUrl = $env:AITHER_ACTA_URL
        if (-not $actaUrl) { $actaUrl = "http://localhost:8185" }

        Write-Step "Trying to generate API key via ACTA ($actaUrl)..."

        try {
            $registerPayload = @{
                username = "gh-aw-agent"
                email    = "agentic@aitherium.com"
                plan     = "pro"
            } | ConvertTo-Json

            $response = Invoke-RestMethod -Uri "$actaUrl/v1/auth/register" `
                -Method POST `
                -Body $registerPayload `
                -ContentType "application/json" `
                -TimeoutSec 5 `
                -ErrorAction Stop

            if ($response.api_key) {
                $actaKey = $response.api_key
                Write-Ok "Generated ACTA API key: $($actaKey.Substring(0,20))..."
            }
        } catch {
            Write-Info "ACTA not reachable locally — will use manual entry"
        }

        # Try mcp.aitherium.com registration endpoint
        if (-not $actaKey) {
            try {
                $response = Invoke-RestMethod -Uri "https://mcp.aitherium.com/v1/auth/register" `
                    -Method POST `
                    -Body (@{ username = "gh-aw-agent"; email = "agentic@aitherium.com"; plan = "pro" } | ConvertTo-Json) `
                    -ContentType "application/json" `
                    -TimeoutSec 10 `
                    -ErrorAction Stop

                if ($response.api_key) {
                    $actaKey = $response.api_key
                    Write-Ok "Generated API key via mcp.aitherium.com"
                }
            } catch {
                Write-Info "Remote ACTA not reachable — manual entry required"
            }
        }

        if ($actaKey) {
            # Auto-set the secret
            if (-not $DryRun) {
                $actaKey | gh secret set AITHERIUM_API_KEY --repo $Repo 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "AITHERIUM_API_KEY saved as repository secret"
                } else {
                    Write-Fail "Failed to set AITHERIUM_API_KEY secret"
                }

                # Also set as environment variable for local use
                [System.Environment]::SetEnvironmentVariable('AITHERIUM_API_KEY', $actaKey, 'User')
                Write-Ok "Also set as User environment variable"
            } else {
                Write-Info "[DryRun] Would set AITHERIUM_API_KEY from ACTA response"
            }
        } else {
            # Manual entry
            Write-Host ""
            Write-Host "  Enter an existing Aitherium API key, or press Enter to skip." -ForegroundColor Yellow
            Write-Host "  Keys start with: aither_sk_live_..." -ForegroundColor DarkGray
            Write-Host ""

            $manualKey = Read-Host "  AITHERIUM_API_KEY"

            if ($manualKey -and $manualKey.Trim() -ne '') {
                if (-not $DryRun) {
                    $manualKey | gh secret set AITHERIUM_API_KEY --repo $Repo 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok "AITHERIUM_API_KEY saved as repository secret"
                    } else {
                        Write-Fail "Failed to set AITHERIUM_API_KEY secret"
                    }
                }
            } else {
                Write-Warn "Skipped — Aitherium MCP workflows will fail until this is set"
                Write-Info "Set later: gh secret set AITHERIUM_API_KEY --value <key>"
            }
        }
    }

    # ── 2c: Optional engine secrets ──
    Write-Step "Checking optional engine secrets..."

    $optionalSecrets = @(
        @{ Name = 'ANTHROPIC_API_KEY'; Engine = 'Claude'; Desc = 'Claude Code engine' },
        @{ Name = 'OPENAI_API_KEY';    Engine = 'Codex';  Desc = 'Codex engine' },
        @{ Name = 'GEMINI_API_KEY';    Engine = 'Gemini'; Desc = 'Gemini CLI engine' }
    )

    foreach ($sec in $optionalSecrets) {
        if ($secretNames -contains $sec.Name) {
            Write-Ok "$($sec.Name) is set ($($sec.Desc))"
        } else {
            # Check local env
            $localVal = [System.Environment]::GetEnvironmentVariable($sec.Name, 'User')
            if (-not $localVal) {
                $localVal = [System.Environment]::GetEnvironmentVariable($sec.Name, 'Process')
            }

            if ($localVal -and $localVal.Trim() -ne '') {
                Write-Step "Found $($sec.Name) in local environment, syncing to GitHub..."
                if (-not $DryRun) {
                    $localVal | gh secret set $sec.Name --repo $Repo 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Ok "$($sec.Name) synced from local env to GitHub"
                    }
                } else {
                    Write-Info "[DryRun] Would sync $($sec.Name) from local env"
                }
            } else {
                Write-Info "$($sec.Name) not set (optional — $($sec.Desc))"
            }
        }
    }
}

# ── Phase 3: Compile workflows ──────────────────────────────────────────────

Write-Host "`n─── Phase 3: Compile Workflows ───" -ForegroundColor White

# Find .md workflow files
$workflowDir = Join-Path (git rev-parse --show-toplevel 2>$null) ".github" "workflows"
if (-not (Test-Path $workflowDir)) {
    Write-Warn "No .github/workflows/ directory found"
} else {
    $mdFiles = Get-ChildItem -Path $workflowDir -Filter "*.md" -File 2>$null |
        Where-Object { $_.Name -ne 'README.md' }
    $lockFiles = Get-ChildItem -Path $workflowDir -Filter "*.lock.yml" -File 2>$null

    Write-Info "Found $($mdFiles.Count) workflow definition(s), $($lockFiles.Count) compiled lock file(s)"

    # Find workflows that need compilation (new or modified)
    $needsCompile = @()
    foreach ($md in $mdFiles) {
        $lockFile = Join-Path $workflowDir "$($md.BaseName).lock.yml"
        if (-not (Test-Path $lockFile)) {
            $needsCompile += $md.BaseName
        } elseif ($md.LastWriteTime -gt (Get-Item $lockFile).LastWriteTime) {
            $needsCompile += $md.BaseName
        }
    }

    if ($needsCompile.Count -eq 0) {
        Write-Ok "All workflows are up to date"
    } else {
        Write-Step "Compiling $($needsCompile.Count) workflow(s): $($needsCompile -join ', ')"

        foreach ($wf in $needsCompile) {
            if ($DryRun) {
                Write-Info "[DryRun] Would compile: $wf"
            } else {
                Write-Info "Compiling $wf..."
                $compileResult = gh aw compile $wf 2>&1
                if ($compileResult -match 'error') {
                    Write-Fail "Failed to compile $wf"
                    Write-Info ($compileResult | Out-String)
                } else {
                    Write-Ok "Compiled $wf"
                }
            }
        }

        # Stage compiled files
        if (-not $DryRun) {
            Write-Step "Staging compiled workflows..."
            $lockFiles = Get-ChildItem -Path $workflowDir -Filter "*.lock.yml" -File
            foreach ($lf in $lockFiles) {
                git add -f $lf.FullName 2>$null
            }
            Write-Ok "Lock files staged for commit"
        }
    }
}

# ── Phase 4: Test run ───────────────────────────────────────────────────────

if ($TestRun) {
    Write-Host "`n─── Phase 4: Test Run ───" -ForegroundColor White

    $testWorkflow = "test-aitherium-mcp"
    $testMd = Join-Path $workflowDir "$testWorkflow.md"

    if (-not (Test-Path $testMd)) {
        Write-Warn "Test workflow '$testWorkflow' not found — skipping test run"
    } else {
        if ($DryRun) {
            Write-Info "[DryRun] Would trigger: gh aw run $testWorkflow"
        } else {
            Write-Step "Triggering test workflow: $testWorkflow"

            # Ensure latest is pushed
            $currentBranch = git symbolic-ref --short HEAD 2>$null
            git push origin $currentBranch 2>$null

            $runResult = gh aw run $testWorkflow 2>&1
            $runUrl = $runResult | Select-String 'https://github.com' | Select-Object -ExpandProperty Line -First

            if ($runUrl) {
                Write-Ok "Test workflow triggered"
                Write-Info "Watch: $($runUrl.Trim())"
            } else {
                Write-Info ($runResult | Out-String)
            }
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host "  Setup Complete" -ForegroundColor Magenta
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host ""
Write-Info "Useful commands:"
Write-Host "  gh aw run <workflow>     " -ForegroundColor White -NoNewline; Write-Host "— Trigger a workflow" -ForegroundColor DarkGray
Write-Host "  gh aw compile <workflow> " -ForegroundColor White -NoNewline; Write-Host "— Recompile after edits" -ForegroundColor DarkGray
Write-Host "  gh aw list               " -ForegroundColor White -NoNewline; Write-Host "— List all workflows" -ForegroundColor DarkGray
Write-Host "  gh aw audit <run-id>     " -ForegroundColor White -NoNewline; Write-Host "— Analyze a workflow run" -ForegroundColor DarkGray
Write-Host "  gh aw secrets bootstrap  " -ForegroundColor White -NoNewline; Write-Host "— Interactive secret setup" -ForegroundColor DarkGray
Write-Host ""

exit 0
