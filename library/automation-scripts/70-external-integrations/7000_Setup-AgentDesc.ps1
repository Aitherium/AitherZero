<#
.SYNOPSIS
    Setup AgentDesc integration for AitherOS agents
    
.DESCRIPTION
    This script automates the setup process for integrating AitherOS with AgentDesc
    marketplace, allowing your agents to automatically earn money.
    
.PARAMETER Register
    Register a new agent on AgentDesc
    
.PARAMETER AgentName
    Name for your agent (default: AitherOS-Agent)
    
.PARAMETER Capabilities
    Comma-separated list of capabilities (default: coding,research,writing,data-analysis)
    
.PARAMETER ApiKey
    Your AgentDesc API key (if already registered)
    
.PARAMETER StartService
    Start the AitherSkills service after setup
    
.EXAMPLE
    # Register a new agent
    .\7000_Setup-AgentDesc.ps1 -Register -AgentName "MyAgent" -Capabilities "coding,research"
    
.EXAMPLE
    # Setup with existing API key
    .\7000_Setup-AgentDesc.ps1 -ApiKey "agentdesc_xxx..." -StartService
    
.EXAMPLE
    # Just start the service
    .\7000_Setup-AgentDesc.ps1 -StartService
#>

[CmdletBinding()]
param(
    [switch]$Register,
    [string]$AgentName = "AitherOS-Agent",
    [string]$Capabilities = "coding,research,writing,data-analysis,automation",
    [string]$ApiKey,
    [switch]$StartService
)

. "$PSScriptRoot/../_init.ps1"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          AgentDesc Integration Setup                       ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$envFile = Join-Path $projectRoot ".env"

# Check if already configured
$existingKey = $env:AGENTDESC_API_KEY
if (-not $existingKey -and (Test-Path $envFile)) {
    $envContent = Get-Content $envFile -Raw
    if ($envContent -match 'AGENTDESC_API_KEY=(.+)') {
        $existingKey = $matches[1].Trim()
    }
}

if ($existingKey -and -not $Register -and -not $ApiKey) {
    Write-Host "✓ AgentDesc API key already configured" -ForegroundColor Green
    Write-Host "  Key: $($existingKey.Substring(0, 20))..." -ForegroundColor Gray
    Write-Host ""
    
    $response = Read-Host "Do you want to reconfigure? (y/N)"
    if ($response -ne 'y') {
        if ($StartService) {
            goto StartServiceLabel
        } else {
            Write-Host "Setup complete. Run with -StartService to start the service." -ForegroundColor Yellow
            exit 0
        }
    }
}

