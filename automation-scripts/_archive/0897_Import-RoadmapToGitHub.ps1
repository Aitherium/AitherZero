<#
.SYNOPSIS
    Import ROADMAP.md items into GitHub Issues and Projects.

.DESCRIPTION
    Parses the AitherOS/ROADMAP.md file and creates GitHub Issues for all
    priority items, including completed work. Links issues to a GitHub Project
    for visual tracking.

.PARAMETER ShowOutput
    Display verbose output during execution.

.PARAMETER DryRun
    Parse and display items without creating GitHub issues.

.PARAMETER IncludeCompleted
    Include completed items (creates closed issues for historical tracking).

.PARAMETER ProjectNumber
    GitHub Project number to link issues to (default: 3 for AitherOS).

.PARAMETER WithSubIssues
    Create parent issues for roadmap sections and link priority items as sub-issues.

.PARAMETER SetDates
    Set start_date and target_date fields on project items.

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -DryRun -ShowOutput
    Preview what issues would be created.

.EXAMPLE
    .\0897_Import-RoadmapToGitHub.ps1 -IncludeCompleted -ShowOutput
    Create all issues including completed work.
#>

[CmdletBinding()]
param(
    [switch]$ShowOutput,
    [switch]$DryRun,
    [switch]$IncludeCompleted,
    [switch]$WithSubIssues,
    [switch]$SetDates,
    [int]$ProjectNumber = 3
)

# Initialize AitherZero
. "$PSScriptRoot/_init.ps1"

$ErrorActionPreference = 'Stop'

# Use the project root from _init.ps1
$RepoRoot = $projectRoot

#region Configuration
$script:Config = @{
    RoadmapPath      = Join-Path $RepoRoot "AitherOS/ROADMAP.md"
    Owner            = "Aitherium"
    Repo             = "AitherZero-Internal"
    OutputPath       = Join-Path $RepoRoot "AitherZero/logs/roadmap-import.json"
    
    # GitHub Project V2 settings (Aitherium org)
    Project          = @{
        Owner        = "Aitherium"
        Number       = 3
        Id           = "PVT_kwDODOiKmc4BJSAr"
        Fields       = @{
            Status     = "PVTSSF_lADODOiKmc4BJSArzg5fers"
            Priority   = "PVTSSF_lADODOiKmc4BJSArzg5fet4"
            StartDate  = "PVTF_lADODOiKmc4BJSArzg5feuI"
            TargetDate = "PVTF_lADODOiKmc4BJSArzg5feuM"
        }
        StatusOptions = @{
            Backlog    = "f75ad846"
            Ready      = "08afe404"
            InProgress = "47fc9ee4"
            InReview   = "4cc61d42"
            Done       = "98236657"
        }
        PriorityOptions = @{
            P0 = "79628723"
            P1 = "0a877460"
            P2 = "da944a9c"
        }
        # Map roadmap status to GitHub Project column
        RoadmapToProjectStatus = @{
            '📋 Planned'     = 'Backlog'
            '🔥 Priority'    = 'Ready'
            '🔄 In Progress' = 'InProgress'
            '👀 In Review'   = 'InReview'
            '✅ Done'        = 'Done'
            '⏸️ Blocked'     = 'Backlog'  # Blocked goes to backlog with label
        }
    }
    
    # Label mappings
    Labels           = @{
        Layers     = @{
            'AitherOS'   = 'layer:aitheros'
            'AitherCore' = 'layer:aithercore'
            'AitherNode' = 'layer:aithernode'
        }
        Categories = @{
            'GPU'        = 'gpu-optimization'
            'Cloud'      = 'cloud-training'
            'Training'   = 'self-improvement'
            'Benchmark'  = 'benchmark'
            'Test'       = 'testing'
            'CI/CD'      = 'infrastructure'
            'MCP'        = 'mcp-server'
            'Agent'      = 'ai-agents'
            'Vision'     = 'vision'
            'Memory'     = 'memory'
            'Search'     = 'search'
            'UI'         = 'ui'
            'Security'   = 'security'
            'Monitoring' = 'monitoring'
            'Infrastructure' = 'infrastructure'
            'Discovery' = 'discovery'
            'Networking' = 'networking'
            'Tunnel' = 'infrastructure'
            'Automation' = 'infrastructure'
            'Redundancy' = 'infrastructure'
            'Core' = 'core'
            'Scanning' = 'discovery'
        }
        Status     = @{
            '✅ Done'        = 'status:done'
            '🔄 In Progress' = 'status:in-progress'
            '📋 Planned'     = 'status:planned'
            '🔥 Priority'    = 'status:ready'
            '👀 In Review'   = 'status:in-review'
            '⏸️ Blocked'     = 'status:blocked'
        }
        IssueTypes = @{
            'Bug'     = 'type:bug'
            'Feature' = 'type:feature'
            'Chore'   = 'type:chore'
            'Docs'    = 'type:docs'
            'Test'    = 'type:test'
        }
    }
}
#endregion

#region Functions

function Write-Output {
    param([string]$Message, [string]$Level = 'Info')
    if ($ShowOutput) {
        $prefix = switch ($Level) {
            'Success' { '✅' }
            'Warning' { '⚠️' }
            'Error' { '❌' }
            'Info' { 'ℹ️' }
            default { '  ' }
        }
        Write-Host "$prefix $Message"
    }
}

function Test-GitHubCLI {
    try {
        $null = gh --version
        $authStatus = gh auth status 2>&1
        return $authStatus -notmatch 'not logged in'
    }
    catch {
        return $false
    }
}

function Test-IssuesEnabled {
    <#
    .SYNOPSIS
        Check if issues are enabled for the repository.
    #>
    try {
        $repoInfo = gh repo view "$($script:Config.Owner)/$($script:Config.Repo)" --json hasIssuesEnabled 2>$null | ConvertFrom-Json
        return $repoInfo.hasIssuesEnabled
    }
    catch {
        return $false
    }
}

