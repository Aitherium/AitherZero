#Requires -Version 7.0
<#
.SYNOPSIS
    Unified Flight Deck — shows ALL in-flight requests, queues, GPU state, and background processes.

.DESCRIPTION
    Polls every major AitherOS service to build a single unified view of:
    - GPU VRAM usage and contention (nvidia-smi)
    - LLM queue depth, in-flight, and waiting requests (MicroScheduler)
    - vLLM backend status (active requests, KV cache, throughput)
    - ComfyUI / ComfyUI-3D job queues (image gen, 3D gen)
    - MeshGen current job status
    - Genesis ResilientQueue depths and dead letters
    - Genesis internal jobs (executor, routines, swarm sessions)
    - A2A Gateway tasks
    - Automation/Scheduler routines and jobs
    - Agent heartbeats and activity
    - Gateway in-flight requests
    - MCP bridge status
    - Watch service alerts
    - Pulse pain signals and event rates

.PARAMETER Watch
    Continuously refresh every N seconds (0 = single pass).

.PARAMETER Json
    Output as JSON for automation.

.PARAMETER Compact
    Compact output — only show non-empty queues and active work.

.PARAMETER Sections
    Comma-separated list of sections to show. Default: all.
    Valid: gpu,llm,comfyui,meshgen,genesis,agents,scheduler,gateway,mcp,pulse,watch

.EXAMPLE
    .\6010_Get-FlightDeck.ps1
    Single pass, full flight deck.

.EXAMPLE
    .\6010_Get-FlightDeck.ps1 -Watch 10 -Compact
    Refresh every 10s, only show active items.

.EXAMPLE
    .\6010_Get-FlightDeck.ps1 -Sections gpu,llm,comfyui -Watch 5
    Monitor only GPU + LLM + ComfyUI.

.NOTES
    Category: monitoring
    Dependencies: Docker, nvidia-smi, AitherOS services
    Platform: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [int]$Watch = 0,
    [switch]$Json,
    [switch]$Compact,
    [string]$Sections = "all"
)

$ErrorActionPreference = 'SilentlyContinue'

# ─── Section filter ──────────────────────────────────────────────────────────
$AllSections = @("gpu", "llm", "comfyui", "meshgen", "genesis", "agents", "scheduler", "gateway", "mcp", "pulse", "watch")
if ($Sections -eq "all") {
    $ActiveSections = $AllSections
} else {
    $ActiveSections = $Sections -split ',' | ForEach-Object { $_.Trim().ToLower() }
}

function Test-Section([string]$name) { $ActiveSections -contains $name }

# ─── HTTP helper with timeout ────────────────────────────────────────────────
function Get-ServiceData {
    param(
        [string]$Url,
        [string]$Label,
        [int]$TimeoutSec = 3
    )
    try {
        $r = Invoke-RestMethod -Uri $Url -Method GET -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $r
    } catch {
        return $null
    }
}

# ─── Color helpers ───────────────────────────────────────────────────────────
function Write-Section([string]$icon, [string]$title) {
    Write-Host ""
    Write-Host "  $icon " -NoNewline -ForegroundColor Cyan
    Write-Host "$title" -ForegroundColor White
    Write-Host "  $('─' * 70)" -ForegroundColor DarkGray
}

function Write-Metric([string]$label, $value, [string]$color = "Gray") {
    Write-Host "    " -NoNewline
    Write-Host "${label}: " -NoNewline -ForegroundColor DarkGray
    Write-Host "$value" -ForegroundColor $color
}

function Write-Alert([string]$msg) {
    Write-Host "    ⚠ $msg" -ForegroundColor Yellow
}

function Write-Critical([string]$msg) {
    Write-Host "    🔴 $msg" -ForegroundColor Red
}

function Write-Good([string]$msg) {
    Write-Host "    ✅ $msg" -ForegroundColor Green
}

function Get-ColorForPercent([int]$pct) {
    if ($pct -ge 90) { return "Red" }
    if ($pct -ge 70) { return "Yellow" }
    return "Green"
}

