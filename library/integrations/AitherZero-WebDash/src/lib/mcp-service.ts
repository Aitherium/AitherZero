/**
 * MCP Service Layer
 * 
 * Manages connection to the AitherZero MCP server via the HTTP bridge API.
 * Provides tool discovery and execution capabilities.
 */

// ============================================================================
// TYPES
// ============================================================================

export type MCPServerStatus = 'connected' | 'disconnected' | 'connecting' | 'error' | 'unknown'
export type MCPServerType = 'aitherzero' | 'aithernode' | 'filesystem' | 'github' | 'browser' | 'custom'

export interface MCPTool {
  name: string
  description: string
  inputSchema: {
    type: string
    properties: Record<string, {
      type: string
      description?: string
      enum?: string[]
      default?: unknown
    }>
    required?: string[]
  }
}

export interface MCPResource {
  uri: string
  name: string
  description?: string
  mimeType?: string
}

export interface MCPPrompt {
  name: string
  description?: string
  arguments?: Array<{
    name: string
    description?: string
    required?: boolean
  }>
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

/** Extended server info for UI panel */
export interface MCPServerInfo {
  id: string
  name: string
  url: string
  type: MCPServerType
  status: MCPServerStatus
  version?: string
  tools: MCPTool[]
  resources?: MCPResource[]
  prompts?: MCPPrompt[]
  capabilities?: string[]
  latencyMs?: number
  error?: string
  autoStart?: boolean
}

/** Registration info for adding new servers */
export interface MCPServerRegistration {
  name: string
  url: string
  type: MCPServerType
  autoConnect?: boolean
}

/** Internal server info from API */
interface InternalServerInfo {
  running: boolean
  ready: boolean
  serverPath: string
  aitherZeroRoot: string
  tools?: MCPTool[]
  resources?: MCPResource[]
  prompts?: MCPPrompt[]
  error?: string
}

export interface MCPToolExecution {
  id: string
  serverId?: string
  serverName?: string
  toolName: string
  args: Record<string, unknown>
  status: 'pending' | 'running' | 'success' | 'error'
  result?: MCPToolResult
  startedAt: string
  completedAt?: string
  durationMs?: number
}

// ============================================================================
// MCP SERVICE
// ============================================================================

class MCPServiceImpl {
  private status: MCPServerStatus = 'disconnected'
  private tools: MCPTool[] = []
  private resources: MCPResource[] = []
  private prompts: MCPPrompt[] = []
  private executions: MCPToolExecution[] = []
  private listeners: Set<(servers: MCPServerInfo[]) => void> = new Set()
  private internalInfo: InternalServerInfo | null = null
  private servers: MCPServerInfo[] = []

  // ---------------------------------------------------------------------------
  // Connection Management
  // ---------------------------------------------------------------------------

  async checkStatus(): Promise<InternalServerInfo> {
    try {
      const response = await fetch('/api/mcp?action=status')
      const info: InternalServerInfo = await response.json()
      this.internalInfo = info
      this.status = info.running && info.ready ? 'connected' : 'disconnected'
      
      // Update main AitherZero server in list
      this.updateMainServer(info)
      this.notifyListeners()
      return info
    } catch (error) {
      this.status = 'error'
      this.internalInfo = null
      this.notifyListeners()
      throw error
    }
  }

  private updateMainServer(info: InternalServerInfo): void {
    const mainServerIndex = this.servers.findIndex(s => s.id === 'aitherzero-mcp')
    const mainServer: MCPServerInfo = {
      id: 'aitherzero-mcp',
      name: 'AitherZero MCP',
      url: info.serverPath || 'stdio://localhost',
      type: 'aitherzero',
      status: info.running && info.ready ? 'connected' : 'disconnected',
      version: '1.0.0',
      tools: info.tools || this.tools,
      resources: info.resources,
      prompts: info.prompts,
      capabilities: ['tools', 'resources', 'prompts'],
      error: info.error,
      autoStart: true
    }

    if (mainServerIndex >= 0) {
      this.servers[mainServerIndex] = mainServer
    } else {
      this.servers.unshift(mainServer)
    }
  }

  async start(): Promise<void> {
    this.status = 'connecting'
    this.notifyListeners()

    try {
      const response = await fetch('/api/mcp?action=start')
      const result = await response.json()
      
      if (!result.success) {
        throw new Error(result.error || 'Failed to start MCP server')
      }

      // Wait a moment for server to be ready
      await new Promise(resolve => setTimeout(resolve, 1000))
      
      // Check status and load tools
      await this.checkStatus()
      await this.loadTools()
      await this.loadResources()
      await this.loadPrompts()

      this.status = 'connected'
      this.notifyListeners()
    } catch (error) {
      this.status = 'error'
      this.notifyListeners()
      throw error
    }
  }