function Get-RoadmapSections {
    <#
    .SYNOPSIS
        Parse ROADMAP.md and extract all sections with priority items.
    #>
    param([string]$Content)
    
    $sections = @()
    
    # Pattern for section headers like "## 38. GPU Performance Optimization Suite"
    $sectionPattern = '(?m)^##\s+(\d+)\.\s+(.+?)$'
    $sectionMatches = [regex]::Matches($Content, $sectionPattern)
    
    foreach ($match in $sectionMatches) {
        $sectionNum = [int]$match.Groups[1].Value
        $sectionTitle = $match.Groups[2].Value.Trim()
        $sectionStart = $match.Index
        
        $sections += @{
            Number = $sectionNum
            Title  = $sectionTitle
            Start  = $sectionStart
        }
    }
    
    return $sections
}

function Get-PriorityItems {
    <#
    .SYNOPSIS
        Extract priority action items from ROADMAP.md tables.
    #>
    param([string]$Content)
    
    $items = @()
    
    # Pattern for priority table rows: | 28 | or | P28 | Task description | ✅ Done |
    # Supports both formats: bare numbers (28) and prefixed (P28)
    # Status markers: ✅ Done, 🔄 In Progress, 📋 Planned, ⏸️ Blocked, 🔥 Priority
    $priorityPattern = '(?m)^\|\s*P?(\d+)\s*\|\s*(.+?)\s*\|\s*(✅ Done|🔄 In Progress|📋 Planned|⏸️ Blocked|🔥 Priority)\s*\|'
    $matches = [regex]::Matches($Content, $priorityPattern)
    
    foreach ($match in $matches) {
        $priority = [int]$match.Groups[1].Value
        $task = $match.Groups[2].Value.Trim()
        $status = $match.Groups[3].Value.Trim()
        
        # Clean up task text (remove markdown links, code blocks)
        $task = $task -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
        $task = $task -replace '`([^`]+)`', '$1'
        
        # Determine section based on priority number
        # Updated to cover all 63 roadmap sections (P1-P300+)
        $section = switch ($priority) {
            { $_ -ge 1 -and $_ -le 27 } { 'Core Infrastructure' }
            { $_ -ge 28 -and $_ -le 37 } { 'GPU Optimization Suite' }
            { $_ -ge 38 -and $_ -le 41 } { 'AI Self-Improvement Loop' }
            { $_ -ge 42 -and $_ -le 58 } { 'Cloud Training Infrastructure' }
            { $_ -ge 59 -and $_ -le 80 } { 'AitherReasoning - Advanced' }
            { $_ -ge 81 -and $_ -le 100 } { 'Genesis Test Pipeline' }
            { $_ -ge 101 -and $_ -le 120 } { 'Documentation & Marketing' }
            { $_ -ge 121 -and $_ -le 140 } { 'Security & mTLS' }
            { $_ -ge 141 -and $_ -le 160 } { 'Licensing & Commercial' }
            { $_ -ge 161 -and $_ -le 180 } { 'Pain Aggregation' }
            { $_ -ge 181 -and $_ -le 195 } { 'Vision Tools' }
            { $_ -ge 196 -and $_ -le 210 } { 'Memory UI' }
            { $_ -ge 211 -and $_ -le 225 } { 'Hardware Optimization' }
            { $_ -ge 226 -and $_ -le 242 } { 'Roadmap Management' }
            { $_ -ge 243 -and $_ -le 260 } { 'AETHERIUM Infrastructure' }
            { $_ -ge 261 -and $_ -le 281 } { 'AitherVeil Plugin Architecture' }
            { $_ -ge 282 -and $_ -le 300 } { 'AitherSearch Web Research' }
            { $_ -ge 301 -and $_ -le 325 } { 'AitherDesktop Integration' }
            { $_ -ge 326 -and $_ -le 345 } { 'AitherDesktop Native OS' }
            { $_ -ge 346 -and $_ -le 360 } { 'AitherMesh Self-Discovery' }
            { $_ -ge 361 -and $_ -le 396 } { 'Infrastructure & Deployment' }
            { $_ -ge 400 -and $_ -le 410 } { 'Google A2A Protocol' }
            { $_ -ge 420 -and $_ -le 437 } { 'AitherSecrets Vault' }
            { $_ -ge 438 -and $_ -le 445 } { 'Service Onboarding' }
            { $_ -ge 446 -and $_ -le 454 } { 'AitherRecover Backup' }
            { $_ -ge 455 -and $_ -le 464 } { 'AitherDiscover Network Scanner' }
            { $_ -ge 465 -and $_ -le 474 } { 'AitherVeil Remote Access' }
            default { 'General' }
        }
        
        # Determine layer
        $layer = if ($task -match 'Gemini|Cloud|Vertex|GCP') { 'AitherOS' }
        elseif ($task -match 'GitHub|Runner|Actions|CI') { 'AitherCore' }
        elseif ($task -match 'GPU|VRAM|Local|Ollama|ComfyUI') { 'AitherNode' }
        else { 'AitherCore' }
        
        # Determine categories based on task content
        $categories = @()
        if ($task -match 'GPU|VRAM|quantiz|TensorRT') { $categories += 'GPU' }
        if ($task -match 'Cloud|GCP|Vertex') { $categories += 'Cloud' }
        if ($task -match 'Train|fine-tun|JSONL|LoRA|DPO') { $categories += 'Training' }
        if ($task -match 'Benchmark|metric|performance') { $categories += 'Benchmark' }
        if ($task -match 'Test|Pester|Genesis') { $categories += 'Test' }
        if ($task -match 'CI|CD|GitHub|workflow|runner') { $categories += 'CI/CD' }
        if ($task -match 'MCP|tool|server') { $categories += 'MCP' }
        if ($task -match 'Agent|ADK|Gemini') { $categories += 'Agent' }
        if ($task -match 'Vision|LLaVA|OCR|image') { $categories += 'Vision' }
        if ($task -match 'Memory|recall|context') { $categories += 'Memory' }
        if ($task -match 'Search|web|research|Perplexity|Brave|Tavily') { $categories += 'Search' }
        if ($task -match 'UI|dashboard|widget|plugin|panel') { $categories += 'UI' }
        if ($task -match 'Security|mTLS|certificate|PKI') { $categories += 'Security' }
        if ($task -match 'Pain|error|health|monitor') { $categories += 'Monitoring' }
        if ($task -match 'AETHERIUM|mesh|Tailscale|distributed') { $categories += 'Infrastructure' }
        if ($task -match 'discover|nmap|ARP|mDNS|scan|interface') { $categories += 'Discovery' }
        if ($task -match 'tunnel|cloudflare|remote access|Funnel') { $categories += 'Networking' }
        
        if ($categories.Count -eq 0) { $categories += 'General' }
        
        # Determine issue type (Bug, Feature, Chore, Docs, Test)
        $issueType = if ($task -match '\bfix\b|\bbug\b|\berror\b|\bcrash\b|\bbroken\b|\bfail') { 'Bug' }
        elseif ($task -match '\btest\b|\bpester\b|\bgenesis\b|\bvalidat') { 'Test' }
        elseif ($task -match '\bdoc\b|\breadme\b|\bguide\b|\binstruction') { 'Docs' }
        elseif ($task -match '\brefactor\b|\bcleanup\b|\bchore\b|\bmigrat\b|\bupgrad') { 'Chore' }
        else { 'Feature' }
        
        # Map roadmap status to GitHub Project status
        $projectStatus = switch ($status) {
            '📋 Planned' { 'Backlog' }
            '🔥 Priority' { 'Ready' }
            '🔄 In Progress' { 'In Progress' }
            '👀 In Review' { 'In Review' }
            '✅ Done' { 'Done' }
            '⏸️ Blocked' { 'Backlog' }
            default { 'Backlog' }
        }
        
        $items += @{
            Priority      = $priority
            Title         = $task
            Status        = $status
            ProjectStatus = $projectStatus
            Section       = $section
            Layer         = $layer
            Categories    = $categories
            IssueType     = $issueType
            IsComplete    = $status -eq '✅ Done'
            IsBlocked     = $status -eq '⏸️ Blocked'
        }
    }
    
    return $items | Sort-Object Priority
}

