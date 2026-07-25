function Invoke-AitherSetup {
    <#
    .SYNOPSIS
        One command to set up AitherOS — full auto, interactive menu, or targeted modules.

    .DESCRIPTION
        Wraps the playbook engine with an interactive setup experience.

        Three modes:
          aither setup                    Interactive menu — pick playbook + modules
          aither setup -Playbook bootstrap  Run a specific playbook directly
          aither setup -All               Run the full bootstrap playbook

        Available playbooks (run 'aither setup -List' to see all):
          bootstrap           Fresh system — Docker, K8s, environment, boot AitherOS
          install-aitheros    Full partner install — deps, profile, deploy, models
          onboard-remote-site Lightweight — ADK + Node + MCP (no Docker needed)
          dev-environment     Dev tools on custom drive paths
          setup-interactive   Post-clone — pick: vLLM, Ollama, MCP, secrets, tunnel, etc.

    .PARAMETER Playbook
        Run a specific playbook by name.

    .PARAMETER All
        Run the 'bootstrap' playbook with all defaults (full auto).

    .PARAMETER List
        List all available setup playbooks.

    .PARAMETER Modules
        For setup-interactive playbook: comma-separated module keys to run.
        Valid: prereqs, environment, secrets, docker, vllm, ollama, node, mcp, connect, mesh, desktop

    .PARAMETER Profile
        Docker Compose profile: minimal, core, full. Default: core.

    .PARAMETER DryRun
        Show what would run without executing.

    .PARAMETER Variables
        Hashtable of variables to pass to the playbook.

    .EXAMPLE
        Invoke-AitherSetup
        # Interactive menu

    .EXAMPLE
        Invoke-AitherSetup -All
        # Full bootstrap, no questions

    .EXAMPLE
        Invoke-AitherSetup -Playbook onboard-remote-site -Variables @{ TenantSlug = 'acme'; ApiKey = 'sk_...' }
        # Onboard a remote site

    .EXAMPLE
        Invoke-AitherSetup -Playbook setup-interactive -Modules vllm,mcp,secrets
        # Just set up vLLM, MCP config, and API keys

    .EXAMPLE
        Invoke-AitherSetup -List
        # Show available playbooks

    .EXAMPLE
        Invoke-AitherSetup -DryRun
        # Preview what would happen
    #>
    [CmdletBinding(DefaultParameterSetName = 'Interactive')]
    param(
        [Parameter(ParameterSetName = 'Named', Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
            $setupPlaybooks = @('bootstrap', 'install-aitheros', 'onboard-remote-site', 'dev-environment', 'setup-interactive')
            $setupPlaybooks | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        })]
        [string]$Playbook,

        [Parameter(ParameterSetName = 'All')]
        [switch]$All,

        [Parameter(ParameterSetName = 'List')]
        [switch]$List,

        [string[]]$Modules,

        [ValidateSet('minimal', 'core', 'full')]
        [string]$Profile = 'core',

        [switch]$DryRun,

        [hashtable]$Variables = @{}
    )

    # ── Banner ───────────────────────────────────────────────────────────
    function Show-Banner {
        Write-Host ""
        Write-Host "   ___   _ _____ _  _ ___ ___  ___  ___" -ForegroundColor Cyan
        Write-Host "  / _ \ | |_   _| || | __| _ \/ _ \/ __|" -ForegroundColor Cyan
        Write-Host " | (_) || | | | | __ | _||   / (_) \__ \" -ForegroundColor Cyan
        Write-Host "  \___/_|_| |_| |_||_|___|_|_\\___/|___/" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Setup Wizard" -ForegroundColor White
        Write-Host ""
    }

    # ── List mode ────────────────────────────────────────────────────────
    if ($List) {
        Show-Banner
        Write-Host "  Available setup playbooks:" -ForegroundColor White
        Write-Host ""

        $playbooks = Get-AitherPlaybook -List | Where-Object {
            $_.Name -in @('bootstrap', 'install-aitheros', 'onboard-remote-site',
                          'dev-environment', 'setup-interactive',
                          'deploy-lightweight', 'docker-setup')
        }

        # If filter returned nothing, show all with 'setup' category or common ones
        if (-not $playbooks) {
            $playbooks = Get-AitherPlaybook -List
        }

        foreach ($pb in $playbooks) {
            Write-Host "  $($pb.Name)" -ForegroundColor Green -NoNewline
            Write-Host " — $($pb.Description)" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "  Usage:" -ForegroundColor DarkGray
        Write-Host "    Invoke-AitherSetup -Playbook <name>" -ForegroundColor White
        Write-Host "    Invoke-AitherSetup -Playbook <name> -DryRun" -ForegroundColor White
        Write-Host ""
        return
    }

    # ── Full auto mode ───────────────────────────────────────────────────
    if ($All) {
        Show-Banner
        Write-Host "  Running full bootstrap..." -ForegroundColor Yellow
        Write-Host ""

        $vars = @{ AitherOSProfile = $Profile } + $Variables
        return Invoke-AitherPlaybook -Name 'bootstrap' -Variables $vars -DryRun:$DryRun -ShowOutput -ContinueOnError
    }

    # ── Named playbook mode ─────────────────────────────────────────────
    if ($Playbook) {
        Show-Banner
        Write-Host "  Playbook: $Playbook" -ForegroundColor Yellow

        $vars = $Variables.Clone()
        $vars['Profile'] = $Profile

        # If modules specified, load playbook, filter sequence, run filtered
        if ($Modules -and $Modules.Count -gt 0) {
            return Invoke-FilteredPlaybook -PlaybookName $Playbook -ModuleKeys $Modules -Variables $vars -DryRun:$DryRun
        }

        Write-Host ""
        return Invoke-AitherPlaybook -Name $Playbook -Variables $vars -DryRun:$DryRun -ShowOutput -ContinueOnError
    }

    # ── Interactive mode (default) ───────────────────────────────────────
    Show-Banner

    # Step 1: Pick a playbook
    $setupPlaybooks = @(
        @{ Key = '1'; Name = 'bootstrap';           Desc = 'Fresh system — Docker, K8s, env, boot everything' }
        @{ Key = '2'; Name = 'install-aitheros';    Desc = 'Full install — deps, partner profile, deploy, models' }
        @{ Key = '3'; Name = 'setup-interactive';   Desc = 'Post-clone — pick modules: vLLM, Ollama, MCP, secrets, tunnel' }
        @{ Key = '4'; Name = 'onboard-remote-site'; Desc = 'Lightweight — ADK + Node + MCP (no Docker)' }
        @{ Key = '5'; Name = 'dev-environment';     Desc = 'Dev tools — Python, Node, Docker, WSL, cloud CLIs' }
    )

    Write-Host "  What do you want to set up?" -ForegroundColor White
    Write-Host ""

    foreach ($p in $setupPlaybooks) {
        Write-Host "    [$($p.Key)] " -ForegroundColor Cyan -NoNewline
        Write-Host "$($p.Name)" -ForegroundColor Green -NoNewline
        Write-Host " — $($p.Desc)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "    [q] Quit" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Select"
    $choice = $choice.Trim()

    if ($choice -eq 'q' -or $choice -eq 'Q' -or -not $choice) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return
    }

    $selected = $setupPlaybooks | Where-Object { $_.Key -eq $choice }
    if (-not $selected) {
        Write-Host "  Invalid choice: $choice" -ForegroundColor Red
        return
    }

    $playbookName = $selected.Name
    $vars = @{ Profile = $Profile } + $Variables

    # Step 2: If setup-interactive, offer module picker
    $selectedModuleKeys = $null
    if ($playbookName -eq 'setup-interactive') {
        $pickerResult = Show-ModulePicker -BaseVariables $vars
        if ($null -eq $pickerResult) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return
        }
        $vars = $pickerResult
        if ($vars.SetupModules -and $vars.SetupModules -ne 'all') {
            $selectedModuleKeys = $vars.SetupModules -split ','
        }
    }

    # Step 3: Confirm
    Write-Host ""
    Write-Host "  Playbook: " -NoNewline -ForegroundColor DarkGray
    Write-Host $playbookName -ForegroundColor Green

    if ($selectedModuleKeys) {
        Write-Host "  Modules:  " -NoNewline -ForegroundColor DarkGray
        Write-Host ($selectedModuleKeys -join ', ') -ForegroundColor Cyan
    }

    Write-Host "  Profile:  " -NoNewline -ForegroundColor DarkGray
    Write-Host $Profile -ForegroundColor Cyan
    Write-Host ""

    if (-not $DryRun) {
        $confirm = Read-Host "  Run now? (Y/n)"
        if ($confirm -and $confirm -notmatch '^[Yy]') {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return
        }
    }

    Write-Host ""

    # If module filtering, use filtered execution
    if ($selectedModuleKeys) {
        return Invoke-FilteredPlaybook -PlaybookName $playbookName -ModuleKeys $selectedModuleKeys -Variables $vars -DryRun:$DryRun
    }

    return Invoke-AitherPlaybook -Name $playbookName -Variables $vars -DryRun:$DryRun -ShowOutput -ContinueOnError
}