  async stop(): Promise<void> {
    try {
      await fetch('/api/mcp?action=stop')
      this.status = 'disconnected'
      this.tools = []
      this.resources = []
      this.prompts = []
      
      // Update main server status
      const mainServerIndex = this.servers.findIndex(s => s.id === 'aitherzero-mcp')
      if (mainServerIndex >= 0) {
        this.servers[mainServerIndex].status = 'disconnected'
        this.servers[mainServerIndex].tools = []
      }
      
      this.notifyListeners()
    } catch (error) {
      this.status = 'error'
      this.notifyListeners()
      throw error
    }
  }

  getStatus(): MCPServerStatus {
    return this.status
  }

  getInternalInfo(): InternalServerInfo | null {
    return this.internalInfo
  }

  // ---------------------------------------------------------------------------
  // Multi-Server Management (for UI Panel)
  // ---------------------------------------------------------------------------

  getMockServers(): MCPServerInfo[] {
    return [
      {
        id: 'aitherzero-mcp',
        name: 'AitherZero MCP',
        url: 'stdio://aitherzero-mcp',
        type: 'aitherzero',
        status: this.status,
        version: '1.0.0',
        tools: this.tools.length > 0 ? this.tools : this.getMockTools(),
        capabilities: ['tools', 'resources', 'prompts', 'automation', 'git'],
        autoStart: true
      },
      {
        id: 'aithernode-mcp',
        name: 'AitherNode Media',
        url: 'http://localhost:8080',
        type: 'aithernode',
        status: 'disconnected',
        version: '1.0.0',
        tools: [
          { name: 'generate_image', description: 'Generate images with ComfyUI', inputSchema: { type: 'object', properties: {} } },
          { name: 'process_video', description: 'Process and edit video files', inputSchema: { type: 'object', properties: {} } }
        ],
        capabilities: ['media', 'gpu', 'comfyui'],
        autoStart: false
      },
      {
        id: 'filesystem-mcp',
        name: 'Filesystem',
        url: 'stdio://filesystem-mcp',
        type: 'filesystem',
        status: 'disconnected',
        version: '1.0.0',
        tools: [
          { name: 'read_file', description: 'Read file contents', inputSchema: { type: 'object', properties: {} } },
          { name: 'write_file', description: 'Write file contents', inputSchema: { type: 'object', properties: {} } },
          { name: 'list_directory', description: 'List directory contents', inputSchema: { type: 'object', properties: {} } }
        ],
        capabilities: ['read', 'write', 'search'],
        autoStart: false
      }
    ]
  }

  private getMockTools(): MCPTool[] {
    return [
      { name: 'run_script', description: 'Execute AitherZero automation scripts', inputSchema: { type: 'object', properties: { scriptNumber: { type: 'string', description: 'Script number (0000-9999)' } }, required: ['scriptNumber'] } },
      { name: 'execute_playbook', description: 'Run automation playbooks', inputSchema: { type: 'object', properties: { playbookName: { type: 'string' } }, required: ['playbookName'] } },
      { name: 'list_scripts', description: 'List available automation scripts', inputSchema: { type: 'object', properties: { category: { type: 'string' } } } },
      { name: 'get_configuration', description: 'Get AitherZero configuration', inputSchema: { type: 'object', properties: { section: { type: 'string' }, key: { type: 'string' } } } },
      { name: 'get_system_info', description: 'Get system information', inputSchema: { type: 'object', properties: {} } },
      { name: 'git_operations', description: 'Perform git operations', inputSchema: { type: 'object', properties: { operation: { type: 'string', enum: ['status', 'commit', 'branch', 'pr'] } } } },
      { name: 'run_tests', description: 'Execute Pester tests', inputSchema: { type: 'object', properties: { path: { type: 'string' }, tag: { type: 'string' } } } },
      { name: 'run_quality_check', description: 'Run PSScriptAnalyzer', inputSchema: { type: 'object', properties: { path: { type: 'string' } } } }
    ]
  }

  getServers(): MCPServerInfo[] {
    return this.servers.length > 0 ? this.servers : this.getMockServers()
  }

  async connectServer(serverId: string): Promise<boolean> {
    const serverIndex = this.servers.findIndex(s => s.id === serverId)
    if (serverIndex >= 0) {
      this.servers[serverIndex].status = 'connecting'
      this.notifyListeners()
    }

    if (serverId === 'aitherzero-mcp') {
      try {
        await this.start()
        return true
      } catch {
        return false
      }
    }

    // Mock connection for other servers
    await new Promise(resolve => setTimeout(resolve, 1000))
    if (serverIndex >= 0) {
      this.servers[serverIndex].status = 'connected'
      this.notifyListeners()
    }
    return true
  }