function Get-ChecklistItems {
    <#
    .SYNOPSIS
        Extract checklist items from ROADMAP.md (- [x] and - [ ] patterns).
    #>
    param([string]$Content)
    
    $items = @()
    
    # Pattern for checklist items
    $checklistPattern = '(?m)^-\s+\[([ xX])\]\s+(.+?)$'
    $matches = [regex]::Matches($Content, $checklistPattern)
    
    $counter = 100  # Start numbering from 100 for checklist items
    
    foreach ($match in $matches) {
        $isComplete = $match.Groups[1].Value -match '[xX]'
        $task = $match.Groups[2].Value.Trim()
        
        # Skip if it's a sub-item (starts with whitespace in original)
        if ($match.Value -match '^\s{2,}') { continue }
        
        # Clean up task text
        $task = $task -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
        $task = $task -replace '`([^`]+)`', '$1'
        $task = $task -replace '\*\*([^*]+)\*\*', '$1'
        
        # Determine categories
        $categories = @()
        if ($task -match 'GPU|VRAM|quantiz') { $categories += 'GPU' }
        if ($task -match 'Cloud|GCP') { $categories += 'Cloud' }
        if ($task -match 'Test|Pester') { $categories += 'Test' }
        if ($categories.Count -eq 0) { $categories += 'General' }
        
        $items += @{
            Priority   = $counter++
            Title      = $task
            Status     = if ($isComplete) { '✅ Done' } else { '📋 Planned' }
            Section    = 'Checklist'
            Layer      = 'AitherCore'
            Categories = $categories
            IsComplete = $isComplete
        }
    }
    
    return $items
}

function New-GitHubLabels {
    <#
    .SYNOPSIS
        Create required labels in the repository.
    #>
    
    Write-Output "Creating GitHub labels..." -Level Information
    
    $labels = @(
        # Layer labels
        @{ Name = 'layer:aitheros'; Color = '7057ff'; Description = 'AitherOS intelligence layer (Gemini 3)' }
        @{ Name = 'layer:aithercore'; Color = '0e8a16'; Description = 'AitherCore/AitherZero execution layer' }
        @{ Name = 'layer:aithernode'; Color = '1d76db'; Description = 'AitherNode local inference (RTX 5080)' }
        
        # Category labels
        @{ Name = 'gpu-optimization'; Color = 'd93f0b'; Description = 'GPU performance and optimization' }
        @{ Name = 'cloud-training'; Color = '0052cc'; Description = 'GCP and cloud AI training' }
        @{ Name = 'self-improvement'; Color = '5319e7'; Description = 'AI self-improvement loop' }
        @{ Name = 'benchmark'; Color = 'fbca04'; Description = 'Performance benchmarking' }
        @{ Name = 'testing'; Color = 'c5def5'; Description = 'Testing and validation' }
        @{ Name = 'infrastructure'; Color = 'bfd4f2'; Description = 'CI/CD and infrastructure' }
        @{ Name = 'mcp-server'; Color = 'f9d0c4'; Description = 'MCP server tools' }
        @{ Name = 'ai-agents'; Color = 'd4c5f9'; Description = 'AI agents and ADK' }
        @{ Name = 'vision'; Color = 'a2eeef'; Description = 'Vision and image analysis' }
        @{ Name = 'memory'; Color = 'bfdadc'; Description = 'Memory and context management' }
        @{ Name = 'search'; Color = 'd4c5f9'; Description = 'Web search and research' }
        @{ Name = 'ui'; Color = 'c5def5'; Description = 'User interface and dashboard' }
        @{ Name = 'security'; Color = 'b60205'; Description = 'Security and authentication' }
        @{ Name = 'monitoring'; Color = 'fef2c0'; Description = 'Monitoring and observability' }
        @{ Name = 'discovery'; Color = '0e8a16'; Description = 'Network and service discovery' }
        @{ Name = 'networking'; Color = '1d76db'; Description = 'Networking and remote access' }
        @{ Name = 'core'; Color = 'd93f0b'; Description = 'Core functionality' }
        
        # Status labels (match GitHub Project columns)
        @{ Name = 'status:backlog'; Color = 'e4e669'; Description = 'In backlog, not yet ready' }
        @{ Name = 'status:ready'; Color = '0e8a16'; Description = 'Ready to work on' }
        @{ Name = 'status:in-progress'; Color = 'fbca04'; Description = 'Currently in progress' }
        @{ Name = 'status:in-review'; Color = '1d76db'; Description = 'In review/testing' }
        @{ Name = 'status:done'; Color = '0e8a16'; Description = 'Completed work' }
        @{ Name = 'status:blocked'; Color = 'b60205'; Description = 'Blocked by dependency' }
        @{ Name = 'status:planned'; Color = 'c2e0c6'; Description = 'Planned for future' }
        
        # Type labels (Bug vs Feature)
        @{ Name = 'type:bug'; Color = 'd73a4a'; Description = 'Something is broken' }
        @{ Name = 'type:feature'; Color = 'a2eeef'; Description = 'New feature or enhancement' }
        @{ Name = 'type:chore'; Color = 'fef2c0'; Description = 'Maintenance or cleanup task' }
        @{ Name = 'type:docs'; Color = '0075ca'; Description = 'Documentation improvements' }
        @{ Name = 'type:test'; Color = 'c5def5'; Description = 'Testing related' }
        
        # Priority labels
        @{ Name = 'priority:p0'; Color = 'b60205'; Description = 'Critical - needs immediate attention' }
        @{ Name = 'priority:p1'; Color = 'd93f0b'; Description = 'High priority' }
        @{ Name = 'priority:p2'; Color = 'fbca04'; Description = 'Normal priority' }
        
        # Meta
        @{ Name = 'roadmap'; Color = 'ededed'; Description = 'Imported from ROADMAP.md' }
        @{ Name = 'section-parent'; Color = '5319e7'; Description = 'Parent issue for roadmap section' }
    )
    
    foreach ($label in $labels) {
        if (-not $DryRun) {
            try {
                gh label create $label.Name --color $label.Color --description $label.Description --force 2>$null
                Write-Output "  Created label: $($label.Name)" -Level Success
            }
            catch {
                Write-Output "  Label exists: $($label.Name)" -Level Information
            }
        }
        else {
            Write-Output "  [DRY RUN] Would create label: $($label.Name)" -Level Information
        }
    }
}

