
export interface MCPServerConfig {
  id?: string
  name: string
  url: string
  apiKey?: string
  enabled?: boolean
  status?: 'online' | 'offline' | 'error'
}

export interface MCPTool {
  name: string
  description: string
  inputSchema: {
    type: string
    properties: Record<string, any>
    required?: string[]
  }
}

export interface MCPToolCall {
  tool: string
  arguments: Record<string, any>
}

export interface MCPToolResult {
  content: Array<{
    type: 'text' | 'image' | 'resource'
    text?: string
    data?: string
    mimeType?: string
  }>
  isError?: boolean
}

export class MCPClient {
  private config: MCPServerConfig

  constructor(config: MCPServerConfig) {
    this.config = config
  }

  async ping(): Promise<boolean> {
    try {
      const response = await fetch(`${this.config.url}/health`, {
        method: 'GET',
        headers: this.getHeaders(),
        signal: AbortSignal.timeout(5000),
      })
      return response.ok
    } catch {
      return false
    }
  }

  async getServerInfo(): Promise<{ name: string; version: string; capabilities: string[] }> {
    const response = await fetch(`${this.config.url}/info`, {
      headers: this.getHeaders(),
    })

    if (!response.ok) {
      throw new Error(`Failed to get server info: ${response.statusText}`)
    }

    return await response.json()
  }

  async listTools(): Promise<MCPTool[]> {
    const response = await fetch(`${this.config.url}/tools`, {
      headers: this.getHeaders(),
    })

    if (!response.ok) {
      throw new Error(`Failed to list tools: ${response.statusText}`)
    }

    const data = await response.json()
    return data.tools || []
  }

  async callTool(toolName: string, args: Record<string, any>): Promise<MCPToolResult> {
    const response = await fetch(`${this.config.url}/tools/${toolName}`, {
      method: 'POST',
      headers: {
        ...this.getHeaders(),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ arguments: args }),
    })

    if (!response.ok) {
      const error = await response.text()
      throw new Error(`Tool execution failed: ${error}`)
    }

    return await response.json()
  }

  async streamToolCall(
    toolName: string,
    args: Record<string, any>,
    onChunk: (chunk: string) => void
  ): Promise<void> {
    const response = await fetch(`${this.config.url}/tools/${toolName}/stream`, {
      method: 'POST',
      headers: {
        ...this.getHeaders(),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ arguments: args }),
    })

    if (!response.ok) {
      const error = await response.text()
      throw new Error(`Tool execution failed: ${error}`)
    }

    const reader = response.body?.getReader()
    if (!reader) throw new Error('No response body')

    const decoder = new TextDecoder()
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      const chunk = decoder.decode(value)
      onChunk(chunk)
    }
  }

  private getHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      Accept: 'application/json',
    }

    if (this.config.apiKey) {
      headers.Authorization = `Bearer ${this.config.apiKey}`
    }

    return headers
  }
}

export const AITHER_MCP_TOOLS = {
  EXECUTE_WORKFLOW: 'execute_aither_workflow',
  QUERY_CORTEX: 'query_cortex_intelligence',
  DISPATCH_AITHERCORE: 'dispatch_aithercore_task',
  TRAIN_MODEL: 'train_aither_model',
  GENERATE_DATA: 'generate_synthetic_data',
  RUN_BENCHMARK: 'run_benchmark_suite',
  GET_NODE_STATUS: 'get_node_status',
  ANALYZE_CREDIT_USAGE: 'analyze_credit_usage',
  DEPLOY_WORKFLOW: 'deploy_workflow_template',
  QUERY_LOCAL_MODEL: 'query_local_model',
  GENERATE_AITHERIUM: 'generate_aitherium_config',
  RUN_AITHERCORE_JOB: 'run_aithercore_parallel_job',
  GET_TRINITY_STATUS: 'get_trinity_node_status',
} as const

export type AitherMCPTool = typeof AITHER_MCP_TOOLS[keyof typeof AITHER_MCP_TOOLS]

