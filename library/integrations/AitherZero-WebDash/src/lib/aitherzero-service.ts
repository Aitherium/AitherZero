/**
 * AitherZero Service Layer
 * 
 * Handles communication with AitherZero PowerShell automation platform
 * via the MCP server bridge for script execution, playbooks, and configuration
 */

import { mcpService, MCPToolExecution } from './mcp-service'

// ============================================================================
// TYPES
// ============================================================================

export interface AutomationScript {
  number: string
  name: string
  description: string
  category: string
  parameters?: ScriptParameter[]
  lastRun?: string
  status?: 'success' | 'failed' | 'running' | 'never'
}

export interface ScriptParameter {
  name: string
  type: 'string' | 'number' | 'boolean' | 'array'
  description?: string
  required?: boolean
  default?: unknown
}

export interface Playbook {
  name: string
  description: string
  scripts: string[]
  profile?: string
  variables?: Record<string, unknown>
  lastRun?: string
}

export interface ScriptExecutionRequest {
  scriptNumber: string
  params?: Record<string, unknown>
  verbose?: boolean
  dryRun?: boolean
  showOutput?: boolean
  showTranscript?: boolean
}

export interface ScriptExecutionResult {
  success: boolean
  output: string
  exitCode?: number
  duration?: number
  error?: string
}

export interface PlaybookExecutionRequest {
  playbookName: string
  profile?: 'quick' | 'standard' | 'full' | 'ci'
  variables?: Record<string, unknown>
}

export interface ProjectInfo {
  name: string
  path: string
  language: 'PowerShell' | 'Python' | 'OpenTofu'
  template: 'Standard' | 'Minimal'
  createdAt?: string
  lastModified?: string
}

export interface DomainInfo {
  name: string
  moduleCount: number
  path: string
  description?: string
}

export interface SystemInfo {
  os: string
  psVersion: string
  hostname: string
  uptime?: string
  memory?: {
    total: number
    free: number
    used: number
  }
  disk?: {
    total: number
    free: number
    used: number
  }
  cpu?: string
  ip?: string[]
}

export interface ServiceStatus {
  Name: string
  Status: 'Running' | 'Stopped'
  PID: number | null
  Port: number
  PortOpen: boolean
  MemoryMB: number
  Uptime?: string
}

// ============================================================================
// SCRIPT CATEGORIES
// ============================================================================

export const SCRIPT_CATEGORIES = {
  ENVIRONMENT: { range: '0000-0099', name: 'Environment Setup', icon: 'Settings' },
  INFRASTRUCTURE: { range: '0100-0199', name: 'Infrastructure', icon: 'Server' },
  DEVELOPMENT: { range: '0200-0299', name: 'Development Tools', icon: 'Code' },
  TESTING: { range: '0400-0499', name: 'Testing', icon: 'FlaskConical' },
  REPORTING: { range: '0500-0599', name: 'Reporting', icon: 'BarChart' },
  SECURITY: { range: '0600-0699', name: 'Security', icon: 'Shield' },
  DEVWORKFLOWS: { range: '0700-0799', name: 'Dev Workflows', icon: 'GitBranch' },
  EXTENSIONS: { range: '8000-8999', name: 'Extensions', icon: 'Puzzle' },
  MAINTENANCE: { range: '9000-9999', name: 'Maintenance', icon: 'Wrench' }
} as const

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function extractOutput(execution: MCPToolExecution): string {
  if (!execution.result) return ''
  return execution.result.content
    .map(c => c.text || '')
    .join('\n')
}

function executionToResult(execution: MCPToolExecution): ScriptExecutionResult {
  return {
    success: execution.status === 'success',
    output: extractOutput(execution),
    duration: execution.durationMs,
    error: execution.status === 'error' ? extractOutput(execution) : undefined
  }
}

// ============================================================================
// AITHERZERO SERVICE
// ============================================================================

export class AitherZeroService {
  
  constructor() {
    // Auto-start MCP server on initialization
    this.ensureMCPConnected()
  }

  private async ensureMCPConnected(): Promise<boolean> {
    try {
      const status = await mcpService.checkStatus()
      if (!status.running) {
        await mcpService.start()
      }
      return true
    } catch (error) {
      console.error('Failed to connect to MCP server:', error)
      return false
    }
  }