  async disconnectServer(serverId: string): Promise<void> {
    if (serverId === 'aitherzero-mcp') {
      await this.stop()
      return
    }

    const serverIndex = this.servers.findIndex(s => s.id === serverId)
    if (serverIndex >= 0) {
      this.servers[serverIndex].status = 'disconnected'
      this.notifyListeners()
    }
  }

  async refreshServer(serverId: string): Promise<void> {
    if (serverId === 'aitherzero-mcp') {
      await this.loadTools()
      await this.loadResources()
      await this.loadPrompts()
    }
    this.notifyListeners()
  }

  async refreshAllServers(): Promise<void> {
    await this.checkStatus()
    await this.loadTools()
    this.notifyListeners()
  }

  async removeServer(serverId: string): Promise<void> {
    this.servers = this.servers.filter(s => s.id !== serverId)
    this.notifyListeners()
  }

  async registerServer(registration: MCPServerRegistration): Promise<MCPServerInfo> {
    const newServer: MCPServerInfo = {
      id: `${registration.type}-${Date.now()}`,
      name: registration.name,
      url: registration.url,
      type: registration.type,
      status: registration.autoConnect ? 'connecting' : 'disconnected',
      tools: [],
      autoStart: registration.autoConnect
    }

    this.servers.push(newServer)
    this.notifyListeners()

    if (registration.autoConnect) {
      await this.connectServer(newServer.id)
    }

    return newServer
  }

  // ---------------------------------------------------------------------------
  // Tool Management
  // ---------------------------------------------------------------------------

  async loadTools(): Promise<MCPTool[]> {
    try {
      const response = await fetch('/api/mcp?action=tools')
      const result = await response.json()
      
      if (result.success && result.tools?.tools) {
        this.tools = result.tools.tools
      }
      
      this.notifyListeners()
      return this.tools
    } catch (error) {
      console.error('Failed to load tools:', error)
      return []
    }
  }

  getTools(): MCPTool[] {
    return this.tools
  }

  getTool(name: string): MCPTool | undefined {
    return this.tools.find(t => t.name === name)
  }

  // ---------------------------------------------------------------------------
  // Resource Management
  // ---------------------------------------------------------------------------

  async loadResources(): Promise<MCPResource[]> {
    try {
      const response = await fetch('/api/mcp?action=resources')
      const result = await response.json()
      
      if (result.success && result.resources?.resources) {
        this.resources = result.resources.resources
      }
      
      this.notifyListeners()
      return this.resources
    } catch (error) {
      console.error('Failed to load resources:', error)
      return []
    }
  }

  getResources(): MCPResource[] {
    return this.resources
  }

  async readResource(uri: string): Promise<string> {
    try {
      const response = await fetch('/api/mcp', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'resources/read',
          params: { uri }
        })
      })
      
      const result = await response.json()
      
      if (!result.success) {
        throw new Error(result.error || 'Failed to read resource')
      }
      
