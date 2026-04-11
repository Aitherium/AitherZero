@{
    Name = "wikipedia-graphrag"
    Description = "Download Wikimedia dumps, ingest a WikiGraph foundation, build GraphRAG communities, and emit an MCTS handoff plan"
    Version = "1.0.0"
    Author = "AitherZero"
    Category = "knowledge-graph"

    Parameters = @{
        Download = $false
        FullScale = $false
        EntityLimit = 10000
        ArticleLimit = 1000
        BatchSize = 250
        KnowledgeGraphUrl = "http://localhost:8196"
        NexusUrl = "http://localhost:8122"
    }

    Prerequisites = @(
        "Python 3.10+ available in PATH"
        "AitherKnowledgeGraph reachable at port 8196"
        "AitherNexus reachable at port 8122"
        "Sufficient disk space for Wikimedia dumps if Download=true"
    )

    Sequence = @(
        @{
            Name = "Validate Prerequisites"
            Script = "00-bootstrap/0001_Validate-Prerequisites"
            Description = "Verify baseline system readiness before large ingest"
            Parameters = @{
                MinDiskSpaceGB = 100
                MinMemoryGB = 16
            }
            ContinueOnError = $false
        },
        @{
            Name = "Build WikiGraph Foundation"
            Script = "08-aitheros/0849_Build-WikiGraph"
            Description = "Ingest Wikidata graph + Wikipedia article corpus, build community summaries, and write an MCTS plan"
            Parameters = @{
                Mode = "Full"
                Download = '$Download'
                FullScale = '$FullScale'
                EntityLimit = '$EntityLimit'
                ArticleLimit = '$ArticleLimit'
                BatchSize = '$BatchSize'
                KnowledgeGraphUrl = '$KnowledgeGraphUrl'
                NexusUrl = '$NexusUrl'
            }
            ContinueOnError = $false
        }
    )

    OnSuccess = @{
        Message = @"

  ============================================================
  WIKIPEDIA GRAPHRAG FOUNDATION COMPLETE
  ============================================================

  Outputs:
    - Wikidata entities stored in KnowledgeGraph
    - Wikipedia article corpus stored in Nexus
        - GraphRAG community summaries stored in Nexus collection wikigraph-communities
    - MCTS handoff plan written under AitherOS/data/wikigraph/artifacts/

  Next steps:
    - Wire MCTS search actions to graph + Nexus retrieval
    - Benchmark GraphRAG query quality vs baseline RAG

"@
    }

    OnFailure = @{
        Message = @"

  ============================================================
  WIKIPEDIA GRAPHRAG FOUNDATION FAILED
  ============================================================

  Check:
    - Dump files exist or rerun with Download=true
    - KnowledgeGraph and Nexus are reachable
    - Disk space and memory are sufficient for the selected scale

"@
    }
}