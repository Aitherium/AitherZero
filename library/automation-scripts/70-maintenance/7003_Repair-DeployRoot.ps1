#Requires -Version 7.0
<#
.SYNOPSIS
    Diagnose and self-heal drift between the repo tree and the tree the fleet DEPLOYS FROM.

.DESCRIPTION
    This host has TWO checkouts. Sessions edit one; Docker builds and bind-mounts from the
    other. Work can therefore be committed, pushed, green in CI and still not live, with
    both trees reporting clean and no error anywhere. That is not hypothetical:

      * 2026-07-27 — two fixes verified earlier the same day were simply GONE from the
        deploy tree. A concurrent session had written whole files over them. One was also
        no longer live: a service had been restarted onto the reverted file.
      * 2026-07-29 — a routine + config authored and committed in the repo tree were absent
        from the deploy tree, and the worker had none of the mounts the deploy-tree compose
        declared. The status recorded at the time said "only a recreate remains", because
        it had been verified against the wrong tree.

    Nothing cheap catches this class. `git status` is clean in both trees, the containers
    are healthy, and the code on disk in the repo looks exactly right.

    So this script asks the only question that matters — *does the tree the fleet builds
    from actually have the work, and is the running fleet actually on it?* — and repairs
    what is safe to repair.

    DEPLOY ROOT IS MEASURED, NOT CONFIGURED. It is read from the running containers'
    compose project label, so it cannot drift from a stale config value. A settings file
    would just be one more thing to be wrong.

    ONLY SAFE REPAIRS. This tree is shared with concurrent sessions and a post-commit CD
    loop, so a careless git operation here does not stay local — it ships. Therefore:
    fast-forward-only merges, and pathspec-scoped checkouts of files that are ABSENT.
    Never reset --hard, never stash, never checkout ., never force. If a merge cannot
    fast-forward, that is reported for a human rather than forced — a `reset --hard` in
    this repo once destroyed hours of another session's work and re-deployed a P0 leak.

.PARAMETER Fix
    Apply the safe repairs. Without it the script only reports (exit 1 on drift).

.PARAMETER Json
    Emit a machine-readable result for a routine or alert path.

.PARAMETER SkipRecreate
    Diagnose and reconcile files, but never recreate a container. Use when a build or
    recreate wave is already running — overlapping them has crashed the WSL2 backend.

.PARAMETER MountsOnly
    Check ONLY that declared source-tree mounts are attached to the running containers,
    skipping the tree-reconciliation half.

    Use this from the post-commit autosync path. `fleet-autosync.sh`'s `canon-sync` already
    reconciles the deploy tree with origin, and does it better than this script does — it
    handles the diverged-deploy-root case (D-1642) with logic that has been exercised on
    real incidents. Duplicating it here would be a second implementation of the same
    invariant, which is the failure this whole workstream removed. What canon-sync does NOT
    do is verify that a mount the compose file DECLARES is actually attached to the running
    container, and a restart never attaches a new one — that is the gap this fills, and it
    is how the worker ran for hours without a mount its own compose declared.

.PARAMETER SelfTest
    Prove the checks can fail, using throwaway repos. Needs no fleet.

.EXAMPLE
    .\7003_Repair-DeployRoot.ps1
    Report drift only. Exit 0 clean, 1 drift, 2 could not determine.

.EXAMPLE
    .\7003_Repair-DeployRoot.ps1 -Fix
    Reconcile the deploy tree and recreate any container missing a declared mount.

.EXAMPLE
    .\7003_Repair-DeployRoot.ps1 -Json | ConvertFrom-Json
    For the self-heal routine / AitherComet.

.NOTES
    Category: maintenance
    Dependencies: git, docker
    Platform: Windows (the two-checkout split is host-specific)
    Exit codes: 0 = clean, 1 = drift found (or not fully repaired), 2 = could not determine
                A run that cannot determine the answer is NEVER 0. Silence is not a pass.
#>

[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$Json,
    [switch]$SkipRecreate,
    [switch]$MountsOnly,
    [switch]$SelfTest
)

# NOT SilentlyContinue. A maintenance script that hides its own errors is the defect class
# it is meant to find; several sibling scripts set that and cannot be trusted when quiet.
$ErrorActionPreference = 'Stop'

# Paths that must exist in the deploy tree for the fleet to run what the repo says it runs.
# Bind-mounted or read at runtime, so their absence is silent rather than a build failure.
$script:DeployCriticalPaths = @(
    'AitherOS/lib',
    'AitherOS/config',
    'AitherOS/services',
    'AitherOS/dev/tools',
    '.DEPLOYMENT/compose/docker-compose.aitheros.yml'
)