# ─── Main collection ─────────────────────────────────────────────────────────
function Collect-FlightDeck {
    $deck = [ordered]@{
        timestamp  = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        sections   = [ordered]@{}
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # GPU — nvidia-smi
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "gpu") {
        $gpu = [ordered]@{ available = $false }
        try {
            $raw = nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,memory.free,temperature.gpu,power.draw --format=csv,noheader,nounits 2>$null
            if ($raw) {
                $parts = $raw -split ','
                $gpu = [ordered]@{
                    available     = $true
                    utilization   = [int]$parts[0].Trim()
                    vram_used_mb  = [int]$parts[1].Trim()
                    vram_total_mb = [int]$parts[2].Trim()
                    vram_free_mb  = [int]$parts[3].Trim()
                    vram_pct      = [math]::Round(([int]$parts[1].Trim() / [int]$parts[2].Trim()) * 100, 1)
                    temp_c        = [int]$parts[4].Trim()
                    power_w       = [math]::Round([double]$parts[5].Trim(), 0)
                }
            }
            # GPU containers
            $gpuContainers = @()
            docker ps --format "{{.Names}}" 2>$null | ForEach-Object {
                $n = $_
                $dr = docker inspect $n --format '{{.HostConfig.DeviceRequests}}' 2>$null
                if ($dr -and $dr -ne '[]' -and $dr -ne '<no value>') {
                    $gpuContainers += $n
                }
            }
            $gpu["gpu_containers"] = $gpuContainers
        } catch {}
        $deck.sections["gpu"] = $gpu
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # LLM — MicroScheduler (8150) + vLLM
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "llm") {
        $llm = [ordered]@{}

        # MicroScheduler queue
        $sched = Get-ServiceData "http://localhost:8150/queue/stats"
        if ($sched) {
            $llm["scheduler"] = [ordered]@{
                queue_depth     = $sched.queue_depth
                processing      = $sched.processing_count
                vram_used_mb    = $sched.vram_used_mb
                models_loaded   = $sched.models_loaded
                avg_wait_ms     = $sched.avg_wait_ms
                avg_exec_ms     = $sched.avg_exec_ms
            }
        }

        # Pending queue view
        $pending = Get-ServiceData "http://localhost:8150/queue/view"
        if ($pending) {
            $llm["pending_requests"] = @($pending).Count
            $llm["pending_detail"] = @($pending) | Select-Object -First 10 | ForEach-Object {
                [ordered]@{
                    task_id  = $_.task_id
                    source   = $_.source
                    priority = $_.priority
                    model    = $_.model
                    wait_s   = $_.wait_seconds
                }
            }
        }

        # Task stats
        $tstats = Get-ServiceData "http://localhost:8150/tasks/stats"
        if ($tstats) { $llm["task_stats"] = $tstats }

        # VRAM coordination
        $vram = Get-ServiceData "http://localhost:8150/vram/status"
        if ($vram) {
            $llm["vram_coordinator"] = [ordered]@{
                total_vram_mb  = $vram.total_vram_mb
                allocated_mb   = $vram.allocated_mb
                free_mb        = $vram.free_mb
                slots          = $vram.slot_states
                active_agents  = $vram.active_agents
                warm_models    = $vram.warm_manifest
                active_swarms  = $vram.active_swarm_sessions
            }
        }

        # Capacity
        $cap = Get-ServiceData "http://localhost:8150/capacity"
        if ($cap) { $llm["capacity"] = $cap }

        # vLLM backend (direct — usually behind MicroScheduler)
        $vllm = Get-ServiceData "http://localhost:8120/health"
        if ($vllm) { $llm["vllm_healthy"] = $true }

        # Agent activity
        $agentAct = Get-ServiceData "http://localhost:8150/agents/activity"
        if ($agentAct) { $llm["agent_activity"] = $agentAct }

        # Online agents
        $online = Get-ServiceData "http://localhost:8150/agents/online"
        if ($online) { $llm["online_agents"] = $online }

        $deck.sections["llm"] = $llm
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # ComfyUI + ComfyUI-3D queues
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "comfyui") {
        $comfy = [ordered]@{}

        # ComfyUI (2D image gen — port 8188)
        $q2d = Get-ServiceData "http://localhost:8188/queue"
        if ($q2d) {
            $comfy["comfyui_2d"] = [ordered]@{
                running = @($q2d.queue_running).Count
                pending = @($q2d.queue_pending).Count
            }
            if (@($q2d.queue_running).Count -gt 0) {
                $comfy["comfyui_2d"]["running_jobs"] = @($q2d.queue_running) | ForEach-Object {
                    if ($_) { $_[1] }
                }
            }
        }

        # ComfyUI-3D (Hunyuan3D — port 8289)
        $q3d = Get-ServiceData "http://localhost:8289/queue"
        if ($q3d) {
            $comfy["comfyui_3d"] = [ordered]@{
                running = @($q3d.queue_running).Count
                pending = @($q3d.queue_pending).Count
            }
            if (@($q3d.queue_running).Count -gt 0) {
                $comfy["comfyui_3d"]["running_jobs"] = @($q3d.queue_running) | ForEach-Object {
                    if ($_) { $_[1] }
                }
            }
        }

        # ComfyUI-3D history — check last completed job
        $hist = Get-ServiceData "http://localhost:8289/history"
        if ($hist) {
            $lastKey = $hist.PSObject.Properties | Select-Object -Last 1
            if ($lastKey) {
                $comfy["last_3d_job"] = [ordered]@{
                    prompt_id = $lastKey.Name
                    status    = $lastKey.Value.status.status_str
                    completed = $lastKey.Value.status.completed
                }
            }
        }

        $deck.sections["comfyui"] = $comfy
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # MeshGen (8788) — current job
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "meshgen") {
        $mesh = [ordered]@{}
        $mh = Get-ServiceData "http://localhost:8788/health"
        if ($mh) {
            $mesh["healthy"]    = $true
            $mesh["uptime_sec"] = $mh.uptime_sec
        } else {
            $mesh["healthy"] = $false
        }

        # Parse latest docker logs for TexGen/ShapeGen progress
        try {
            $logs = docker logs aitheros-meshgen --tail 5 2>&1 | Out-String
            if ($logs -match 'Still generating (\w+)\.\.\. \((\d+)s\)') {
                $mesh["current_phase"] = $Matches[1]
                $mesh["elapsed_sec"]   = [int]$Matches[2]
            } elseif ($logs -match 'completed|saved|exported') {
                $mesh["current_phase"] = "idle"
            } else {
                $mesh["current_phase"] = "idle"
            }
        } catch {}

        $deck.sections["meshgen"] = $mesh
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Genesis (8001) — queues, jobs, routines, swarm
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "genesis") {
        $gen = [ordered]@{}

        # ResilientQueue stats
        $qs = Get-ServiceData "http://localhost:8001/queues/stats"
        if ($qs) {
            $gen["queues"] = [ordered]@{
                total_pending      = $qs.total_pending
                total_processing   = $qs.total_processing
                total_dead_letter  = $qs.total_dead_letter
                queue_depths       = $qs.queue_depths
                worker_running     = $qs.worker_running
            }
        }

        # Internal jobs (executor)
        $jobs = Get-ServiceData "http://localhost:8001/internals/jobs/status"
        if ($jobs -and $jobs.available -ne $false) {
            $gen["jobs"] = [ordered]@{
                active    = $jobs.active_count
                completed = $jobs.completed_count
                queued    = $jobs.queued_count
            }
            if ($jobs.active_jobs) {
                $gen["jobs"]["active_list"] = $jobs.active_jobs
            }
        }

        # Swarm sessions
        $swarm = Get-ServiceData "http://localhost:8001/internals/swarm/sessions"
        if ($swarm -and $swarm.available -ne $false) {
            $gen["swarm_sessions"] = $swarm.sessions
        }

        # Routines
        $rout = Get-ServiceData "http://localhost:8001/internals/routines/detail"
        if ($rout -and $rout.available -ne $false) {
            $running = @($rout.routines | Where-Object { $_.status -eq "running" })
            $gen["routines_running"] = $running.Count
            if ($running.Count -gt 0) {
                $gen["routines_active"] = $running | ForEach-Object {
                    [ordered]@{ name = $_.name; priority = $_.priority }
                }
            }
        }

        # Circuit breakers
        $cb = Get-ServiceData "http://localhost:8001/internals/circuits/status"
        if ($cb -and $cb.available -ne $false) {
            $open = $cb.circuits | Where-Object { $_.state -eq "open" }
            if ($open) {
                $gen["open_circuit_breakers"] = @($open) | ForEach-Object { $_.name }
            }
        }

        # Boot status
        $boot = Get-ServiceData "http://localhost:8001/internals/boot/status"
        if ($boot -and $boot.available -ne $false) {
            $gen["boot_phase"] = $boot.phase
        }

        # LLM queue (proxied via Genesis)
        $llmq = Get-ServiceData "http://localhost:8001/llm/queue"
        if ($llmq) { $gen["llm_queue"] = $llmq }

        # Expedition status
        $exp = Get-ServiceData "http://localhost:8001/expedition/status"
        if ($exp) { $gen["expedition"] = $exp }

        # Demand metrics
        $demand = Get-ServiceData "http://localhost:8001/demand/metrics"
        if ($demand) { $gen["demand"] = $demand }

        $deck.sections["genesis"] = $gen
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Agents — A2A Gateway + agent heartbeats
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "agents") {
        $agents = [ordered]@{}

        # A2A registered agents
        $a2a = Get-ServiceData "http://localhost:8009/agents"
        if ($a2a) { $agents["registered"] = @($a2a).Count }

        # A2A skills
        $skills = Get-ServiceData "http://localhost:8009/skills"
        if ($skills) { $agents["total_skills"] = @($skills).Count }

        # Watch agent tracking
        $wa = Get-ServiceData "http://localhost:8082/agents"
        if ($wa) {
            $active = @($wa | Where-Object { $_.status -eq "active" -or $_.heartbeat_age_sec -lt 60 })
            $agents["active_agents"]   = $active.Count
            $agents["total_tracked"]   = @($wa).Count
            if ($active.Count -gt 0) {
                $agents["active_list"] = $active | ForEach-Object { $_.name }
            }
        }

        $deck.sections["agents"] = $agents
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Scheduler / AutomationCore (8109)
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "scheduler") {
        $sched = [ordered]@{}

        $ss = Get-ServiceData "http://localhost:8109/scheduler/status"
        if ($ss) {
            $sched["running"]    = $ss.running
            $sched["tick_count"] = $ss.tick_count
            $sched["uptime_sec"] = $ss.uptime_sec
        }

        # Routine queue
        $rq = Get-ServiceData "http://localhost:8109/routines/queue"
        if ($rq) { $sched["routine_queue"] = @($rq).Count }

        # Active jobs
        $sj = Get-ServiceData "http://localhost:8109/jobs"
        if ($sj) {
            $activeJobs = @($sj | Where-Object { $_.status -eq "active" -or $_.status -eq "running" })
            $sched["active_jobs"] = $activeJobs.Count
            if ($activeJobs.Count -gt 0) {
                $sched["active_job_list"] = $activeJobs | Select-Object -First 10 | ForEach-Object {
                    [ordered]@{ id = $_.id; name = $_.name; status = $_.status }
                }
            }
        }

        # Paused routines
        $paused = Get-ServiceData "http://localhost:8109/routines/paused"
        if ($paused) { $sched["paused_routines"] = @($paused).Count }

        # Kernel tick
        $kt = Get-ServiceData "http://localhost:8109/kernel/status"
        if ($kt) {
            $sched["kernel_effort"]       = $kt.effort
            $sched["kernel_active_agents"] = $kt.active_agents
        }

        $deck.sections["scheduler"] = $sched
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Gateway
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "gateway") {
        $gw = [ordered]@{}

        $gs = Get-ServiceData "http://localhost:8009/gateway/stats"
        if ($gs) { $gw["stats"] = $gs }

        # External gateway
        $eg = Get-ServiceData "http://localhost:8700/health"
        if ($eg) { $gw["external_healthy"] = $true }

        # Mesh topology
        $mesh = Get-ServiceData "http://localhost:8009/mesh/topology"
        if ($mesh) { $gw["mesh_nodes"] = @($mesh.nodes).Count }

        $deck.sections["gateway"] = $gw
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # MCP Bridges
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "mcp") {
        $mcp = [ordered]@{}
        $mcph = Get-ServiceData "http://localhost:8191/health"
        if ($mcph) {
            $mcp["healthy"] = $true
            $mcp["bridges"] = $mcph.bridges
        } else {
            $mcp["healthy"] = $false
        }
        $deck.sections["mcp"] = $mcp
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Pulse (8081) — events, pain, alerts
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "pulse") {
        $pulse = [ordered]@{}

        $ps = Get-ServiceData "http://localhost:8081/stats"
        if ($ps) {
            $pulse["uptime_sec"]     = $ps.uptime_sec
            $pulse["events_total"]   = $ps.events_total
            $pulse["events_per_sec"] = $ps.events_per_sec
            $pulse["ws_clients"]     = $ps.ws_clients
            $pulse["sse_clients"]    = $ps.sse_clients
            $pulse["active_alerts"]  = $ps.active_alerts
        }

        # Pain signals
        $pain = Get-ServiceData "http://localhost:8081/pain/active"
        if ($pain) {
            $pulse["pain_signals"] = @($pain).Count
            if (@($pain).Count -gt 0) {
                $pulse["pain_list"] = @($pain) | Select-Object -First 5 | ForEach-Object {
                    [ordered]@{ source = $_.source; severity = $_.severity; message = $_.message }
                }
            }
        }

        # Token burn rate
        $burn = Get-ServiceData "http://localhost:8081/tokens/burn-rate"
        if ($burn) { $pulse["token_burn_rate"] = $burn }

        $deck.sections["pulse"] = $pulse
    }

    # ═══════════════════════════════════════════════════════════════════════════
    # Watch (8082) — alerts, service health overview
    # ═══════════════════════════════════════════════════════════════════════════
    if (Test-Section "watch") {
        $watch = [ordered]@{}

        $wa = Get-ServiceData "http://localhost:8082/alerts"
        if ($wa) {
            $active = @($wa | Where-Object { $_.active -eq $true -or $_.resolved -ne $true })
            $watch["active_alerts"] = $active.Count
            if ($active.Count -gt 0) {
                $watch["alert_list"] = $active | Select-Object -First 5 | ForEach-Object {
                    [ordered]@{ source = $_.source; severity = $_.severity; message = $_.message }
                }
            }
        }

        # Startup status
        $startup = Get-ServiceData "http://localhost:8082/startup/status"
        if ($startup) {
            $watch["startup_phase"]    = $startup.phase
            $watch["startup_progress"] = $startup.progress
        }

        # Error history
        $errs = Get-ServiceData "http://localhost:8082/errors"
        if ($errs) { $watch["recent_errors"] = @($errs).Count }

        $deck.sections["watch"] = $watch
    }

    return $deck
}