function Add-SubIssue {
    <#
    .SYNOPSIS
        Link an existing issue as a sub-issue of a parent issue using GraphQL API.
    #>
    param(
        [string]$ParentIssueId,
        [string]$ChildIssueId
    )
    
    if ($DryRun) {
        Write-Output "  [DRY RUN] Would link sub-issue" -Level Information
        return $true
    }
    
    $mutation = @"
mutation {
  addSubIssue(input: {
    issueId: "$ParentIssueId"
    subIssueId: "$ChildIssueId"
    replaceParent: true
  }) {
    issue {
      id
      title
    }
    subIssue {
      id
      title
    }
  }
}
"@
    
    try {
        $result = gh api graphql -f query="$mutation" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Output "  Linked as sub-issue" -Level Success
            return $true
        }
        else {
            Write-Output "  Failed to link sub-issue: $result" -Level Warning
            return $false
        }
    }
    catch {
        Write-Output "  Error linking sub-issue: $_" -Level Error
        return $false
    }
}

function Set-ProjectItemDates {
    <#
    .SYNOPSIS
        Set start_date and target_date on a project item using GraphQL.
    #>
    param(
        [string]$ItemId,
        [datetime]$StartDate,
        [datetime]$TargetDate
    )
    
    if ($DryRun) {
        Write-Output "  [DRY RUN] Would set dates: $($StartDate.ToString('yyyy-MM-dd')) -> $($TargetDate.ToString('yyyy-MM-dd'))" -Level Information
        return $true
    }
    
    $projectId = $script:Config.Project.Id
    $startDateFieldId = $script:Config.Project.Fields.StartDate
    $targetDateFieldId = $script:Config.Project.Fields.TargetDate
    
    # Set start date
    $startMutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$projectId"
    itemId: "$ItemId"
    fieldId: "$startDateFieldId"
    value: { date: "$($StartDate.ToString('yyyy-MM-dd'))" }
  }) {
    projectV2Item { id }
  }
}
"@
    
    # Set target date
    $targetMutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$projectId"
    itemId: "$ItemId"
    fieldId: "$targetDateFieldId"
    value: { date: "$($TargetDate.ToString('yyyy-MM-dd'))" }
  }) {
    projectV2Item { id }
  }
}
"@
    
    try {
        $null = gh api graphql -f query="$startMutation" 2>&1
        $null = gh api graphql -f query="$targetMutation" 2>&1
        Write-Output "  Set dates: $($StartDate.ToString('yyyy-MM-dd')) -> $($TargetDate.ToString('yyyy-MM-dd'))" -Level Success
        return $true
    }
    catch {
        Write-Output "  Error setting dates: $_" -Level Error
        return $false
    }
}

function Get-IssueNodeId {
    <#
    .SYNOPSIS
        Get the GraphQL node ID for an issue by number.
    #>
    param([int]$IssueNumber)
    
    $query = @"
query {
  repository(owner: "$($script:Config.Owner)", name: "$($script:Config.Repo)") {
    issue(number: $IssueNumber) {
      id
    }
  }
}
"@
    
    try {
        $result = gh api graphql -f query="$query" 2>&1 | ConvertFrom-Json
        return $result.data.repository.issue.id
    }
    catch {
        return $null
    }
}