$script:Findings = [System.Collections.Generic.List[hashtable]]::new()
$script:Repairs = [System.Collections.Generic.List[string]]::new()

function Add-Finding {
    param([string]$Check, [string]$Severity, [string]$Detail, [string]$Remedy = '')
    $script:Findings.Add(@{ check = $Check; severity = $Severity; detail = $Detail; remedy = $Remedy })
}

function Invoke-Git {
    <#  Run git in a specific tree and return stdout lines.

        Never throws on a non-zero exit: callers decide what a failure means, because
        "git said no" is often the finding rather than an error.

        $GitArgs is an EXPLICIT array, not ValueFromRemainingArguments. With the latter,
        PowerShell treats a `--` argument as its own end-of-parameters token and removes
        it, so `ls-tree ... -- <pathspec>` arrived at git without the separator and the
        pathspec was silently dropped — every path scanned as "no files tracked", i.e. the
        check passed by finding nothing. The self-test caught exactly that. #>
    param([string]$Root, [string[]]$GitArgs)
    $out = & git -C $Root @GitArgs 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Lines = @($out); Text = ($out -join "`n") }
}

function Get-RepoRoot {
    <#  Walk up to the enclosing git checkout.

        A fixed parent count was wrong by one and returned `D:\`, which then reported the
        repo branch as "fatal: not a git repository" and raised a bogus branch-mismatch
        CRITICAL. Counting directories breaks the moment anything moves; looking for the
        marker cannot. #>
    $d = $PSScriptRoot
    while ($d) {
        if (Test-Path (Join-Path $d '.git')) { return $d }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

function Get-DeployRoot {
    <#  MEASURED from the running fleet, not read from config.

        The compose project label on any running container records the absolute path of the
        compose file docker actually loaded. Two levels up from `.DEPLOYMENT/compose/` is
        the deploy root. If nothing is running we cannot answer, and we say so (exit 2)
        rather than guessing the repo root — guessing is exactly how the wrong tree gets
        verified. #>
    param([string]$Fallback)
    $names = & docker ps --format '{{.Names}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $names) { return $null }
    foreach ($n in @($names)) {
        $cf = & docker inspect $n --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $cf) {
            $first = (@($cf -split ',')[0]).Trim()
            if ($first) {
                $composeDir = Split-Path $first -Parent          # ...\.DEPLOYMENT\compose
                $deployment = Split-Path $composeDir -Parent      # ...\.DEPLOYMENT
                $root = Split-Path $deployment -Parent            # deploy root
                if ($root -and (Test-Path $root)) { return $root }
            }
        }
    }
    return $null
}

function Test-TreeReconciliation {
    <# Is the deploy tree on the same branch, and can it reach the repo tree's commits? #>
    param([string]$RepoRoot, [string]$DeployRoot)

    $repoBranch = (Invoke-Git $RepoRoot @('rev-parse','--abbrev-ref','HEAD')).Text.Trim()
    $depBranch = (Invoke-Git $DeployRoot @('rev-parse','--abbrev-ref','HEAD')).Text.Trim()

    if (-not $depBranch) {
        Add-Finding 'deploy-tree-git' 'CRITICAL' "cannot read HEAD in $DeployRoot" 'is it a git checkout?'
        return
    }
    if ($repoBranch -ne $depBranch) {
        Add-Finding 'branch-match' 'CRITICAL' `
            "repo tree is on '$repoBranch' but the deploy tree is on '$depBranch' — the fleet is building a DIFFERENT branch" `
            "switch the deploy tree, or accept that repo-tree commits will never deploy"
    }

    # Fetch is read-only and safe.
    $null = Invoke-Git $DeployRoot @('fetch','--quiet','origin',$depBranch)
    $counts = (Invoke-Git $DeployRoot @('rev-list','--left-right','--count',"origin/$depBranch...HEAD")).Text.Trim()
    if ($counts -match '^(\d+)\s+(\d+)$') {
        $behind = [int]$Matches[1]; $ahead = [int]$Matches[2]
        if ($behind -gt 0) {
            $remedy = if ($ahead -gt 0) {
                "deploy tree is ahead $ahead as well, so a fast-forward is impossible — a HUMAN must reconcile (never forced from here)"
            } else { "fast-forward merge (this script does it with -Fix)" }
            Add-Finding 'deploy-tree-behind' 'CRITICAL' `
                "deploy tree is $behind commit(s) behind origin/$depBranch (ahead $ahead) — committed work is NOT deployed" $remedy
        }
    } else {
        Add-Finding 'deploy-tree-behind' 'WARN' "could not compare the deploy tree to origin/$depBranch" ''
    }
}