  async getServiceStatus(services: string[] = ['ComfyUI', 'Ollama', 'AitherNode', 'Cloudflared']): Promise<ServiceStatus[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.runScript('0012', {
        Services: services,
        AsJson: true
      })
      
      if (execution.status === 'success') {
        const output = extractOutput(execution)
        try {
          // Find the JSON part (it might be surrounded by logs)
          const jsonMatch = output.match(/\[[\s\S]*\]/)
          if (jsonMatch) {
            return JSON.parse(jsonMatch[0])
          }
          return JSON.parse(output)
        } catch {
          console.warn('Failed to parse service status JSON', output)
        }
      }
    } catch (error) {
      console.error('Failed to get service status:', error)
    }

    // Fallback to mock data if script fails
    return services.map(name => ({
      Name: name,
      Status: 'Stopped',
      PID: null,
      Port: 0,
      PortOpen: false,
      MemoryMB: 0
    }))
  }

  async stopService(serviceName: string): Promise<{ success: boolean; error?: string }> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.runScript('0013', {
        Name: serviceName,
        Force: true
      })
      
      if (execution.status === 'success') {
        return { success: true }
      }
      return { success: false, error: extractOutput(execution) }
    } catch (error) {
      return { success: false, error: String(error) }
    }
  }

  async startService(serviceId: string, port?: number): Promise<{ success: boolean; output?: string; error?: string }> {
    try {
      await this.ensureMCPConnected()
      
      let scriptNumber = ''
      switch (serviceId) {
        case 'comfyui': scriptNumber = '0734'; break;
        case 'comfyui-gateway': scriptNumber = '0732'; break;
        case 'ollama': scriptNumber = '0737'; break;
        case 'aithernode': scriptNumber = '0762'; break;
        default: return { success: false, error: `Unknown service ID: ${serviceId}` }
      }

      const execution = await mcpService.runScript(scriptNumber, {
        ShowOutput: true,
        Detached: true,
        ...(port ? { Port: port.toString() } : {})
      })
      
      if (execution.status === 'success') {
        return { success: true, output: extractOutput(execution) }
      }
      return { success: false, error: extractOutput(execution) }
    } catch (error) {
      return { success: false, error: String(error) }
    }
  }

  // ---------------------------------------------------------------------------
  // Script Management
  // ---------------------------------------------------------------------------

  async listScripts(category?: string): Promise<AutomationScript[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.listScripts(category)
      
      if (execution.status === 'success') {
        return this.parseScriptList(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to list scripts:', error)
    }

    return this.getMockScripts()
  }

  async searchScripts(query: string): Promise<AutomationScript[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('search_scripts', { query })
      
      if (execution.status === 'success') {
        return this.parseScriptList(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to search scripts:', error)
    }

    // Fallback: filter mock scripts
    const allScripts = this.getMockScripts()
    const lowerQuery = query.toLowerCase()
    return allScripts.filter(s => 
      s.name.toLowerCase().includes(lowerQuery) || 
      s.description.toLowerCase().includes(lowerQuery)
    )
  }

  async executeScript(request: ScriptExecutionRequest): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.runScript(
        request.scriptNumber,
        request.params,
        { 
          verbose: request.verbose, 
          dryRun: request.dryRun,
          showOutput: request.showOutput,
          showTranscript: request.showTranscript
        }
      )
      return executionToResult(execution)
    } catch (error) {
      return {
        success: false,
        output: '',
        error: String(error)
      }
    }
  }

  async getScriptHelp(scriptNumber: string): Promise<string> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('get_automation_help', {
        target: scriptNumber,
        type: 'script'
      })
      
      if (execution.status === 'success') {
        return extractOutput(execution)
      }
    } catch (error) {
      console.error('Failed to get script help:', error)
    }

    return `Script ${scriptNumber}\n\nNo documentation available.`
  }

  // ---------------------------------------------------------------------------
  // Playbook Management
  // ---------------------------------------------------------------------------

  async listPlaybooks(): Promise<Playbook[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('list_playbooks', {})
      
      if (execution.status === 'success') {
        return this.parsePlaybookList(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to list playbooks:', error)
    }

    return this.getMockPlaybooks()
  }

  async executePlaybook(request: PlaybookExecutionRequest): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executePlaybook(
        request.playbookName,
        request.profile,
        request.variables
      )
      return executionToResult(execution)
    } catch (error) {
      return {
        success: false,
        output: '',
        error: String(error)
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Configuration Management
  // ---------------------------------------------------------------------------

  async getConfiguration(section?: string, key?: string): Promise<Record<string, unknown>> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.getConfiguration(section, key)
      
      if (execution.status === 'success') {
        const output = extractOutput(execution)
        try {
          return JSON.parse(output)
        } catch {
          return { raw: output }
        }
      }
    } catch (error) {
      console.error('Failed to get configuration:', error)
    }

    return this.getMockConfiguration()
  }

  async setConfiguration(
    section: string, 
    key: string, 
    value: unknown, 
    scope: 'local' | 'global' = 'local'
  ): Promise<{ success: boolean; error?: string }> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('set_configuration', {
        section, key, value, scope
      })
      return { success: execution.status === 'success' }
    } catch (error) {
      return { success: false, error: String(error) }
    }
  }

  // ---------------------------------------------------------------------------
  // Project Management
  // ---------------------------------------------------------------------------

  async listProjects(nameFilter?: string): Promise<ProjectInfo[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('list_projects', { name: nameFilter })
      
      if (execution.status === 'success') {
        return this.parseProjectList(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to list projects:', error)
    }

    return []
  }

  async createProject(options: {
    path: string
    name?: string
    language?: 'PowerShell' | 'Python' | 'OpenTofu'
    template?: 'Standard' | 'Minimal'
    includeCI?: boolean
    includeVSCode?: boolean
    gitInit?: boolean
  }): Promise<{ success: boolean; output?: string; error?: string }> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.newProject(options)
      
      return {
        success: execution.status === 'success',
        output: extractOutput(execution),
        error: execution.status === 'error' ? extractOutput(execution) : undefined
      }
    } catch (error) {
      return { success: false, error: String(error) }
    }
  }

  // ---------------------------------------------------------------------------
  // Domain Information
  // ---------------------------------------------------------------------------

  async getDomainInfo(domain?: string): Promise<DomainInfo[]> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('get_domain_info', { domain })
      
      if (execution.status === 'success') {
        return this.parseDomainInfo(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to get domain info:', error)
    }

    return this.getMockDomains()
  }

  // ---------------------------------------------------------------------------
  // System Information
  // ---------------------------------------------------------------------------

  async getSystemInfo(): Promise<SystemInfo> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.getSystemInfo()
      
      if (execution.status === 'success') {
        return this.parseSystemInfo(extractOutput(execution))
      }
    } catch (error) {
      console.error('Failed to get system info:', error)
    }

    return {
      os: 'Windows 11',
      psVersion: '7.4.0',
      hostname: 'aither-dev'
    }
  }

  async getLogs(lines: number = 100): Promise<string> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.getLogs(lines)
      
      if (execution.status === 'success') {
        return extractOutput(execution)
      }
    } catch (error) {
      console.error('Failed to get logs:', error)
    }

    return 'No logs available - MCP server not connected'
  }

  async getProjectReport(format?: 'text' | 'json' | 'markdown'): Promise<string> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('get_project_report', { format })
      
      if (execution.status === 'success') {
        return extractOutput(execution)
      }
    } catch (error) {
      console.error('Failed to get project report:', error)
    }

    return 'Project report not available - MCP server not connected'
  }

  // ---------------------------------------------------------------------------
  // Git Operations
  // ---------------------------------------------------------------------------

  async createBranch(name: string, base?: string): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.gitOperations('create_branch', { name, base })
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  async commitChanges(message: string, files?: string): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.gitOperations('commit', { message, files })
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  async createPullRequest(title: string, body?: string, draft?: boolean): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.gitOperations('create_pr', { title, body, draft })
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  // ---------------------------------------------------------------------------
  // Quality & Testing
  // ---------------------------------------------------------------------------

  async runTests(path?: string, tag?: string): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.runTests(path, tag)
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  async runQualityCheck(path?: string): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.runQualityCheck(path)
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  async buildModule(): Promise<ScriptExecutionResult> {
    try {
      await this.ensureMCPConnected()
      const execution = await mcpService.executeTool('build_module', {})
      return executionToResult(execution)
    } catch (error) {
      return { success: false, output: '', error: String(error) }
    }
  }

  // ---------------------------------------------------------------------------
  // Parsing Helpers
  // ---------------------------------------------------------------------------

  private parseScriptList(text: string): AutomationScript[] {
    const lines = text.split('\n').filter(l => l.trim())
    const scripts: AutomationScript[] = []

    for (const line of lines.slice(2)) {
      const match = line.match(/^(\d{4})\s+(.+?)\s{2,}(.+)$/)
      if (match) {
        scripts.push({
          number: match[1],
          name: match[2].trim(),
          description: match[3].trim(),
          category: this.getCategoryForScript(match[1])
        })
      }
    }

    return scripts.length > 0 ? scripts : this.getMockScripts()
  }

  private parsePlaybookList(text: string): Playbook[] {
    const lines = text.split('\n').filter(l => l.trim())
    const playbooks: Playbook[] = []

    for (const line of lines.slice(2)) {
      const match = line.match(/^(\S+)\s+(.+)$/)
      if (match) {
        playbooks.push({
          name: match[1].trim(),
          description: match[2].trim(),
          scripts: []
        })
      }
    }

    return playbooks.length > 0 ? playbooks : this.getMockPlaybooks()
  }

  private parseProjectList(text: string): ProjectInfo[] {
    try {
      return JSON.parse(text)
    } catch {
      return []
    }
  }

  private parseDomainInfo(text: string): DomainInfo[] {
    const lines = text.split('\n').filter(l => l.trim())
    const domains: DomainInfo[] = []

    for (const line of lines.slice(2)) {
      const match = line.match(/^(\S+)\s+(\d+)\s+(.+)$/)
      if (match) {
        domains.push({
          name: match[1].trim(),
          moduleCount: parseInt(match[2]),
          path: match[3].trim()
        })
      }
    }

    return domains.length > 0 ? domains : this.getMockDomains()
  }

  private parseSystemInfo(text: string): SystemInfo {
    try {
      // Try parsing as JSON first
      const data = JSON.parse(text)
      return {
        os: data.Platform || 'Unknown',
        psVersion: data.PowerShellVersion || '',
        hostname: data.ComputerName || '',
        memory: data.MemoryInfo ? {
          total: data.MemoryInfo.TotalGB,
          free: data.MemoryInfo.FreeGB,
          used: data.MemoryInfo.UsedGB
        } : undefined,
        disk: data.DiskInfo && data.DiskInfo.length > 0 ? {
          total: data.DiskInfo[0].TotalGB,
          free: data.DiskInfo[0].FreeGB,
          used: data.DiskInfo[0].UsedGB
        } : undefined,
        cpu: data.ProcessorName,
        ip: data.IPAddresses
      }
    } catch {
      // Fallback to text parsing
      const info: SystemInfo = { os: '', psVersion: '', hostname: '' }
      const lines = text.split('\n')
      
      let currentSection = ''
      
      for (const line of lines) {
        const trimmed = line.trim()
        if (!trimmed) continue
        
        if (trimmed.includes('System Information')) currentSection = 'general'
        else if (trimmed.includes('Memory:')) currentSection = 'memory'
        else if (trimmed.includes('Disk Information:')) currentSection = 'disk'
        
        if (line.includes('Computer Name:')) info.hostname = line.split(':')[1]?.trim() || ''
        if (line.includes('Platform:')) info.os = line.split(':')[1]?.trim() || ''
        if (line.includes('PowerShell:')) info.psVersion = line.split(':')[1]?.trim() || ''
        if (line.includes('CPU:')) info.cpu = line.split(':')[1]?.trim() || ''
        
        // Memory parsing
        if (currentSection === 'memory') {
          if (!info.memory) info.memory = { total: 0, free: 0, used: 0 }
          if (line.includes('Total:')) info.memory.total = parseFloat(line.split(':')[1]?.replace('GB', '').trim() || '0')
          if (line.includes('Free:')) info.memory.free = parseFloat(line.split(':')[1]?.replace('GB', '').trim() || '0')
          if (line.includes('Used:')) info.memory.used = parseFloat(line.split(':')[1]?.replace('GB', '').trim() || '0')
        }
        
        // Disk parsing (first disk)
        if (currentSection === 'disk' && !info.disk) {
          if (line.includes('Total:') && line.includes('Free:')) {
            const parts = line.split('|')
            info.disk = {
              total: parseFloat(parts[0]?.split(':')[1]?.replace('GB', '').trim() || '0'),
              free: parseFloat(parts[1]?.split(':')[1]?.replace('GB', '').trim() || '0'),
              used: 0
            }
            info.disk.used = info.disk.total - info.disk.free
          }
        }
      }
      return info
    }
  }

  private getCategoryForScript(number: string): string {
    const num = parseInt(number)
    if (num < 100) return 'Environment'
    if (num < 200) return 'Infrastructure'
    if (num < 300) return 'Development'
    if (num < 500) return 'Testing'
    if (num < 600) return 'Reporting'
    if (num < 700) return 'Security'
    if (num < 800) return 'Dev Workflows'
    if (num < 9000) return 'Extensions'
    return 'Maintenance'
  }

  // ---------------------------------------------------------------------------
  // Mock Data (Fallback when MCP unavailable)
  // ---------------------------------------------------------------------------

  private getMockScripts(): AutomationScript[] {
    return [
      { number: '0011', name: 'Get-SystemInfo', description: 'Gather system information and environment details', category: 'Environment' },
      { number: '0206', name: 'Setup-DevEnvironment', description: 'Configure complete development environment', category: 'Development' },
      { number: '0207', name: 'Configure-Git', description: 'Setup Git and GitHub CLI configuration', category: 'Development' },
      { number: '0402', name: 'Run-UnitTests', description: 'Execute Pester unit tests', category: 'Testing' },
      { number: '0403', name: 'Run-IntegrationTests', description: 'Execute Pester integration tests', category: 'Testing' },
      { number: '0404', name: 'Run-PSScriptAnalyzer', description: 'Run PSScriptAnalyzer quality checks', category: 'Testing' },
      { number: '0510', name: 'Get-ProjectReport', description: 'Generate comprehensive project metrics report', category: 'Reporting' },
      { number: '0701', name: 'Create-Branch', description: 'Create a new Git branch', category: 'Dev Workflows' },
      { number: '0702', name: 'Commit-Changes', description: 'Commit changes with standardized message', category: 'Dev Workflows' },
      { number: '0703', name: 'Create-PullRequest', description: 'Create a GitHub pull request', category: 'Dev Workflows' },
      { number: '0906', name: 'Validate-Syntax', description: 'Validate PowerShell syntax', category: 'Maintenance' },
      { number: '9010', name: 'Scan-DiskUsage', description: 'Analyze disk usage and identify large files', category: 'Maintenance' }
    ]
  }

  private getMockPlaybooks(): Playbook[] {
    return [
      { 
        name: 'code-quality-full', 
        description: 'Complete code quality validation suite',
        scripts: ['0404', '0402', '0403', '0906']
      },
      { 
        name: 'pr-validation', 
        description: 'PR pre-merge validation checks',
        scripts: ['0906', '0404', '0402']
      },
      { 
        name: 'dev-environment-setup', 
        description: 'Setup complete development environment',
        scripts: ['0011', '0206', '0207']
      },
      { 
        name: 'comprehensive-validation', 
        description: 'Full project validation with reporting',
        scripts: ['0906', '0404', '0402', '0403', '0510']
      }
    ]
  }

  private getMockConfiguration(): Record<string, unknown> {
    return {
      Core: {
        Environment: 'development',
        Profile: 'Standard',
        LogLevel: 'Information'
      },
      Features: {
        MCP: true,
        Extensions: true,
        AIAgents: true
      },
      Testing: {
        Coverage: true,
        MinCoverage: 80
      }
    }
  }

  private getMockDomains(): DomainInfo[] {
    return [
      { name: 'Automation', moduleCount: 8, path: 'src/public/Automation' },
      { name: 'CLI', moduleCount: 5, path: 'src/public/CLI' },
      { name: 'Configuration', moduleCount: 4, path: 'src/public/Configuration' },
      { name: 'Infrastructure', moduleCount: 6, path: 'src/public/Infrastructure' },
      { name: 'Integrations', moduleCount: 3, path: 'src/public/Integrations' },
      { name: 'Projects', moduleCount: 4, path: 'src/public/Projects' },
      { name: 'Reporting', moduleCount: 5, path: 'src/public/Reporting' },
      { name: 'Security', moduleCount: 3, path: 'src/public/Security' },
      { name: 'Testing', moduleCount: 4, path: 'src/public/Testing' },
      { name: 'Utilities', moduleCount: 7, path: 'src/public/Utilities' }
    ]
  }
}

// Export singleton instance
export const aitherZeroService = new AitherZeroService()