function New-SectionParentIssue {
    <#
    .SYNOPSIS
        Create a parent issue for a roadmap section.
    #>
    param(
        [int]$SectionNumber,
        [string]$SectionTitle,
        [int]$ChildCount
    )
    
    $title = "[Section $SectionNumber] $SectionTitle"
    
    if ($DryRun) {
        Write-Output "[DRY RUN] Would create section parent: $title ($ChildCount sub-issues)" -Level Information
        return @{ Number = 0; Id = "DRY_RUN"; Title = $title }
    }
    
    # Check if already exists
    $existing = gh issue list --state all --search "in:title `"[Section $SectionNumber]`"" --json number,title 2>$null | ConvertFrom-Json
    
    if ($existing.Count -gt 0) {
        $issueNum = $existing[0].number
        $nodeId = Get-IssueNodeId -IssueNumber $issueNum
        Write-Output "  Section parent exists: #$issueNum" -Level Information
        return @{ Number = $issueNum; Id = $nodeId; Title = $existing[0].title }
    }
    
    $body = @"
## Roadmap Section $SectionNumber

### $SectionTitle

This is a parent issue for organizing related roadmap items.

**Sub-issues:** $ChildCount priority items

---

*Auto-generated from ROADMAP.md*
"@
    
    $result = gh issue create --title $title --body $body --label "roadmap" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $issueNum = if ($result -match '/issues/(\d+)') { [int]$Matches[1] } else { 0 }
        $nodeId = Get-IssueNodeId -IssueNumber $issueNum
        Write-Output "  Created section parent: #$issueNum - $title" -Level Success
        return @{ Number = $issueNum; Id = $nodeId; Title = $title }
    }
    
    return $null
}

function New-GitHubIssue {
    <#
    .SYNOPSIS
        Create or update a GitHub issue from a roadmap item.
        Idempotent: skips if unchanged, updates if status changed.
    #>
    param(
        [hashtable]$Item,
        [switch]$UpdateExisting
    )
    
    $title = "[P$($Item.Priority)] $($Item.Title)"
    
    # Build labels
    $labels = @('roadmap')
    $labels += $script:Config.Labels.Layers[$Item.Layer]
    $labels += $script:Config.Labels.Status[$Item.Status]
    
    # Add type label (bug, feature, etc.)
    $typeLabel = $script:Config.Labels.IssueTypes[$Item.IssueType]
    if ($typeLabel) { $labels += $typeLabel }
    
    # Add blocked label if applicable
    if ($Item.IsBlocked) { $labels += 'status:blocked' }
    
    foreach ($cat in $Item.Categories) {
        $catLabel = $script:Config.Labels.Categories[$cat]
        if ($catLabel) { $labels += $catLabel }
    }
    
    $labelsStr = ($labels | Where-Object { $_ }) -join ','
    
    # Build body
    $body = @"
## Roadmap Item

**Priority:** P$($Item.Priority)
**Section:** $($Item.Section)
**Layer:** $($Item.Layer)
**Type:** $($Item.IssueType)
**Status:** $($Item.Status)
**Project Status:** $($Item.ProjectStatus)

---

### Description

$($Item.Title)

---

*Imported from ROADMAP.md on $(Get-Date -Format 'yyyy-MM-dd HH:mm')*
"@
    
    if ($DryRun) {
        Write-Output "[DRY RUN] Would create issue: $title" -Level Information
        Write-Output "  Labels: $labelsStr" -Level Information
        Write-Output "  Status: $($Item.Status)" -Level Information
        return @{
            Number = 0
            Title  = $title
            Status = $Item.Status
            DryRun = $true
        }
    }
    
    # Check if issue already exists
    $existing = gh issue list --state all --search "in:title `"[P$($Item.Priority)]`"" --json number,title,state,labels 2>$null | ConvertFrom-Json
    
    if ($existing.Count -gt 0) {
        $issueNum = $existing[0].number
        $issueState = $existing[0].state
        $shouldBeClosed = $Item.IsComplete
        $isClosed = $issueState -eq 'CLOSED'
        
        # Check if state needs updating
        if ($shouldBeClosed -and -not $isClosed) {
            # Roadmap says done, but issue is open - close it
            gh issue close $issueNum --reason completed 2>$null
            Write-Output "  Updated #${issueNum}: OPEN -> CLOSED (marked done in roadmap)" -Level Success
            return @{
                Number  = $issueNum
                Title   = $existing[0].title
                Status  = 'Updated'
                Updated = $true
                Action  = 'Closed'
            }
        }
        elseif (-not $shouldBeClosed -and $isClosed) {
            # Roadmap says not done, but issue is closed - reopen it
            gh issue reopen $issueNum 2>$null
            Write-Output "  Updated #${issueNum}: CLOSED -> OPEN (reopened in roadmap)" -Level Success
            return @{
                Number  = $issueNum
                Title   = $existing[0].title
                Status  = 'Updated'
                Updated = $true
                Action  = 'Reopened'
            }
        }
        else {
            Write-Output "  Issue exists: #$issueNum - $($existing[0].title) (no change)" -Level Information
            return @{
                Number   = $issueNum
                Title    = $existing[0].title
                Status   = 'Existing'
                Existing = $true
            }
        }
    }
    
    # Create the issue
    $result = gh issue create --title $title --body $body --label $labelsStr 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $issueUrl = $result | Select-String -Pattern 'https://github.com/.+/issues/(\d+)' | ForEach-Object { $_.Matches[0].Value }
        $issueNum = if ($issueUrl -match '/issues/(\d+)') { $Matches[1] } else { '?' }
        
        Write-Output "  Created issue #$issueNum : $title" -Level Success
        
        # Close if completed
        if ($Item.IsComplete) {
            gh issue close $issueNum --reason completed 2>$null
            Write-Output "  Closed issue #$issueNum (completed work)" -Level Success
        }
        
        return @{
            Number = $issueNum
            Title  = $title
            Status = if ($Item.IsComplete) { 'Closed' } else { 'Open' }
            Url    = $issueUrl
        }
    }
    else {
        $errorMsg = $result -join ' '
        
        # Check for specific errors
        if ($errorMsg -match 'has disabled issues') {
            Write-Output "  ERROR: Repository has issues disabled. Enable at: https://github.com/$($script:Config.Owner)/$($script:Config.Repo)/settings" -Level Error
            return @{
                Title  = $title
                Status = 'RepoDisabled'
                Error  = 'Issues are disabled for this repository'
            }
        }
        elseif ($errorMsg -match 'rate limit') {
            Write-Output "  ERROR: GitHub API rate limit hit. Waiting 60s..." -Level Warning
            Start-Sleep -Seconds 60
            # Retry once
            $result = gh issue create --title $title --body $body --label $labelsStr 2>&1
            if ($LASTEXITCODE -eq 0) {
                $issueUrl = $result | Select-String -Pattern 'https://github.com/.+/issues/(\d+)' | ForEach-Object { $_.Matches[0].Value }
                $issueNum = if ($issueUrl -match '/issues/(\d+)') { $Matches[1] } else { '?' }
                Write-Output "  Created issue #${issueNum} (after retry)" -Level Success
                return @{ Number = $issueNum; Title = $title; Status = 'Open'; Url = $issueUrl }
            }
        }
        
        Write-Output "  Failed to create issue: $errorMsg" -Level Error
        return $null
    }
}