export const MOCK_AITHER_TOOLS: MCPTool[] = [
  {
    name: AITHER_MCP_TOOLS.QUERY_CORTEX,
    description: 'Send high-IQ reasoning query to Gemini 3.0 Pro (CORTEX intelligence)',
    inputSchema: {
      type: 'object',
      properties: {
        prompt: {
          type: 'string',
          description: 'The complex reasoning query to send to Cortex',
        },
        model: {
          type: 'string',
          enum: ['gemini-3.0-pro', 'gemini-2.5-flash', 'gemini-2.0-flash-thinking-exp'],
          description: 'Which Gemini model to use',
        },
        maxTokens: {
          type: 'number',
          description: 'Maximum tokens to generate',
        },
      },
      required: ['prompt'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.DISPATCH_AITHERCORE,
    description: 'Queue a task on the AitherCore distributed compute grid (GitHub Actions)',
    inputSchema: {
      type: 'object',
      properties: {
        taskName: {
          type: 'string',
          description: 'Name of the task to execute',
        },
        workflowFile: {
          type: 'string',
          description: 'Path to workflow YAML file',
        },
        inputs: {
          type: 'object',
          description: 'Workflow input parameters',
        },
        runnerType: {
          type: 'string',
          enum: ['ubuntu-latest', 'ubuntu-latest-64-cores', 'windows-latest', 'macos-latest'],
          description: 'GitHub runner type',
        },
      },
      required: ['taskName', 'workflowFile'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.TRAIN_MODEL,
    description: 'Initiate Aither-7B fine-tuning run on local AitherNode GPU',
    inputSchema: {
      type: 'object',
      properties: {
        datasetPath: {
          type: 'string',
          description: 'Path to training dataset (.jsonl)',
        },
        baseModel: {
          type: 'string',
          description: 'Base model to fine-tune',
        },
        epochs: {
          type: 'number',
          description: 'Number of training epochs',
        },
        batchSize: {
          type: 'number',
          description: 'Training batch size',
        },
        learningRate: {
          type: 'number',
          description: 'Learning rate',
        },
      },
      required: ['datasetPath'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.GENERATE_DATA,
    description: 'Generate synthetic training data using Gemini models',
    inputSchema: {
      type: 'object',
      properties: {
        topic: {
          type: 'string',
          description: 'Topic or domain for data generation',
        },
        rows: {
          type: 'number',
          description: 'Number of examples to generate',
        },
        model: {
          type: 'string',
          enum: ['gemini-1.5-pro', 'gemini-2.5-pro'],
          description: 'Gemini model to use for generation',
        },
        complexity: {
          type: 'string',
          enum: ['basic', 'intermediate', 'advanced', 'expert'],
          description: 'Complexity level of generated examples',
        },
      },
      required: ['topic', 'rows'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.RUN_BENCHMARK,
    description: 'Execute model evaluation benchmark using Gemini as judge',
    inputSchema: {
      type: 'object',
      properties: {
        localModel: {
          type: 'string',
          description: 'Local model to evaluate (e.g., aither-7b, llama-3)',
        },
        testSuite: {
          type: 'string',
          enum: ['coding', 'reasoning', 'creative', 'comprehensive'],
          description: 'Benchmark test suite',
        },
        judgeModel: {
          type: 'string',
          description: 'Gemini model to use as judge',
        },
        testCases: {
          type: 'number',
          description: 'Number of test cases to run',
        },
      },
      required: ['localModel', 'testSuite'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.GET_TRINITY_STATUS,
    description: 'Query status of all Trinity nodes (CORTEX // AITHERCORE // AITHERNODE)',
    inputSchema: {
      type: 'object',
      properties: {
        detailed: {
          type: 'boolean',
          description: 'Include detailed metrics for each node',
        },
      },
      required: [],
    },
  },
  {
    name: AITHER_MCP_TOOLS.QUERY_LOCAL_MODEL,
    description: 'Query a local model running on AitherNode (Ollama)',
    inputSchema: {
      type: 'object',
      properties: {
        model: {
          type: 'string',
          description: 'Model name (e.g., llama3, qwen2.5-coder, aither-7b)',
        },
        prompt: {
          type: 'string',
          description: 'Prompt to send to the model',
        },
        temperature: {
          type: 'number',
          description: 'Temperature (0.0-2.0)',
        },
        maxTokens: {
          type: 'number',
          description: 'Maximum tokens to generate',
        },
      },
      required: ['model', 'prompt'],
    },
  },
  {
    name: AITHER_MCP_TOOLS.GENERATE_AITHERIUM,
    description: 'Generate Aitherium configuration code (.psd1 or .tf)',
    inputSchema: {
      type: 'object',
      properties: {
        intent: {
          type: 'string',
          description: 'Human-readable intent for infrastructure',
        },
        format: {
          type: 'string',
          enum: ['powershell', 'terraform', 'json'],
          description: 'Output format for configuration',
        },
        includeValidation: {
          type: 'boolean',
          description: 'Include validation and tests',
        },
      },
      required: ['intent'],
    },
  },
]