function Show-ModulePicker {
    <#
    .SYNOPSIS
        Interactive module picker for setup-interactive playbook.
    #>
    param([hashtable]$BaseVariables = @{})

    $modules = [ordered]@{
        prereqs    = @{ Num = 1;  Name = 'Prerequisites';     Cat = 'Foundation';     Desc = 'Docker, PowerShell 7, Git, hardware check' }
        environment= @{ Num = 2;  Name = 'Environment';       Cat = 'Foundation';     Desc = 'Master key, hardware detect, .env config' }
        secrets    = @{ Num = 3;  Name = 'API Keys & Secrets'; Cat = 'Foundation';    Desc = 'GitHub, Anthropic, HuggingFace tokens' }
        docker     = @{ Num = 4;  Name = 'Docker Services';   Cat = 'Infrastructure'; Desc = 'Build + start containers' }
        vllm       = @{ Num = 5;  Name = 'vLLM';              Cat = 'AI Inference';   Desc = 'GPU inference server (CUDA)' }
        ollama     = @{ Num = 6;  Name = 'Ollama';             Cat = 'AI Inference';   Desc = 'Local models (CPU/GPU)' }
        node       = @{ Num = 7;  Name = 'ADK + AitherNode';  Cat = 'Tooling';        Desc = 'Agent framework + MCP server' }
        mcp        = @{ Num = 8;  Name = 'MCP Config';        Cat = 'Tooling';        Desc = 'Claude Code, Cursor, VS Code' }
        connect    = @{ Num = 9;  Name = 'Cloudflare Tunnel'; Cat = 'Networking';     Desc = 'Remote access to your instance' }
        mesh       = @{ Num = 10; Name = 'Mesh Network';      Cat = 'Networking';     Desc = 'Multi-site sync' }
        desktop    = @{ Num = 11; Name = 'AitherDesktop';     Cat = 'Desktop';        Desc = 'PyQt6 native overlay' }
    }

    Write-Host ""
    Write-Host "  Pick modules (comma-separated numbers, 'a' for all):" -ForegroundColor White
    Write-Host ""

    $lastCat = ''
    foreach ($entry in $modules.GetEnumerator()) {
        $m = $entry.Value
        if ($m.Cat -ne $lastCat) {
            Write-Host "  --- $($m.Cat) ---" -ForegroundColor DarkCyan
            $lastCat = $m.Cat
        }
        $pad = if ($m.Num -lt 10) { ' ' } else { '' }
        Write-Host "    [$pad$($m.Num)] $($m.Name)" -ForegroundColor White -NoNewline
        Write-Host " — $($m.Desc)" -ForegroundColor DarkGray
    }

    Write-Host ""
    $input = Read-Host "  Modules"
    $input = $input.Trim()

    if (-not $input -or $input -eq 'q') { return $null }

    if ($input -eq 'a' -or $input -eq 'A') {
        $BaseVariables['SetupModules'] = 'all'
        return $BaseVariables
    }

    # Map numbers to keys
    $selectedKeys = @()
    foreach ($num in ($input -split '[,\s]+')) {
        $n = 0
        if ([int]::TryParse($num.Trim(), [ref]$n)) {
            $match = $modules.GetEnumerator() | Where-Object { $_.Value.Num -eq $n }
            if ($match) { $selectedKeys += $match.Key }
        }
    }

    if ($selectedKeys.Count -eq 0) {
        Write-Host "  No valid modules selected." -ForegroundColor Red
        return $null
    }

    $BaseVariables['SetupModules'] = ($selectedKeys -join ',')
    return $BaseVariables
}