function Test-DeployCriticalPaths {
    <#  Files tracked at the deploy tree's own upstream but MISSING from its working tree.

        This is the exact shape of the 2026-07-29 incident: the routine module and its
        config were committed and pushed, and simply absent from the tree docker mounts. #>
    param([string]$DeployRoot)

    $branch = (Invoke-Git $DeployRoot @('rev-parse','--abbrev-ref','HEAD')).Text.Trim()
    if (-not $branch) { return }

    foreach ($p in $script:DeployCriticalPaths) {
        $tracked = Invoke-Git $DeployRoot @('ls-tree','-r','--name-only',"origin/$branch",'--',$p)
        if (-not $tracked.Ok) { continue }
        $missing = @()
        foreach ($f in $tracked.Lines) {
            $f = $f.Trim()
            if (-not $f) { continue }
            if (-not (Test-Path (Join-Path $DeployRoot $f))) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            $shown = ($missing | Select-Object -First 8) -join ', '
            Add-Finding 'deploy-critical-missing' 'CRITICAL' `
                "$($missing.Count) file(s) under '$p' are tracked at origin/$branch but ABSENT from the deploy tree: $shown" `
                'pathspec checkout from origin (this script does it with -Fix)'
        }
    }
}

function Get-DeclaredMountSources {
    <# Host paths the deploy-tree compose declares as bind mounts, per service. #>
    param([string]$ComposePath)
    if (-not (Test-Path $ComposePath)) { return @{} }
    # Deliberately a text scan, not a YAML parse: this file uses merge keys and
    # interpolation that a naive parser resolves differently from docker, and we only need
    # the destination strings.
    $result = @{}
    $svc = $null
    foreach ($line in Get-Content $ComposePath) {
        if ($line -match '^  ([A-Za-z0-9_.-]+):\s*$') { $svc = $Matches[1]; continue }
        if ($svc -and $line -match '^\s+-\s+.+:(/[^:]+)(:ro|:rw|:cached)?\s*$') {
            if (-not $result.ContainsKey($svc)) { $result[$svc] = @() }
            $result[$svc] += $Matches[1]
        }
    }
    return $result
}

function Test-RunningMounts {
    <#  A mount DECLARED in the deploy-tree compose but absent on the running container.

        A restart does NOT attach a new bind mount — only a recreate does. So a compose
        change can be committed, present in the deploy tree, and still not in effect, with
        the container healthy the whole time. #>
    param([string]$DeployRoot)

    $composePath = Join-Path $DeployRoot '.DEPLOYMENT/compose/docker-compose.aitheros.yml'
    $declared = Get-DeclaredMountSources -ComposePath $composePath
    if ($declared.Count -eq 0) { return @() }

    $running = & docker ps --format '{{.Names}}' 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }

    $needRecreate = @()
    foreach ($name in @($running)) {
        $svc = & docker inspect $name --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $svc -or -not $declared.ContainsKey($svc)) { continue }
        # `{{println .Destination}}`, NOT `{{"`n"}}`: inside a single-quoted PowerShell
        # string the backtick-n is LITERAL, so the Go template emitted one line containing
        # "/data`n/etc/resolv.conf`n..." and nothing ever matched — every mount reported
        # missing and the first live run produced a screen of false CRITICALs.
        $actual = & docker inspect $name --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $actualSet = @($actual) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        # Only SOURCE-TREE mounts. The generic form is unreliable here: this compose file
        # has 259 services with YAML anchors and merge keys, and several containers share
        # one service label, so a text scan mis-attributes named volumes and cert paths.
        # The class this script exists for is source code not being mounted, so restrict
        # to that and stay quiet about the rest rather than cry wolf.
        $absent = @(
            $declared[$svc] |
                Where-Object { $_ -match '^/app/(AitherOS/)?(lib|services|config|dev|apps)(/|$)' -or $_ -eq '/app/TECH_DEBT.md' } |
                Where-Object { $actualSet -notcontains $_ }
        )
        if ($absent.Count -gt 0) {
            $needRecreate += [pscustomobject]@{ Container = $name; Service = $svc; Missing = $absent }
            Add-Finding 'mount-not-attached' 'CRITICAL' `
                "container '$name' (service '$svc') is missing declared mount(s): $($absent -join ', ') — a RESTART will not attach these" `
                'recreate the service (this script does it with -Fix, unless -SkipRecreate)'
        }
    }
    return $needRecreate
}