# ─── Render (human-readable) ─────────────────────────────────────────────────
function Render-FlightDeck($deck) {
    $ts = $deck.timestamp
    Write-Host ""
    Write-Host "  ✈  " -NoNewline -ForegroundColor Cyan
    Write-Host "AitherOS Flight Deck" -NoNewline -ForegroundColor White
    Write-Host "  │  " -NoNewline -ForegroundColor DarkGray
    Write-Host "$ts" -ForegroundColor DarkGray
    Write-Host "  $('═' * 72)" -ForegroundColor DarkGray

    # --- GPU ---
    $gpu = $deck.sections["gpu"]
    if ($gpu -and $gpu.available) {
        Write-Section "🖥" "GPU"
        $pct = $gpu.vram_pct
        $color = Get-ColorForPercent $pct
        Write-Metric "VRAM" "$($gpu.vram_used_mb) / $($gpu.vram_total_mb) MB ($pct%)" $color
        Write-Metric "Free" "$($gpu.vram_free_mb) MB" $(if ($gpu.vram_free_mb -lt 2000) { "Red" } else { "Green" })
        Write-Metric "Utilization" "$($gpu.utilization)%" $(Get-ColorForPercent $gpu.utilization)
        Write-Metric "Temp" "$($gpu.temp_c)°C" $(if ($gpu.temp_c -gt 80) { "Red" } elseif ($gpu.temp_c -gt 70) { "Yellow" } else { "Green" })
        Write-Metric "Power" "$($gpu.power_w)W"
        if ($gpu.gpu_containers) {
            Write-Metric "GPU Containers" ($gpu.gpu_containers -join ", ") "Cyan"
        }
    }

    # --- LLM ---
    $llm = $deck.sections["llm"]
    if ($llm) {
        Write-Section "🧠" "LLM Queue (MicroScheduler:8150)"
        $s = $llm.scheduler
        if ($s) {
            $qd = $s.queue_depth
            $qcolor = if ($qd -gt 10) { "Red" } elseif ($qd -gt 3) { "Yellow" } else { "Green" }
            Write-Metric "Queue Depth" $qd $qcolor
            Write-Metric "Processing" $s.processing "Cyan"
            if ($s.vram_used_mb) { Write-Metric "Sched VRAM" "$($s.vram_used_mb) MB" }
            if ($s.models_loaded) { Write-Metric "Models Loaded" ($s.models_loaded -join ", ") }
            if ($s.avg_wait_ms) { Write-Metric "Avg Wait" "$($s.avg_wait_ms) ms" }
            if ($s.avg_exec_ms) { Write-Metric "Avg Exec" "$($s.avg_exec_ms) ms" }
        }
        if ($llm.pending_requests -and $llm.pending_requests -gt 0) {
            Write-Alert "Pending requests: $($llm.pending_requests)"
            $llm.pending_detail | ForEach-Object {
                Write-Host "      " -NoNewline
                Write-Host "[$($_.priority)] $($_.source)" -NoNewline -ForegroundColor Yellow
                Write-Host " → $($_.model) (wait: $($_.wait_s)s)" -ForegroundColor DarkGray
            }
        }
        if ($llm.vram_coordinator) {
            $vc = $llm.vram_coordinator
            if ($vc.active_agents -and @($vc.active_agents).Count -gt 0) {
                Write-Metric "Active Agents" (@($vc.active_agents) -join ", ") "Cyan"
            }
            if ($vc.active_swarms -and @($vc.active_swarms).Count -gt 0) {
                Write-Metric "Swarm Sessions" @($vc.active_swarms).Count "Magenta"
            }
            if ($vc.slots) {
                $busySlots = @()
                $vc.slots.PSObject.Properties | ForEach-Object {
                    $slotName = $_.Name
                    $slotVal = $_.Value
                    if ($slotVal -and ($slotVal.active -eq $true -or $slotVal.acquired -eq $true)) {
                        $busySlots += $slotName
                    }
                }
                if ($busySlots.Count -gt 0) {
                    Write-Metric "Busy VRAM Slots" ($busySlots -join ", ") "Yellow"
                }
            }
        }
        if ($llm.online_agents -and @($llm.online_agents).Count -gt 0) {
            Write-Metric "Online Agents" @($llm.online_agents).Count "Green"
        }
        if ($llm.agent_activity) {
            $aa = $llm.agent_activity
            if ($aa.running -and @($aa.running).Count -gt 0) {
                Write-Metric "Agent Tasks Running" @($aa.running).Count "Cyan"
            }
            if ($aa.queued -and @($aa.queued).Count -gt 0) {
                Write-Alert "Agent Tasks Queued: $(@($aa.queued).Count)"
            }
        }
    }

    # --- ComfyUI ---
    $comfy = $deck.sections["comfyui"]
    if ($comfy) {
        $has2d = $comfy.comfyui_2d -and ($comfy.comfyui_2d.running -gt 0 -or $comfy.comfyui_2d.pending -gt 0)
        $has3d = $comfy.comfyui_3d -and ($comfy.comfyui_3d.running -gt 0 -or $comfy.comfyui_3d.pending -gt 0)
        if (-not $Compact -or $has2d -or $has3d) {
            Write-Section "🎨" "ComfyUI Queues"
            if ($comfy.comfyui_2d) {
                $c2 = $comfy.comfyui_2d
                $status = if ($c2.running -gt 0) { "RUNNING ($($c2.running))" } else { "idle" }
                $color = if ($c2.running -gt 0) { "Yellow" } else { "Green" }
                Write-Metric "2D (SDXL:8188)" "$status  pending: $($c2.pending)" $color
            }
            if ($comfy.comfyui_3d) {
                $c3 = $comfy.comfyui_3d
                $status = if ($c3.running -gt 0) { "RUNNING ($($c3.running))" } else { "idle" }
                $color = if ($c3.running -gt 0) { "Yellow" } else { "Green" }
                Write-Metric "3D (Hunyuan:8289)" "$status  pending: $($c3.pending)" $color
                if ($c3.running_jobs) {
                    $c3.running_jobs | ForEach-Object { Write-Host "      job: $_" -ForegroundColor DarkYellow }
                }
            }
        }
    }

    # --- MeshGen ---
    $mesh = $deck.sections["meshgen"]
    if ($mesh) {
        if (-not $Compact -or $mesh.current_phase -ne "idle") {
            Write-Section "🏗" "MeshGen (Hunyuan3D:8788)"
            $phase = $mesh.current_phase
            if ($phase -and $phase -ne "idle") {
                Write-Metric "Phase" $phase "Yellow"
                Write-Metric "Elapsed" "$($mesh.elapsed_sec)s" $(if ($mesh.elapsed_sec -gt 600) { "Red" } else { "Yellow" })
            } else {
                Write-Good "Idle"
            }
        }
    }

    # --- Genesis ---
    $gen = $deck.sections["genesis"]
    if ($gen) {
        $hasWork = ($gen.queues -and $gen.queues.total_pending -gt 0) -or
                   ($gen.jobs -and $gen.jobs.active -gt 0) -or
                   ($gen.swarm_sessions -and @($gen.swarm_sessions).Count -gt 0) -or
                   ($gen.routines_running -and $gen.routines_running -gt 0) -or
                   ($gen.open_circuit_breakers -and @($gen.open_circuit_breakers).Count -gt 0)

        if (-not $Compact -or $hasWork) {
            Write-Section "⚡" "Genesis (8001)"
            if ($gen.queues) {
                $q = $gen.queues
                Write-Metric "Queue Pending" $q.total_pending $(if ($q.total_pending -gt 50) { "Red" } elseif ($q.total_pending -gt 10) { "Yellow" } else { "Green" })
                Write-Metric "Queue Processing" $q.total_processing "Cyan"
                if ($q.total_dead_letter -gt 0) {
                    Write-Critical "Dead Letters: $($q.total_dead_letter)"
                }
                if ($q.queue_depths) {
                    $q.queue_depths.PSObject.Properties | Where-Object { $_.Value -gt 0 } | ForEach-Object {
                        Write-Host "      $($_.Name): $($_.Value)" -ForegroundColor DarkYellow
                    }
                }
            }
            if ($gen.jobs -and $gen.jobs.active -gt 0) {
                Write-Metric "Active Jobs" $gen.jobs.active "Cyan"
                $gen.jobs.active_list | ForEach-Object {
                    Write-Host "      $_" -ForegroundColor DarkCyan
                }
            }
            if ($gen.swarm_sessions -and @($gen.swarm_sessions).Count -gt 0) {
                Write-Metric "Swarm Sessions" @($gen.swarm_sessions).Count "Magenta"
            }
            if ($gen.routines_running -gt 0) {
                Write-Metric "Routines Running" $gen.routines_running "Yellow"
                $gen.routines_active | ForEach-Object {
                    Write-Host "      $($_.name) (pri: $($_.priority))" -ForegroundColor DarkYellow
                }
            }
            if ($gen.open_circuit_breakers) {
                Write-Critical "Open Circuit Breakers: $($gen.open_circuit_breakers -join ', ')"
            }
        }
    }

    # --- Agents ---
    $agents = $deck.sections["agents"]
    if ($agents -and (-not $Compact -or ($agents.active_agents -and $agents.active_agents -gt 0))) {
        Write-Section "🤖" "Agents"
        if ($agents.registered) { Write-Metric "A2A Registered" $agents.registered }
        if ($agents.total_skills) { Write-Metric "Total Skills" $agents.total_skills }
        if ($agents.active_agents) { Write-Metric "Active" $agents.active_agents "Green" }
        if ($agents.active_list) {
            Write-Host "      $($agents.active_list -join ', ')" -ForegroundColor DarkCyan
        }
    }

    # --- Scheduler ---
    $sched = $deck.sections["scheduler"]
    if ($sched -and (-not $Compact -or ($sched.active_jobs -and $sched.active_jobs -gt 0))) {
        Write-Section "⏰" "Scheduler (AutomationCore:8109)"
        if ($sched.running -ne $null) { Write-Metric "Running" $sched.running $(if ($sched.running) { "Green" } else { "Red" }) }
        if ($sched.routine_queue) { Write-Metric "Routine Queue" $sched.routine_queue }
        if ($sched.active_jobs -and $sched.active_jobs -gt 0) {
            Write-Metric "Active Jobs" $sched.active_jobs "Cyan"
            $sched.active_job_list | ForEach-Object {
                Write-Host "      $($_.name) [$($_.status)]" -ForegroundColor DarkCyan
            }
        }
        if ($sched.kernel_effort) { Write-Metric "Kernel Effort" $sched.kernel_effort }
    }

    # --- Gateway ---
    $gw = $deck.sections["gateway"]
    if ($gw -and -not $Compact) {
        Write-Section "🌐" "Gateway"
        if ($gw.stats) { Write-Metric "Stats" ($gw.stats | ConvertTo-Json -Compress -Depth 2) }
        if ($gw.external_healthy) { Write-Good "External gateway healthy" }
        if ($gw.mesh_nodes) { Write-Metric "Mesh Nodes" $gw.mesh_nodes }
    }

    # --- MCP ---
    $mcp = $deck.sections["mcp"]
    if ($mcp -and -not $Compact) {
        Write-Section "🔧" "MCP Bridges"
        Write-Metric "Healthy" $mcp.healthy $(if ($mcp.healthy) { "Green" } else { "Red" })
    }

    # --- Pulse ---
    $pulse = $deck.sections["pulse"]
    if ($pulse) {
        $hasPain = $pulse.pain_signals -and $pulse.pain_signals -gt 0
        $hasAlerts = $pulse.active_alerts -and $pulse.active_alerts -gt 0
        if (-not $Compact -or $hasPain -or $hasAlerts) {
            Write-Section "💓" "Pulse (8081)"
            if ($pulse.events_per_sec) { Write-Metric "Events/sec" $pulse.events_per_sec }
            if ($pulse.ws_clients) { Write-Metric "WS Clients" $pulse.ws_clients }
            if ($pulse.active_alerts -and $pulse.active_alerts -gt 0) {
                Write-Alert "Active Alerts: $($pulse.active_alerts)"
            }
            if ($pulse.pain_signals -gt 0) {
                Write-Critical "Pain Signals: $($pulse.pain_signals)"
                $pulse.pain_list | ForEach-Object {
                    Write-Host "      [$($_.severity)] $($_.source): $($_.message)" -ForegroundColor Red
                }
            }
            if ($pulse.token_burn_rate) { Write-Metric "Token Burn" $pulse.token_burn_rate }
        }
    }

    # --- Watch ---
    $watch = $deck.sections["watch"]
    if ($watch) {
        $hasIssues = ($watch.active_alerts -and $watch.active_alerts -gt 0) -or ($watch.recent_errors -and $watch.recent_errors -gt 0)
        if (-not $Compact -or $hasIssues) {
            Write-Section "👁" "Watch (8082)"
            if ($watch.active_alerts -gt 0) {
                Write-Alert "Active Alerts: $($watch.active_alerts)"
                $watch.alert_list | ForEach-Object {
                    Write-Host "      [$($_.severity)] $($_.source): $($_.message)" -ForegroundColor Yellow
                }
            } else {
                Write-Good "No active alerts"
            }
            if ($watch.recent_errors -gt 0) { Write-Metric "Recent Errors" $watch.recent_errors "Yellow" }
        }
    }

    Write-Host ""
    Write-Host "  $('═' * 72)" -ForegroundColor DarkGray
    Write-Host ""
}

# ─── Main loop ───────────────────────────────────────────────────────────────
do {
    $deck = Collect-FlightDeck

    if ($Json) {
        $deck | ConvertTo-Json -Depth 10
    } else {
        if ($Watch -gt 0) { Clear-Host }
        Render-FlightDeck $deck
    }

    if ($Watch -gt 0) {
        Write-Host "  Refreshing in ${Watch}s... (Ctrl+C to stop)" -ForegroundColor DarkGray
        Start-Sleep -Seconds $Watch
    }
} while ($Watch -gt 0)