function Invoke-FilteredPlaybook {
    <#
    .SYNOPSIS
        Load a playbook, filter its Sequence by Module keys, execute the filtered version.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PlaybookName,

        [Parameter(Mandatory)]
        [string[]]$ModuleKeys,

        [hashtable]$Variables = @{},

        [switch]$DryRun
    )

    $pb = Get-AitherPlaybook -Name $PlaybookName
    if (-not $pb) {
        Write-Host "  Playbook not found: $PlaybookName" -ForegroundColor Red
        return
    }

    # Filter sequence: keep steps whose Module field matches selected keys
    $filtered = @()
    foreach ($step in $pb.Sequence) {
        $stepModule = $step.Module
        if (-not $stepModule) {
            # Steps without a Module field always run
            $filtered += $step
        }
        elseif ($stepModule -in $ModuleKeys) {
            $filtered += $step
        }
    }

    if ($filtered.Count -eq 0) {
        Write-Host "  No matching steps found for modules: $($ModuleKeys -join ', ')" -ForegroundColor Red
        return
    }

    Write-Host "  Running $($filtered.Count) steps (filtered from $($pb.Sequence.Count)):" -ForegroundColor White
    foreach ($step in $filtered) {
        Write-Host "    - $($step.Name)" -ForegroundColor Gray
    }
    Write-Host ""

    # Replace sequence with filtered version and execute
    $pb.Sequence = $filtered
    return Invoke-AitherPlaybook -Playbook $pb -Variables $Variables -DryRun:$DryRun -ShowOutput -ContinueOnError
}