# ---------------------------------------------------------------------------- #
# Repairs — safe forms only
# ---------------------------------------------------------------------------- #

function Repair-DeployTree {
    param([string]$DeployRoot)

    $branch = (Invoke-Git $DeployRoot @('rev-parse','--abbrev-ref','HEAD')).Text.Trim()
    if (-not $branch) { return }

    $counts = (Invoke-Git $DeployRoot @('rev-list','--left-right','--count',"origin/$branch...HEAD")).Text.Trim()
    if ($counts -match '^(\d+)\s+(\d+)$') {
        $behind = [int]$Matches[1]; $ahead = [int]$Matches[2]
        if ($behind -gt 0) {
            if ($ahead -gt 0) {
                # A real merge with local commits, in a tree other sessions are writing to.
                # Refuse. Forcing this is what D-267 did.
                $script:Repairs.Add("REFUSED to reconcile: deploy tree is behind $behind AND ahead $ahead — needs a human merge, not automation")
            } else {
                # --ff-only cannot rewrite or discard anything; it declines instead.
                $m = Invoke-Git $DeployRoot @('merge','--ff-only',"origin/$branch")
                if ($m.Ok) { $script:Repairs.Add("fast-forwarded the deploy tree $behind commit(s) to origin/$branch") }
                else { $script:Repairs.Add("fast-forward declined: $($m.Text -split "`n" | Select-Object -First 1)") }
            }
        }
    }

    # Restore only files that are ABSENT. A pathspec checkout of a missing file cannot
    # overwrite a concurrent session's edit, because there is nothing there to overwrite.
    foreach ($p in $script:DeployCriticalPaths) {
        $tracked = Invoke-Git $DeployRoot @('ls-tree','-r','--name-only',"origin/$branch",'--',$p)
        if (-not $tracked.Ok) { continue }
        $missing = @()
        foreach ($f in $tracked.Lines) {
            $f = $f.Trim()
            if ($f -and -not (Test-Path (Join-Path $DeployRoot $f))) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            $co = Invoke-Git $DeployRoot (@('checkout',"origin/$branch",'--') + $missing)
            if ($co.Ok) { $script:Repairs.Add("restored $($missing.Count) absent file(s) under '$p' from origin/$branch") }
            else { $script:Repairs.Add("could not restore files under '$p': $($co.Text -split "`n" | Select-Object -First 1)") }
        }
    }
}

function Repair-Mounts {
    param([string]$DeployRoot, [array]$NeedRecreate)
    if ($NeedRecreate.Count -eq 0) { return }

    # The canonical wrapper injects --project-directory and -p, so relative binds resolve
    # against the deploy root. Running `docker compose -f <file>` by hand instead resolves
    # them one directory too deep, which has silently emptied data volumes on this host.
    $wrapper = Join-Path $DeployRoot '.DEPLOYMENT/scripts/compose.ps1'
    if (-not (Test-Path $wrapper)) {
        $script:Repairs.Add("REFUSED to recreate: canonical wrapper not found at $wrapper (raw `docker compose -f` mis-resolves relative binds)")
        return
    }
    foreach ($item in $NeedRecreate) {
        # One service at a time, and never with --build: attaching a mount needs a
        # recreate, not an image rebuild, and a build wave here has crashed the backend.
        & pwsh -NoProfile -File $wrapper aitheros up -d --no-build --force-recreate $item.Service 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $script:Repairs.Add("recreated '$($item.Service)' to attach: $($item.Missing -join ', ')") }
        else { $script:Repairs.Add("recreate FAILED for '$($item.Service)' (exit $LASTEXITCODE)") }
    }
}

# ---------------------------------------------------------------------------- #
# Self-test
# ---------------------------------------------------------------------------- #

