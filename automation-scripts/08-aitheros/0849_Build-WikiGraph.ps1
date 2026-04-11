#Requires -Version 7.0

<#
.SYNOPSIS
    Automates a Wikidata + Wikipedia ingest pipeline for GraphRAG experiments.

.DESCRIPTION
    Wraps the Python-based WikiGraph pipeline in AitherOS/scripts/wikigraph_pipeline.py.
    This script can download Wikimedia dumps, ingest a Wikidata graph into
    AitherKnowledgeGraph, ingest Wikipedia article text into Nexus, build
    GraphRAG-style community summaries, and emit an MCTS handoff plan for
    future query-time graph search.

    Safe by default: it does NOT download multi-hundred-GB dumps unless -Download
    is specified. It also defaults to proof-of-concept limits for entity/article
    counts unless -FullScale is provided.

    Exit Codes:
    0 - Success
    1 - Failure
    2 - Execution error

.PARAMETER Mode
    Which phase to run: Download, IngestWikidata, IngestWikipediaText, BuildCommunities, PlanMcts, Full.

.PARAMETER Download
    Download Wikimedia dump files before ingestion.

.PARAMETER FullScale
    Remove proof-of-concept limits and attempt full ingestion.

.PARAMETER DataDir
    Base directory for Wikimedia dumps and generated artifacts.

.PARAMETER KnowledgeGraphUrl
    URL for AitherKnowledgeGraph.

.PARAMETER NexusUrl
    URL for AitherNexus.

.PARAMETER EntityLimit
    Proof-of-concept limit for Wikidata entities.

.PARAMETER ArticleLimit
    Proof-of-concept limit for Wikipedia articles.

.PARAMETER BatchSize
    Batch size for KnowledgeGraph uploads.

.PARAMETER DryRun
    Show commands without executing them.

.NOTES
    Stage: Development
    Order: 0849
    Dependencies: 0001, 8196, 8122
    Tags: wikidata, wikipedia, graphrag, knowledge-graph, nexus, mcts
    AllowParallel: false
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Download', 'IngestWikidata', 'IngestWikipediaText', 'BuildCommunities', 'PlanMcts', 'Full')]
    [string]$Mode = 'Full',

    [switch]$Download,
    [switch]$FullScale,
    [string]$DataDir = 'AitherOS/data/wikigraph',
    [string]$KnowledgeGraphUrl = 'http://localhost:8196',
    [string]$NexusUrl = 'http://localhost:8122',
    [int]$EntityLimit = 10000,
    [int]$ArticleLimit = 1000,
    [int]$BatchSize = 250,
    [switch]$DryRun,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$writeScriptLog = Join-Path $PSScriptRoot '..\..\..\src\public\Logging\Write-ScriptLog.ps1'
if (Test-Path $writeScriptLog) { . $writeScriptLog }

function Resolve-PythonCommand {
    foreach ($candidate in @('python', 'py')) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }
    throw 'Python 3.10+ is required but was not found in PATH.'
}

function Invoke-WikiGraphCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $commandText = "$PythonCmd $($Arguments -join ' ')"
    Write-ScriptLog "WikiGraph command: $commandText"

    if ($DryRun) {
        Write-ScriptLog 'Dry run enabled — command not executed.' -Level Information
        return $null
    }

    & $PythonCmd @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "WikiGraph command failed with exit code $LASTEXITCODE"
    }
}

