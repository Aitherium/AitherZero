#Requires -Version 7.0

<#
.SYNOPSIS
    Conversation threading for AitherZero LLM sessions.

.DESCRIPTION
    Provides persistent conversation catalogs with project-scoped threading.
    Adapted from PSUnplugged's threading model for AitherZero playbook sessions.

    Threads are stored as JSONL files in the configured threads directory,
    enabling multi-turn LLM interactions across playbook steps and scripts.

.NOTES
    Category: AI/Private
    Platform: Windows, Linux, macOS
#>

# ─── Thread Storage ─────────────────────────────────────────────────────

function Get-ThreadsDirectory {
    [CmdletBinding()]
    param()

    $base = if ($env:AITHERZERO_THREADS_PATH) {
        $env:AITHERZERO_THREADS_PATH
    } else {
        $moduleRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
        Join-Path $moduleRoot 'library' 'logs' 'threads'
    }

    if (-not (Test-Path $base)) {
        New-Item -ItemType Directory -Path $base -Force | Out-Null
    }
    return $base
}

function Get-ThreadPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId
    )

    $dir = Get-ThreadsDirectory
    return Join-Path $dir "$ThreadId.jsonl"
}

# ─── Public Thread API ──────────────────────────────────────────────────

function New-AitherThread {
    <#
    .SYNOPSIS
        Creates a new conversation thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ProjectScope,

        [Parameter()]
        [hashtable]$Metadata = @{}
    )

    $threadId = [System.Guid]::NewGuid().ToString('N').Substring(0, 12)

    $header = @{
        type       = 'thread_header'
        thread_id  = $threadId
        name       = if ($Name) { $Name } else { "thread-$threadId" }
        project    = if ($ProjectScope) { $ProjectScope } else { (Split-Path (Get-Location) -Leaf) }
        created_at = (Get-Date -Format 'o')
        metadata   = $Metadata
    }

    $path = Get-ThreadPath -ThreadId $threadId
    $header | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $path -Encoding utf8

    return [PSCustomObject]@{
        ThreadId  = $threadId
        Name      = $header.name
        Project   = $header.project
        Path      = $path
        CreatedAt = $header.created_at
    }
}

function Add-AitherThreadMessage {
    <#
    .SYNOPSIS
        Appends a message to a conversation thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [Parameter(Mandatory)]
        [ValidateSet('system', 'user', 'assistant')]
        [string]$Role,

        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter()]
        [string]$Model,

        [Parameter()]
        [hashtable]$Metadata = @{}
    )

    $entry = @{
        type       = 'message'
        role       = $Role
        content    = $Content
        timestamp  = (Get-Date -Format 'o')
        model      = $Model
        metadata   = $Metadata
    }

    $path = Get-ThreadPath -ThreadId $ThreadId
    if (-not (Test-Path $path)) {
        Write-Error "Thread $ThreadId not found"
        return
    }

    $entry | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $path -Encoding utf8 -Append
}

function Get-AitherThreadMessages {
    <#
    .SYNOPSIS
        Reads all messages from a conversation thread.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [Parameter()]
        [int]$Last = 0
    )

    $path = Get-ThreadPath -ThreadId $ThreadId
    if (-not (Test-Path $path)) {
        Write-Error "Thread $ThreadId not found"
        return @()
    }

    $lines = Get-Content -Path $path -Encoding utf8
    $messages = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            if ($entry.type -eq 'message') {
                $messages += $entry
            }
        } catch {
            Write-Verbose "Skipping malformed thread entry: $line"
        }
    }

    if ($Last -gt 0 -and $messages.Count -gt $Last) {
        $messages = $messages[($messages.Count - $Last)..($messages.Count - 1)]
    }

    return $messages
}

function Get-AitherThreadList {
    <#
    .SYNOPSIS
        Lists all conversation threads, optionally filtered by project.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Project,

        [Parameter()]
        [int]$Limit = 20
    )

    $dir = Get-ThreadsDirectory
    $files = Get-ChildItem -Path $dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First ($Limit * 2)  # over-fetch to account for project filtering

    $threads = @()
    foreach ($f in $files) {
        $firstLine = Get-Content -Path $f.FullName -TotalCount 1 -Encoding utf8
        if (-not $firstLine) { continue }
        try {
            $header = $firstLine | ConvertFrom-Json
            if ($header.type -ne 'thread_header') { continue }
            if ($Project -and $header.project -ne $Project) { continue }

            $lineCount = (Get-Content -Path $f.FullName -Encoding utf8 | Where-Object { $_ -match '"type"\s*:\s*"message"' }).Count

            $threads += [PSCustomObject]@{
                ThreadId  = $header.thread_id
                Name      = $header.name
                Project   = $header.project
                Messages  = $lineCount
                CreatedAt = $header.created_at
                LastActive = $f.LastWriteTime
            }
        } catch {
            continue
        }

        if ($threads.Count -ge $Limit) { break }
    }

    return $threads
}

function Remove-AitherThread {
    <#
    .SYNOPSIS
        Deletes a conversation thread.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId
    )

    $path = Get-ThreadPath -ThreadId $ThreadId
    if (Test-Path $path) {
        if ($PSCmdlet.ShouldProcess($path, "Remove thread $ThreadId")) {
            Remove-Item -Path $path -Force
        }
    } else {
        Write-Warning "Thread $ThreadId not found"
    }
}

function ConvertTo-ChatMessages {
    <#
    .SYNOPSIS
        Converts thread messages to OpenAI-compatible chat message format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ThreadId,

        [Parameter()]
        [int]$MaxMessages = 20,

        [Parameter()]
        [string]$SystemPrompt
    )

    $messages = @()

    if ($SystemPrompt) {
        $messages += @{ role = 'system'; content = $SystemPrompt }
    }

    $threadMessages = Get-AitherThreadMessages -ThreadId $ThreadId -Last $MaxMessages
    foreach ($msg in $threadMessages) {
        $messages += @{ role = $msg.role; content = $msg.content }
    }

    return $messages
}

# ─── Exports ────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'New-AitherThread'
    'Add-AitherThreadMessage'
    'Get-AitherThreadMessages'
    'Get-AitherThreadList'
    'Remove-AitherThread'
    'ConvertTo-ChatMessages'
)