function Invoke-SelfTest {
    $fail = [System.Collections.Generic.List[string]]::new()
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drt-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $up = Join-Path $tmp 'upstream'; $dep = Join-Path $tmp 'deploy'
        New-Item -ItemType Directory -Path $up -Force | Out-Null
        & git -C $up init -q --bare 2>&1 | Out-Null

        $work = Join-Path $tmp 'work'
        & git clone -q $up $work 2>&1 | Out-Null
        & git -C $work config user.email 't@t' 2>&1 | Out-Null
        & git -C $work config user.name 't' 2>&1 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $work 'AitherOS/config') -Force | Out-Null
        Set-Content (Join-Path $work 'AitherOS/config/keep.yaml') 'a: 1'
        & git -C $work add -A 2>&1 | Out-Null
        & git -C $work commit -qm base 2>&1 | Out-Null
        & git -C $work push -q origin HEAD 2>&1 | Out-Null

        & git clone -q $up $dep 2>&1 | Out-Null

        # A clean deploy tree must produce no findings.
        $script:Findings.Clear()
        Test-TreeReconciliation -RepoRoot $work -DeployRoot $dep
        Test-DeployCriticalPaths -DeployRoot $dep
        if ($script:Findings.Count -ne 0) {
            $fail.Add("clean trees produced findings: $($script:Findings.check -join ', ')")
        }

        # Deleting a deploy-critical file must be detected...
        Remove-Item (Join-Path $dep 'AitherOS/config/keep.yaml') -Force
        $script:Findings.Clear()
        Test-DeployCriticalPaths -DeployRoot $dep
        if (-not ($script:Findings | Where-Object { $_.check -eq 'deploy-critical-missing' })) {
            $fail.Add('a deleted deploy-critical file was NOT detected')
        }
        # ...and repaired, because it is absent (nothing to overwrite).
        Repair-DeployTree -DeployRoot $dep
        if (-not (Test-Path (Join-Path $dep 'AitherOS/config/keep.yaml'))) {
            $fail.Add('the absent file was not restored by the repair')
        }

        # A deploy tree left behind must be detected.
        Set-Content (Join-Path $work 'AitherOS/config/keep.yaml') 'a: 2'
        & git -C $work commit -aqm next 2>&1 | Out-Null
        & git -C $work push -q origin HEAD 2>&1 | Out-Null
        $script:Findings.Clear()
        Test-TreeReconciliation -RepoRoot $work -DeployRoot $dep
        if (-not ($script:Findings | Where-Object { $_.check -eq 'deploy-tree-behind' })) {
            $fail.Add('a deploy tree behind origin was NOT detected')
        }

        # And a divergent tree must be REFUSED, not forced.
        Set-Content (Join-Path $dep 'AitherOS/config/local.yaml') 'b: 1'
        & git -C $dep add -A 2>&1 | Out-Null
        & git -C $dep commit -qm 'local work' 2>&1 | Out-Null
        $script:Repairs.Clear()
        Repair-DeployTree -DeployRoot $dep
        if (-not ($script:Repairs | Where-Object { $_ -match 'REFUSED' })) {
            $fail.Add('a divergent deploy tree was not REFUSED — automation must never force this')
        }

        # Mount parsing: a declared destination must be extracted.
        $composeDir = Join-Path $tmp 'c/.DEPLOYMENT/compose'
        New-Item -ItemType Directory -Path $composeDir -Force | Out-Null
        $cf = Join-Path $composeDir 'docker-compose.aitheros.yml'
        Set-Content $cf @'
services:
  aither-worker:
    volumes:
      - .\AitherOS\dev\tools:/app/AitherOS/dev/tools:ro
      - named-vol:/data
'@
        $declared = Get-DeclaredMountSources -ComposePath $cf
        if ($declared['aither-worker'] -notcontains '/app/AitherOS/dev/tools') {
            $fail.Add("declared bind mount not parsed; got: $($declared['aither-worker'] -join ', ')")
        }

        # The source-tree filter must keep source mounts and drop the rest, or the check
        # reports named volumes and cert paths as missing (it did, on its first live run).
        $srcRe = '^/app/(AitherOS/)?(lib|services|config|dev|apps)(/|$)'
        foreach ($keep in @('/app/AitherOS/dev/tools', '/app/lib', '/app/AitherOS/config')) {
            if ($keep -notmatch $srcRe) { $fail.Add("source-tree filter wrongly EXCLUDES $keep") }
        }
        foreach ($drop in @('/data', '/certs', '/root/.cache/vllm', '/var/lib/grafana', '/output')) {
            if ($drop -match $srcRe) { $fail.Add("source-tree filter wrongly INCLUDES $drop") }
        }
    } finally {
        $script:Findings.Clear(); $script:Repairs.Clear()
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($fail.Count -gt 0) {
        Write-Host 'SELF-TEST FAILED' -ForegroundColor Red
        $fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        return 1
    }
    Write-Host 'SELF-TEST PASSED — detects behind/missing/unattached, restores absent files, REFUSES a divergent tree' -ForegroundColor Green
    return 0
}