try {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    $PythonCmd = Resolve-PythonCommand
    $PipelineScript = Join-Path $RepoRoot 'AitherOS/scripts/wikigraph_pipeline.py'

    if (-not (Test-Path $PipelineScript)) {
        throw "Pipeline script not found: $PipelineScript"
    }

    $ResolvedDataDir = Join-Path $RepoRoot $DataDir
    $WikidataDir = Join-Path $ResolvedDataDir 'wikidata'
    $WikipediaDir = Join-Path $ResolvedDataDir 'wikipedia'
    $ArtifactsDir = Join-Path $ResolvedDataDir 'artifacts'
    $TitleMapPath = Join-Path $ArtifactsDir 'wikidata_enwiki_titles.jsonl'
    $NodeCatalogPath = Join-Path $ArtifactsDir 'wikidata_nodes.jsonl'
    $EdgeCatalogPath = Join-Path $ArtifactsDir 'wikidata_edges.jsonl'
    $CommunityJsonPath = Join-Path $ArtifactsDir 'wikigraph_communities.json'
    $CommunityMarkdownPath = Join-Path $ArtifactsDir 'wikigraph_communities.md'
    $MctsPlanPath = Join-Path $ArtifactsDir 'wikigraph_mcts_plan.json'

    New-Item -ItemType Directory -Path $ResolvedDataDir, $ArtifactsDir -Force | Out-Null

    if ($FullScale) {
        $EntityLimit = 0
        $ArticleLimit = 0
    }

    Write-ScriptLog "Starting WikiGraph automation in mode '$Mode'"
    Write-ScriptLog "Data directory: $ResolvedDataDir"
    Write-ScriptLog "KnowledgeGraph: $KnowledgeGraphUrl | Nexus: $NexusUrl"
    Write-ScriptLog "Entity limit: $(if ($EntityLimit -eq 0) { 'full' } else { $EntityLimit }) | Article limit: $(if ($ArticleLimit -eq 0) { 'full' } else { $ArticleLimit })"

    $wikidataDump = Join-Path $WikidataDir 'latest-all.json.gz'
    $wikipediaXml = Join-Path $WikipediaDir 'enwiki-latest-pages-articles-multistream.xml.bz2'

    if ($Download -or $Mode -eq 'Download') {
        if ($PSCmdlet.ShouldProcess('Wikimedia dumps', 'Download requested data sets')) {
            $downloadTarget = if ($Mode -eq 'Download') { 'all' } else { 'all' }
            Invoke-WikiGraphCommand -Arguments @($PipelineScript, 'download', '--dataset', $downloadTarget, '--destination-dir', $ResolvedDataDir)
        }
        if ($Mode -eq 'Download') {
            return
        }
    }

    switch ($Mode) {
        'IngestWikidata' {
            if (-not $DryRun -and -not (Test-Path $wikidataDump)) {
                throw "Wikidata dump not found: $wikidataDump. Re-run with -Download or place the file manually."
            }
            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'ingest-wikidata',
                '--dump-path', $wikidataDump,
                '--knowledge-graph-url', $KnowledgeGraphUrl,
                '--title-map-path', $TitleMapPath,
                '--node-catalog-path', $NodeCatalogPath,
                '--edge-catalog-path', $EdgeCatalogPath,
                '--entity-limit', $EntityLimit,
                '--batch-size', $BatchSize
            )
        }
        'IngestWikipediaText' {
            if (-not $DryRun -and -not (Test-Path $wikipediaXml)) {
                throw "Wikipedia article dump not found: $wikipediaXml. Re-run with -Download or place the file manually."
            }
            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'ingest-wikipedia-text',
                '--xml-path', $wikipediaXml,
                '--nexus-url', $NexusUrl,
                '--title-map-path', $TitleMapPath,
                '--collection', 'wikipedia-articles',
                '--article-limit', $ArticleLimit,
                '--only-mapped'
            )
        }
        'BuildCommunities' {
            if (-not $DryRun -and -not (Test-Path $NodeCatalogPath)) {
                throw "Node catalog not found: $NodeCatalogPath. Run IngestWikidata first."
            }
            if (-not $DryRun -and -not (Test-Path $EdgeCatalogPath)) {
                throw "Edge catalog not found: $EdgeCatalogPath. Run IngestWikidata first."
            }
            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'build-communities',
                '--node-catalog-path', $NodeCatalogPath,
                '--edge-catalog-path', $EdgeCatalogPath,
                '--output-path', $CommunityJsonPath,
                '--summary-markdown-path', $CommunityMarkdownPath,
                '--nexus-url', $NexusUrl,
                '--collection', 'wikigraph-communities'
            )
        }
        'PlanMcts' {
            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'plan-mcts',
                '--output-path', $MctsPlanPath,
                '--collection', 'wikipedia-articles',
                '--title-map-path', $TitleMapPath
            )
        }
        'Full' {
            if (-not $DryRun -and -not (Test-Path $wikidataDump)) {
                throw "Wikidata dump not found: $wikidataDump. Re-run with -Download or place the file manually."
            }
            if (-not $DryRun -and -not (Test-Path $wikipediaXml)) {
                throw "Wikipedia article dump not found: $wikipediaXml. Re-run with -Download or place the file manually."
            }

            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'ingest-wikidata',
                '--dump-path', $wikidataDump,
                '--knowledge-graph-url', $KnowledgeGraphUrl,
                '--title-map-path', $TitleMapPath,
                '--node-catalog-path', $NodeCatalogPath,
                '--edge-catalog-path', $EdgeCatalogPath,
                '--entity-limit', $EntityLimit,
                '--batch-size', $BatchSize
            )

            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'ingest-wikipedia-text',
                '--xml-path', $wikipediaXml,
                '--nexus-url', $NexusUrl,
                '--title-map-path', $TitleMapPath,
                '--collection', 'wikipedia-articles',
                '--article-limit', $ArticleLimit,
                '--only-mapped'
            )

            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'build-communities',
                '--node-catalog-path', $NodeCatalogPath,
                '--edge-catalog-path', $EdgeCatalogPath,
                '--output-path', $CommunityJsonPath,
                '--summary-markdown-path', $CommunityMarkdownPath,
                '--nexus-url', $NexusUrl,
                '--collection', 'wikigraph-communities'
            )

            Invoke-WikiGraphCommand -Arguments @(
                $PipelineScript, 'plan-mcts',
                '--output-path', $MctsPlanPath,
                '--collection', 'wikipedia-articles',
                '--title-map-path', $TitleMapPath
            )
        }
        default {
            throw "Unsupported mode: $Mode"
        }
    }

    Write-ScriptLog 'WikiGraph automation completed successfully.' -Level Success
    if ($PassThru) {
        [pscustomobject]@{
            Mode = $Mode
            DataDir = $ResolvedDataDir
            TitleMapPath = $TitleMapPath
            NodeCatalogPath = $NodeCatalogPath
            EdgeCatalogPath = $EdgeCatalogPath
            CommunityJsonPath = $CommunityJsonPath
            CommunityMarkdownPath = $CommunityMarkdownPath
            MctsPlanPath = $MctsPlanPath
            EntityLimit = $EntityLimit
            ArticleLimit = $ArticleLimit
        }
    }
    exit 0
}
catch {
    Write-ScriptLog "WikiGraph automation failed: $($_.Exception.Message)" -Level Error
    exit 1
}