      return result.result?.contents?.[0]?.text || ''
    } catch (error) {
      console.error('Failed to read resource:', error)
      throw error
    }
  }

  // ---------------------------------------------------------------------------
  // Prompt Management
  // ---------------------------------------------------------------------------

  async loadPrompts(): Promise<MCPPrompt[]> {
    try {
      const response = await fetch('/api/mcp?action=prompts')
      const result = await response.json()
      
      if (result.success && result.prompts?.prompts) {
        this.prompts = result.prompts.prompts
      }
      
      this.notifyListeners()
      return this.prompts
    } catch (error) {
      console.error('Failed to load prompts:', error)
      return []
    }
  }

  getPrompts(): MCPPrompt[] {
    return this.prompts
  }

  async getPrompt(name: string, args?: Record<string, string>): Promise<string> {
    try {
      const response = await fetch('/api/mcp', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'prompts/get',
          params: { name, arguments: args }
        })
      })
      
      const result = await response.json()
      
      if (!result.success) {
        throw new Error(result.error || 'Failed to get prompt')
      }
      
      return result.result?.messages?.[0]?.content?.text || ''
    } catch (error) {
      console.error('Failed to get prompt:', error)
      throw error
    }
  }

  // ---------------------------------------------------------------------------
  // Tool Execution
  // ---------------------------------------------------------------------------

  async executeTool(
    serverIdOrToolName: string, 
    toolNameOrArgs: string | Record<string, unknown>,
    argsOptional?: Record<string, unknown>
  ): Promise<MCPToolExecution> {
    // Support both old (toolName, args) and new (serverId, toolName, args) signatures
    let toolName: string
    let args: Record<string, unknown>
    let serverId: string | undefined

    if (typeof toolNameOrArgs === 'string') {
      // New signature: (serverId, toolName, args)
      serverId = serverIdOrToolName
      toolName = toolNameOrArgs
      args = argsOptional || {}
    } else {
      // Old signature: (toolName, args)
      toolName = serverIdOrToolName
      args = toolNameOrArgs
    }

    const execution: MCPToolExecution = {
      id: `exec-${Date.now()}`,
      serverId,
      toolName,
      args,
      status: 'pending',
      startedAt: new Date().toISOString()
    }

    this.executions.unshift(execution)
    this.notifyListeners()

    try {
      execution.status = 'running'
      this.notifyListeners()

      const startTime = Date.now()

      const response = await fetch('/api/mcp', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          method: 'tools/call',
          params: {
            name: toolName,
            arguments: args
          }
        })
      })

      const result = await response.json()
      
      execution.durationMs = Date.now() - startTime
      execution.completedAt = new Date().toISOString()

      if (!result.success) {
        execution.status = 'error'
        execution.result = {
          content: [{ type: 'text', text: result.error || 'Unknown error' }],
          isError: true
        }
      } else {
        execution.status = result.result?.isError ? 'error' : 'success'
        execution.result = result.result
      }

    } catch (error) {
      execution.status = 'error'
      execution.result = {
        content: [{ type: 'text', text: error instanceof Error ? error.message : 'Unknown error' }],
        isError: true
      }
      execution.completedAt = new Date().toISOString()
    }

    this.notifyListeners()
    return execution
  }

  getExecutions(limit: number = 50): MCPToolExecution[] {
    return this.executions.slice(0, limit)
  }

  clearExecutions(): void {
    this.executions = []
    this.notifyListeners()
  }

  // ---------------------------------------------------------------------------
  // Convenience Methods for Common AitherZero Tools
  // ---------------------------------------------------------------------------

  async runScript(
    scriptNumber: string, 
    params?: Record<string, unknown>,
    options?: { 
      verbose?: boolean
      dryRun?: boolean
      showOutput?: boolean
      showTranscript?: boolean
    }
  ): Promise<MCPToolExecution> {
    return this.executeTool('run_script', {
      scriptNumber,
      params: params || {},
      showOutput: options?.showOutput ?? true,  // Default to true for WebDash
      showTranscript: options?.showTranscript,
      verbose: options?.verbose,
      dryRun: options?.dryRun
    })
  }

  async executePlaybook(
    playbookName: string,
    profile?: string,
    variables?: Record<string, unknown>
  ): Promise<MCPToolExecution> {
    return this.executeTool('execute_playbook', {
      playbookName,
      profile: profile || 'standard',
      variables: variables || {}
    })
  }

  async listScripts(category?: string): Promise<MCPToolExecution> {
    return this.executeTool('list_scripts', { category })
  }

  async getConfiguration(section?: string, key?: string): Promise<MCPToolExecution> {
    return this.executeTool('get_configuration', { section, key })
  }

  async getSystemInfo(): Promise<MCPToolExecution> {
    return this.executeTool('get_system_info', {})
  }

  async getLogs(lines: number = 100): Promise<MCPToolExecution> {
    return this.executeTool('get_logs', { lines })
  }

  async runTests(path?: string, tag?: string): Promise<MCPToolExecution> {
    return this.executeTool('run_tests', { path, tag })
  }

  async runQualityCheck(path?: string): Promise<MCPToolExecution> {
    return this.executeTool('run_quality_check', { path })
  }

  async gitOperations(
    operation: 'status' | 'create_branch' | 'commit' | 'create_pr',
    args: Record<string, unknown>
  ): Promise<MCPToolExecution> {
    return this.executeTool('git_operations', { operation, args })
  }

  async newProject(options: {
    path: string
    name?: string
    language?: 'PowerShell' | 'Python' | 'OpenTofu'
    template?: 'Standard' | 'Minimal'
    gitInit?: boolean
  }): Promise<MCPToolExecution> {
    return this.executeTool('new_project', options)
  }

  async invokeAgent(
    agent: 'Gemini' | 'Claude' | 'Codex',
    prompt: string,
    context?: string
  ): Promise<MCPToolExecution> {
    return this.executeTool('invoke_agent', { agent, prompt, context })
  }

  // ---------------------------------------------------------------------------
  // Event Subscription
  // ---------------------------------------------------------------------------

  subscribe(listener: (servers: MCPServerInfo[]) => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  private notifyListeners(): void {
    const servers = this.getServers()
    this.listeners.forEach(listener => listener(servers))
  }
}

// Export singleton instance
export const mcpService = new MCPServiceImpl()

// Re-export types for backward compatibility
export type { MCPTool as MCPToolDef }