#endregion

#region Main Execution

Write-Output "========================================" -Level Information
Write-Output "AitherZero Roadmap → GitHub Import" -Level Information
Write-Output "========================================" -Level Information
Write-Output "" -Level Information

# Check prerequisites
if (-not $DryRun -and -not (Test-GitHubCLI)) {
    Write-AitherError "GitHub CLI not authenticated. Run 'gh auth login' first."
    exit 1
}

# Check if issues are enabled
if (-not $DryRun) {
    Write-Output "Checking repository settings..." -Level Information
    if (-not (Test-IssuesEnabled)) {
        Write-Output "" -Level Information
        Write-Output "ERROR: Issues are DISABLED for this repository!" -Level Error
        Write-Output "" -Level Information
        Write-Output "To enable issues:" -Level Information
        Write-Output "  1. Go to: https://github.com/$($script:Config.Owner)/$($script:Config.Repo)/settings" -Level Information
        Write-Output "  2. Scroll to 'Features' section" -Level Information
        Write-Output "  3. Check the 'Issues' checkbox" -Level Information
        Write-Output "  4. Re-run this script" -Level Information
        Write-Output "" -Level Information
        
        # Offer to open the settings page
        $settingsUrl = "https://github.com/$($script:Config.Owner)/$($script:Config.Repo)/settings"
        Write-Output "Opening settings page..." -Level Information
        Start-Process $settingsUrl
        
        exit 1
    }
    Write-Output "Repository issues are enabled" -Level Success
}

# Read roadmap
if (-not (Test-Path $script:Config.RoadmapPath)) {
    Write-AitherError "ROADMAP.md not found at: $($script:Config.RoadmapPath)"
    exit 1
}

$roadmapContent = Get-Content $script:Config.RoadmapPath -Raw
Write-Output "Loaded ROADMAP.md ($([math]::Round($roadmapContent.Length / 1024, 1)) KB)" -Level Information

# Parse items
$priorityItems = Get-PriorityItems -Content $roadmapContent
$checklistItems = Get-ChecklistItems -Content $roadmapContent

Write-Output "Found $($priorityItems.Count) priority items" -Level Information
Write-Output "Found $($checklistItems.Count) checklist items" -Level Information
Write-Output "" -Level Information

# Filter based on IncludeCompleted
$allItems = $priorityItems
if (-not $IncludeCompleted) {
    $allItems = $allItems | Where-Object { -not $_.IsComplete }
    Write-Output "Filtered to $($allItems.Count) incomplete items (use -IncludeCompleted for all)" -Level Warning
}

# Create labels (only once - check if roadmap label exists as indicator)
if (-not $DryRun) {
    $existingLabels = gh label list --json name 2>$null | ConvertFrom-Json
    $hasRoadmapLabel = $existingLabels | Where-Object { $_.name -eq 'roadmap' }
    
    if (-not $hasRoadmapLabel) {
        Write-Output "Creating GitHub labels (first-time setup)..." -Level Information
        New-GitHubLabels
        Write-Output "" -Level Information
    }
    else {
        Write-Output "Labels already exist, skipping creation" -Level Information
    }
}

# Sub-issue mode: Create parent issues for sections first
$sectionParents = @{}
if ($WithSubIssues) {
    Write-Output "Creating section parent issues for sub-issue hierarchy..." -Level Information
    Write-Output "" -Level Information
    
    # Group items by section
    $itemsBySection = $allItems | Group-Object -Property Section
    
    foreach ($sectionGroup in $itemsBySection) {
        $sectionName = $sectionGroup.Name
        # Extract section number from name (e.g., "GPU Optimization Suite" -> find in roadmap)
        $sectionNum = switch ($sectionName) {
            'GPU Optimization Suite' { 38 }
            'AI Self-Improvement Loop' { 39 }
            'Cloud Training Infrastructure' { 40 }
            'AitherReasoning - Advanced' { 41 }
            'Genesis Test Pipeline' { 42 }
            'Documentation & Marketing' { 43 }
            'Security & mTLS' { 44 }
            'Licensing & Commercial' { 45 }
            'Pain Aggregation' { 50 }
            'Vision Tools' { 52 }
            'Memory UI' { 53 }
            'Hardware Optimization' { 56 }
            'Roadmap Management' { 59 }
            'AETHERIUM Infrastructure' { 61 }
            'AitherVeil Plugin Architecture' { 62 }
            'AitherSearch Web Research' { 63 }
            'AitherScope Visualizer' { 64 }
            'AitherDesktop Integration' { 65 }
            'AitherDesktop Native OS' { 65 }
            'AitherMesh Self-Discovery' { 67 }
            'Infrastructure & Deployment' { 71 }
            'Google A2A Protocol' { 72 }
            'AitherSecrets Vault' { 73 }
            'Service Onboarding' { 74 }
            'AitherRecover Backup' { 74 }
            'AitherDiscover Network Scanner' { 75 }
            'AitherVeil Remote Access' { 76 }
            default { 0 }
        }
        
        if ($sectionNum -gt 0) {
            $parent = New-SectionParentIssue -SectionNumber $sectionNum -SectionTitle $sectionName -ChildCount $sectionGroup.Count
            if ($parent) {
                $sectionParents[$sectionName] = $parent
            }
        }
    }
    
    Write-Output "" -Level Information
    Write-Output "Created $($sectionParents.Count) section parents" -Level Success
    Write-Output "" -Level Information
}

# Create issues
Write-Output "Creating GitHub Issues..." -Level Information
Write-Output "" -Level Information

$results = @{
    Created  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    Existing = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    Failed   = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    Closed   = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    Updated  = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
}

#region DIFFERENTIAL SYNC - Fetch ALL existing issues ONCE
Write-Output "Fetching existing roadmap issues (single API call)..." -Level Information