# ---------------------------------------------------------------------------- #
# Main
# ---------------------------------------------------------------------------- #

if ($SelfTest) { exit (Invoke-SelfTest) }

$repoRoot = Get-RepoRoot
if (-not $repoRoot) {
    $msg = "could not find the enclosing git checkout above $PSScriptRoot"
    if ($Json) { [pscustomobject]@{ ok = $false; determined = $false; reason = $msg } | ConvertTo-Json -Compress }
    else { Write-Host "CANNOT DETERMINE: $msg" -ForegroundColor Yellow }
    exit 2
}
$deployRoot = Get-DeployRoot -Fallback $repoRoot

if (-not $deployRoot) {
    $msg = 'could not determine the deploy root: no running container carried a compose project label (is docker up?)'
    if ($Json) { [pscustomobject]@{ ok = $false; determined = $false; reason = $msg } | ConvertTo-Json -Compress }
    else { Write-Host "CANNOT DETERMINE: $msg" -ForegroundColor Yellow }
    exit 2   # never 0 — an undetermined answer is not a clean one
}

$sameTree = ($repoRoot.TrimEnd('\', '/') -ieq $deployRoot.TrimEnd('\', '/'))

if (-not $Json) {
    Write-Host ''
    Write-Host 'Deploy-root drift' -ForegroundColor Cyan
    Write-Host "  repo tree   : $repoRoot"
    Write-Host "  deploy tree : $deployRoot$(if ($sameTree) { '  (same tree — no split on this host)' })"
    Write-Host ''
}

if (-not $sameTree -and -not $MountsOnly) {
    Test-TreeReconciliation -RepoRoot $repoRoot -DeployRoot $deployRoot
    Test-DeployCriticalPaths -DeployRoot $deployRoot
}
$needRecreate = Test-RunningMounts -DeployRoot $deployRoot

if ($Fix) {
    if (-not $sameTree -and -not $MountsOnly) { Repair-DeployTree -DeployRoot $deployRoot }
    if (-not $SkipRecreate) { Repair-Mounts -DeployRoot $deployRoot -NeedRecreate $needRecreate }
    elseif ($needRecreate.Count -gt 0) {
        $script:Repairs.Add("skipped $($needRecreate.Count) recreate(s) (-SkipRecreate)")
    }

    # Re-verify: a repair is not done because it ran, it is done when the check passes.
    $script:Findings.Clear()
    if (-not $sameTree -and -not $MountsOnly) {
        Test-TreeReconciliation -RepoRoot $repoRoot -DeployRoot $deployRoot
        Test-DeployCriticalPaths -DeployRoot $deployRoot
    }
    $null = Test-RunningMounts -DeployRoot $deployRoot
}

$critical = @($script:Findings | Where-Object { $_.severity -eq 'CRITICAL' })

if ($Json) {
    [pscustomobject]@{
        ok         = ($critical.Count -eq 0)
        determined = $true
        repo_root  = $repoRoot
        deploy_root = $deployRoot
        same_tree  = $sameTree
        findings   = @($script:Findings)
        critical   = $critical.Count
        repairs    = @($script:Repairs)
        reason     = if ($critical.Count -eq 0) { 'deploy tree matches the repo tree and the fleet is on it' }
                     else { ($critical | ForEach-Object { $_.detail }) -join '; ' }
    } | ConvertTo-Json -Depth 6 -Compress
} else {
    if ($script:Repairs.Count -gt 0) {
        Write-Host 'Repairs:' -ForegroundColor Cyan
        $script:Repairs | ForEach-Object { Write-Host "  - $_" }
        Write-Host ''
    }
    if ($script:Findings.Count -eq 0) {
        Write-Host 'OK - the deploy tree matches the repo tree and the fleet is running on it' -ForegroundColor Green
    } else {
        foreach ($f in $script:Findings) {
            $c = if ($f.severity -eq 'CRITICAL') { 'Red' } else { 'Yellow' }
            Write-Host "[$($f.severity)] $($f.check)" -ForegroundColor $c
            Write-Host "    $($f.detail)"
            if ($f.remedy) { Write-Host "    -> $($f.remedy)" -ForegroundColor DarkGray }
        }
        Write-Host ''
        if (-not $Fix) { Write-Host 'Re-run with -Fix to apply the safe repairs.' -ForegroundColor DarkGray }
    }
}

exit ($(if ($critical.Count -eq 0) { 0 } else { 1 }))