# Step 1: Register Agent (if requested)
if ($Register) {
    Write-Host "[1/5] Registering agent on AgentDesc..." -ForegroundColor Cyan
    Write-Host "  Name: $AgentName" -ForegroundColor Gray
    Write-Host "  Capabilities: $Capabilities" -ForegroundColor Gray
    Write-Host ""
    
    $capsArray = $Capabilities -split ',' | ForEach-Object { $_.Trim() }
    $registrationBody = @{
        name = $AgentName
        description = "Multi-capable AI agent from AitherOS ecosystem"
        capabilities = $capsArray
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "https://agentdesc.com/api/agents/register" `
            -Method Post `
            -ContentType "application/json" `
            -Body $registrationBody `
            -ErrorAction Stop
        
        Write-Host "✓ Agent registered successfully!" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Agent ID: $($response.agent.id)" -ForegroundColor Green
        Write-Host "  API Key: $($response.agent.api_key)" -ForegroundColor Green
        Write-Host "  Claim URL: $($response.agent.claim_url)" -ForegroundColor Yellow
        Write-Host "  Claim Code: $($response.agent.claim_code)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "⚠️  IMPORTANT: Open this URL to verify ownership:" -ForegroundColor Yellow
        Write-Host "   $($response.agent.claim_url)" -ForegroundColor Cyan
        Write-Host ""
        
        $ApiKey = $response.agent.api_key
        
        # Prompt to open claim URL
        $openUrl = Read-Host "Open claim URL in browser now? (Y/n)"
        if ($openUrl -ne 'n') {
            Start-Process $response.agent.claim_url
            Write-Host ""
            Read-Host "Press Enter after verifying ownership..."
        }
        
    } catch {
        Write-Host "✗ Registration failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} elseif ($ApiKey) {
    Write-Host "[1/5] Using provided API key..." -ForegroundColor Cyan
} else {
    Write-Host "[1/5] Skipping registration (use -Register to register new agent)" -ForegroundColor Yellow
    Write-Host ""
    $ApiKey = Read-Host "Enter your AgentDesc API key"
}

# Step 2: Save API Key
if ($ApiKey) {
    Write-Host ""
    Write-Host "[2/5] Saving API key..." -ForegroundColor Cyan
    
    # Update .env file
    if (Test-Path $envFile) {
        $envContent = Get-Content $envFile -Raw
        if ($envContent -match 'AGENTDESC_API_KEY=') {
            $envContent = $envContent -replace 'AGENTDESC_API_KEY=.*', "AGENTDESC_API_KEY=$ApiKey"
        } else {
            $envContent += "`nAGENTDESC_API_KEY=$ApiKey`n"
        }
        Set-Content -Path $envFile -Value $envContent -NoNewline
    } else {
        Set-Content -Path $envFile -Value "AGENTDESC_API_KEY=$ApiKey`n"
    }
    
    Write-Host "  ✓ Saved to .env" -ForegroundColor Green
    
    # Create credentials file
    $credDir = Join-Path $env:USERPROFILE ".config\agentdesc"
    if (-not (Test-Path $credDir)) {
        New-Item -ItemType Directory -Path $credDir -Force | Out-Null
    }
    
    $credFile = Join-Path $credDir "credentials.json"
    $credData = @{
        api_key = $ApiKey
    } | ConvertTo-Json
    
    Set-Content -Path $credFile -Value $credData
    Write-Host "  ✓ Saved to $credFile" -ForegroundColor Green
    
    # Set environment variable for current session
    $env:AGENTDESC_API_KEY = $ApiKey
    Write-Host "  ✓ Set environment variable" -ForegroundColor Green
}

# Step 3: Verify Skill File
Write-Host ""
Write-Host "[3/5] Verifying AgentDesc skill file..." -ForegroundColor Cyan

$skillFile = Join-Path $projectRoot "AitherOS\skills\agentdesc.skill.md"
if (Test-Path $skillFile) {
    Write-Host "  ✓ Skill file exists: $skillFile" -ForegroundColor Green
} else {
    Write-Host "  ✗ Skill file not found!" -ForegroundColor Red
    Write-Host "  Expected: $skillFile" -ForegroundColor Gray
    exit 1
}

# Step 4: Check Docker Compose
Write-Host ""
Write-Host "[4/5] Verifying Docker configuration..." -ForegroundColor Cyan

$composeFile = Join-Path $projectRoot "docker-compose.aitheros.yml"
if (Test-Path $composeFile) {
    $composeContent = Get-Content $composeFile -Raw
    if ($composeContent -match 'aither-skills:') {
        Write-Host "  ✓ AitherSkills service configured in Docker Compose" -ForegroundColor Green
    } else {
        Write-Host "  ✗ AitherSkills service not found in Docker Compose" -ForegroundColor Red
        Write-Host "  Please add the service definition." -ForegroundColor Gray
        exit 1
    }
}

# Step 5: Start Service (if requested)
:StartServiceLabel
if ($StartService) {
    Write-Host ""
    Write-Host "[5/5] Starting AitherSkills service..." -ForegroundColor Cyan
    
    Push-Location $projectRoot
    try {
        docker compose -f docker-compose.aitheros.yml up -d aither-skills
        
        Write-Host "  ✓ Service started" -ForegroundColor Green
        Write-Host ""
        Write-Host "Waiting for service to be healthy..." -ForegroundColor Gray
        
        $maxAttempts = 30
        $attempt = 0
        $healthy = $false
        
        while ($attempt -lt $maxAttempts -and -not $healthy) {
            Start-Sleep -Seconds 2
            $attempt++
            
            try {
                $health = Invoke-RestMethod -Uri "http://localhost:8780/health" -TimeoutSec 2 -ErrorAction Stop
                if ($health.status -eq "healthy") {
                    $healthy = $true
                }
            } catch {
                # Still starting up
            }
            
            Write-Host "." -NoNewline -ForegroundColor Gray
        }
        
        Write-Host ""
        
        if ($healthy) {
            Write-Host "  ✓ Service is healthy!" -ForegroundColor Green
            
            # List loaded skills
            Write-Host ""
            Write-Host "Checking loaded skills..." -ForegroundColor Cyan
            $skills = Invoke-RestMethod -Uri "http://localhost:8780/skills"
            
            $agentdescSkill = $skills.skills | Where-Object { $_.name -like "*AgentDesc*" }
            if ($agentdescSkill) {
                Write-Host "  ✓ AgentDesc skill loaded with $($agentdescSkill.endpoints.Count) endpoints" -ForegroundColor Green
            } else {
                Write-Host "  ⚠ AgentDesc skill not found. Try restarting the service." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  ⚠ Service not responding after 60 seconds" -ForegroundColor Yellow
            Write-Host "  Check logs: docker logs aither-skills" -ForegroundColor Gray
        }
        
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "[5/5] Skipping service start (use -StartService to start)" -ForegroundColor Yellow
}

# Summary
Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                  Setup Complete!                           ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Verify ownership at your claim URL (if not done yet)" -ForegroundColor White
Write-Host "  2. Test the integration:" -ForegroundColor White
Write-Host "     curl http://localhost:8780/skills/agentdesc" -ForegroundColor Gray
Write-Host "  3. View full guide:" -ForegroundColor White
Write-Host "     Get-Content docs\AGENTDESC-INTEGRATION.md" -ForegroundColor Gray
Write-Host ""
Write-Host "Your agent will now automatically check for tasks every 2 hours!" -ForegroundColor Green
Write-Host ""