$existingIssuesMap = @{}
if (-not $DryRun) {
    # Fetch ALL issues with roadmap label in ONE call (up to 1000)
    $existingIssues = gh issue list --state all --label "roadmap" --limit 1000 --json number,title,state 2>$null | ConvertFrom-Json
    
    # Build hash map by priority number for O(1) lookup
    foreach ($issue in $existingIssues) {
        if ($issue.title -match '^\[P(\d+)\]') {
            $priorityNum = $Matches[1]
            $existingIssuesMap[$priorityNum] = @{
                Number = $issue.number
                Title  = $issue.title
                State  = $issue.state
            }
        }
    }
    Write-Output "Found $($existingIssuesMap.Count) existing roadmap issues" -Level Success
}
#endregion

# Determine what needs to be synced
$itemsToCreate = @()
$itemsToUpdate = @()
$itemsUnchanged = @()

foreach ($item in $allItems) {
    $priorityKey = "$($item.Priority)"
    $existing = $existingIssuesMap[$priorityKey]
    
    if ($existing) {
        $shouldBeClosed = $item.IsComplete
        $isClosed = $existing.State -eq 'CLOSED'
        
        if (($shouldBeClosed -and -not $isClosed) -or (-not $shouldBeClosed -and $isClosed)) {
            $itemsToUpdate += @{ Item = $item; Existing = $existing }
        }
        else {
            $itemsUnchanged += @{ Item = $item; Existing = $existing }
            $results.Existing.Add(@{ Number = $existing.Number; Title = $existing.Title })
        }
    }
    else {
        $itemsToCreate += $item
    }
}

Write-Output "" -Level Information
Write-Output "Differential sync summary:" -Level Information
Write-Output "  • New items to create: $($itemsToCreate.Count)" -Level Information
Write-Output "  • Items to update: $($itemsToUpdate.Count)" -Level Information  
Write-Output "  • Unchanged (skip): $($itemsUnchanged.Count)" -Level Information
Write-Output "" -Level Information

# Only process items that need changes
$throttleLimit = if ($DryRun) { 20 } else { 10 }

# Process CREATES (parallel)
if ($itemsToCreate.Count -gt 0) {
    Write-Output "Creating $($itemsToCreate.Count) new issues..." -Level Information
    
    $itemsToCreate | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
        $item = $_
        $DryRun = $using:DryRun
        $results = $using:results
        $config = $using:script:Config
        
        $title = "[P$($item.Priority)] $($item.Title)"
        
        # Build labels
        $labels = @('roadmap')
        $labels += $config.Labels.Layers[$item.Layer]
        $labels += $config.Labels.Status[$item.Status]
        
        foreach ($cat in $item.Categories) {
            $catLabel = $config.Labels.Categories[$cat]
            if ($catLabel) { $labels += $catLabel }
        }
        
        $labelsStr = ($labels | Where-Object { $_ }) -join ','
        
        $body = @"
## Roadmap Item

**Priority:** P$($item.Priority)
**Section:** $($item.Section)
**Layer:** $($item.Layer)
**Status:** $($item.Status)

---

### Description

$($item.Title)

---

*Imported from ROADMAP.md on $(Get-Date -Format 'yyyy-MM-dd HH:mm')*
"@
        
        if ($DryRun) {
            Write-Host "[DRY RUN] Would create: $title"
            $results.Created.Add(@{ Number = 0; Title = $title; DryRun = $true })
            return
        }
        
        $result = gh issue create --title $title --body $body --label $labelsStr 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $issueNum = if ($result -match '/issues/(\d+)') { $Matches[1] } else { '?' }
            Write-Host "  Created #$issueNum : $title"
            
            if ($item.IsComplete) {
                gh issue close $issueNum --reason completed 2>$null
                $results.Closed.Add(@{ Number = $issueNum; Title = $title })
            }
            else {
                $results.Created.Add(@{ Number = $issueNum; Title = $title })
            }
        }
        else {
            Write-Host "  FAILED: $title - $result" -ForegroundColor Red
            $results.Failed.Add(@{ Title = $title; Error = $result })
        }
    }
}

# Process UPDATES (parallel)
if ($itemsToUpdate.Count -gt 0) {
    Write-Output "Updating $($itemsToUpdate.Count) issues..." -Level Information
    
    $itemsToUpdate | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
        $update = $_
        $item = $update.Item
        $existing = $update.Existing
        $DryRun = $using:DryRun
        $results = $using:results
        
        $title = "[P$($item.Priority)] $($item.Title)"
        $issueNum = $existing.Number
        $shouldBeClosed = $item.IsComplete
        $isClosed = $existing.State -eq 'CLOSED'
        
        if ($DryRun) {
            $action = if ($shouldBeClosed) { "CLOSE" } else { "REOPEN" }
            Write-Host "[DRY RUN] Would $action #$issueNum : $title"
            return
        }
        
        if ($shouldBeClosed -and -not $isClosed) {
            gh issue close $issueNum --reason completed 2>$null
            Write-Host "  Updated #${issueNum}: CLOSED (done in roadmap)"
            $results.Updated.Add(@{ Number = $issueNum; Title = $title; Action = 'Closed' })
        }
        elseif (-not $shouldBeClosed -and $isClosed) {
            gh issue reopen $issueNum 2>$null
            Write-Host "  Updated #${issueNum}: REOPENED"
            $results.Updated.Add(@{ Number = $issueNum; Title = $title; Action = 'Reopened' })
        }
    }
}

# Phase 2: Link sub-issues (sequential - needs all issues to exist first)
if ($WithSubIssues -and $sectionParents.Count -gt 0 -and -not $DryRun) {
    Write-Output "" -Level Information
    Write-Output "Linking sub-issues to parent sections..." -Level Information
    
    $linkedCount = 0
    foreach ($item in $allItems) {
        $sectionName = $item.Section
        $parent = $sectionParents[$sectionName]
        
        if ($parent -and $parent.Id) {
            # Find the child issue
            $existing = gh issue list --state all --search "in:title `"[P$($item.Priority)]`"" --json number 2>$null | ConvertFrom-Json
            
            if ($existing.Count -gt 0) {
                $childNum = $existing[0].number
                $childId = Get-IssueNodeId -IssueNumber $childNum
                
                if ($childId) {
                    $linked = Add-SubIssue -ParentIssueId $parent.Id -ChildIssueId $childId
                    if ($linked) { $linkedCount++ }
                }
            }
        }
    }
    
    Write-Output "Linked $linkedCount sub-issues" -Level Success
}

# Phase 3: Set dates on project items (if requested)
if ($SetDates -and -not $DryRun) {
    Write-Output "" -Level Information
    Write-Output "Setting start/target dates on project items..." -Level Information
    
    # Calculate dates based on priority (higher priority = sooner)
    $baseStartDate = Get-Date
    $datesSet = 0
    
    foreach ($item in $allItems) {
        # Skip completed items
        if ($item.IsComplete) { continue }
        
        # Find the issue
        $existing = gh issue list --state all --search "in:title `"[P$($item.Priority)]`"" --json number 2>$null | ConvertFrom-Json
        
        if ($existing.Count -gt 0) {
            $issueNum = $existing[0].number
            
            # Get project item ID for this issue
            $query = @"
query {
  repository(owner: "$($script:Config.Owner)", name: "$($script:Config.Repo)") {
    issue(number: $issueNum) {
      projectItems(first: 10) {
        nodes {
          id
          project { number }
        }
      }
    }
  }
}
"@
            $result = gh api graphql -f query="$query" 2>$null | ConvertFrom-Json
            $projectItem = $result.data.repository.issue.projectItems.nodes | Where-Object { $_.project.number -eq $ProjectNumber } | Select-Object -First 1
            
            if ($projectItem) {
                # Calculate dates based on priority (lower priority number = sooner)
                $weekOffset = [math]::Floor($item.Priority / 10)
                $startDate = $baseStartDate.AddDays($weekOffset * 7)
                $targetDate = $startDate.AddDays(14)  # 2-week sprint default
                
                Set-ProjectItemDates -ItemId $projectItem.id -StartDate $startDate -TargetDate $targetDate
                $datesSet++
            }
        }
    }
    
    Write-Output "Set dates on $datesSet project items" -Level Success
}

# Phase 4: Set project column status (only for NEW and UPDATED items - not all items)
if (-not $DryRun) {
    Write-Output "" -Level Information
    Write-Output "Setting project column status for changed items..." -Level Information
    
    $statusSet = 0
    
    # Only process items that were created or updated (not the 585+ unchanged ones)
    $changedItems = @()
    $changedItems += $itemsToCreate
    $changedItems += ($itemsToUpdate | ForEach-Object { $_.Item })
    
    if ($changedItems.Count -eq 0) {
        Write-Output "No changed items to update project status for" -Level Information
    }
    else {
        Write-Output "Updating project status for $($changedItems.Count) changed items..." -Level Information
        
        foreach ($item in $changedItems) {
            $priorityKey = "$($item.Priority)"
            $issueNum = $existingIssuesMap[$priorityKey].Number
            
            # If it was just created, it might not be in the map yet - search for it
            if (-not $issueNum) {
                $found = gh issue list --state all --search "in:title `"[P$($item.Priority)]`"" --json number --limit 1 2>$null | ConvertFrom-Json
                if ($found.Count -gt 0) { $issueNum = $found[0].number }
            }
            
            if ($issueNum) {
                # Get project item ID
                $query = @"
query {
  repository(owner: "$($script:Config.Owner)", name: "$($script:Config.Repo)") {
    issue(number: $issueNum) {
      projectItems(first: 10) {
        nodes {
          id
          project { number }
        }
      }
    }
  }
}
"@
                $result = gh api graphql -f query="$query" 2>$null | ConvertFrom-Json
                $projectItem = $result.data.repository.issue.projectItems.nodes | Where-Object { $_.project.number -eq $ProjectNumber } | Select-Object -First 1
                
                if ($projectItem) {
                    $statusOptionId = $script:Config.Project.StatusOptions[$item.ProjectStatus]
                    
                    if ($statusOptionId) {
                        $mutation = @"
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$($script:Config.Project.Id)"
    itemId: "$($projectItem.id)"
    fieldId: "$($script:Config.Project.Fields.Status)"
    value: { singleSelectOptionId: "$statusOptionId" }
  }) {
    projectV2Item { id }
  }
}
"@
                        $null = gh api graphql -f query="$mutation" 2>$null
                        $statusSet++
                        Write-Host "  Set status for #$issueNum"
                    }
                }
            }
        }
        
        Write-Output "Set status on $statusSet project items" -Level Success
    }
}

# Summary
Write-Output "" -Level Information
Write-Output "========================================" -Level Information
Write-Output "Import Summary" -Level Information
Write-Output "========================================" -Level Information
Write-Output "Created:  $($results.Created.Count) issues" -Level Success
Write-Output "Closed:   $($results.Closed.Count) issues (completed work)" -Level Success
Write-Output "Updated:  $($results.Updated.Count) issues (status synced)" -Level Success
Write-Output "Existing: $($results.Existing.Count) issues (unchanged)" -Level Information
Write-Output "Failed:   $($results.Failed.Count) issues" -Level Error
if ($WithSubIssues) {
    Write-Output "Sections: $($sectionParents.Count) parent issues created" -Level Information
}
Write-Output "" -Level Information

# Save results (convert ConcurrentBag to arrays for JSON)
$outputData = @{
    Timestamp       = Get-Date -Format 'o'
    DryRun          = $DryRun
    IncludeComplete = $IncludeCompleted
    Results         = @{
        Created  = @($results.Created.ToArray())
        Existing = @($results.Existing.ToArray())
        Updated  = @($results.Updated.ToArray())
        Closed   = @($results.Closed.ToArray())
        Failed   = @($results.Failed.ToArray())
    }
    ItemCount       = @{
        Priority  = $priorityItems.Count
        Checklist = $checklistItems.Count
        Total     = $allItems.Count
    }
}

$outputData | ConvertTo-Json -Depth 10 | Set-Content $script:Config.OutputPath
Write-Output "Results saved to: $($script:Config.OutputPath)" -Level Information

if ($DryRun) {
    Write-Output "" -Level Information
    Write-Output "This was a DRY RUN. No issues were created." -Level Warning
    Write-Output "Run without -DryRun to create issues." -Level Information
}

exit 0

#endregion
