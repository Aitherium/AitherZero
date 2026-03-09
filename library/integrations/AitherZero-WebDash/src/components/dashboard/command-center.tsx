'use client'

import React, { useState, useEffect, useRef, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import {
  Terminal, Play, Square, Loader2, ChevronDown, ChevronUp,
  Zap, Clock, CheckCircle2, XCircle, AlertTriangle,
  FileCode, Send, Trash2, Copy, Check, RotateCcw,
  Sparkles, Bot, Cpu, Command as CommandIcon, History,
  Settings, Eye, FileText, Bug, HelpCircle
} from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Textarea } from '@/components/ui/textarea'
import { Switch } from '@/components/ui/switch'
import { Label } from '@/components/ui/label'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'

import { aitherZeroService, AutomationScript, Playbook, ScriptExecutionResult, ScriptParameter } from '@/lib/aitherzero-service'
import { aitherOSService, AgentExecutionResult, LocalInferenceResult } from '@/lib/aitheros-service'
import type { AitherAgent, LocalModel } from '@/lib/types'

// ============================================================================
// TYPES
// ============================================================================

interface CommandHistoryItem {
  id: string
  type: 'script' | 'playbook' | 'agent' | 'local-model' | 'custom'
  command: string
  args?: Record<string, unknown>
  result?: ScriptExecutionResult | AgentExecutionResult | LocalInferenceResult
  status: 'pending' | 'running' | 'success' | 'error'
  startedAt: string
  completedAt?: string
  duration?: number
}

interface ExecutionOptions {
  showOutput: boolean
  showTranscript: boolean
  verbose: boolean
  dryRun: boolean
}

interface CommandCenterProps {
  className?: string
  onScriptSelect?: (script: AutomationScript) => void
  onAgentSelect?: (agent: AitherAgent) => void
}

// ============================================================================
// COMMAND CENTER COMPONENT
// ============================================================================

export default function CommandCenter({ className, onScriptSelect, onAgentSelect }: CommandCenterProps) {
  // State
  const [activeTab, setActiveTab] = useState<'scripts' | 'playbooks' | 'agents' | 'models'>('scripts')
  const [scripts, setScripts] = useState<AutomationScript[]>([])
  const [playbooks, setPlaybooks] = useState<Playbook[]>([])
  const [agents, setAgents] = useState<AitherAgent[]>([])
  const [localModels, setLocalModels] = useState<LocalModel[]>([])
  
  const [searchQuery, setSearchQuery] = useState('')
  const [selectedScript, setSelectedScript] = useState<AutomationScript | null>(null)
  const [selectedPlaybook, setSelectedPlaybook] = useState<Playbook | null>(null)
  const [selectedAgent, setSelectedAgent] = useState<AitherAgent | null>(null)
  const [selectedModel, setSelectedModel] = useState<LocalModel | null>(null)
  
  const [commandHistory, setCommandHistory] = useState<CommandHistoryItem[]>([])
  const [isExecuting, setIsExecuting] = useState(false)
  const [promptInput, setPromptInput] = useState('')
  const [scriptParams, setScriptParams] = useState<Record<string, string>>({})
  
  // Execution options state
  const [executionOptions, setExecutionOptions] = useState<ExecutionOptions>({
    showOutput: true,
    showTranscript: false,
    verbose: false,
    dryRun: false
  })
  const [showOptionsPanel, setShowOptionsPanel] = useState(false)
  
  const [isLoading, setIsLoading] = useState(true)
  const [copiedId, setCopiedId] = useState<string | null>(null)
  const outputRef = useRef<HTMLDivElement>(null)

  // Load initial data
  useEffect(() => {
    async function loadData() {
      setIsLoading(true)
      try {
        const [scriptsData, playbooksData, agentsData, modelsData] = await Promise.all([
          aitherZeroService.listScripts(),
          aitherZeroService.listPlaybooks(),
          aitherOSService.listAgents(),
          aitherOSService.listLocalModels()
        ])
        
        setScripts(scriptsData)
        setPlaybooks(playbooksData)
        setAgents(agentsData)
        setLocalModels(modelsData)
      } catch (error) {
        console.error('Failed to load command center data:', error)
      } finally {
        setIsLoading(false)
      }
    }

    loadData()
  }, [])

  // Auto-scroll output
  useEffect(() => {
    if (outputRef.current) {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [commandHistory])

  // Filter items based on search
  const filteredScripts = scripts.filter(s => 
    s.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    s.description.toLowerCase().includes(searchQuery.toLowerCase()) ||
    s.number.includes(searchQuery)
  )

  const filteredPlaybooks = playbooks.filter(p =>
    p.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    p.description.toLowerCase().includes(searchQuery.toLowerCase())
  )

  // Execute script
  const executeScript = useCallback(async (script: AutomationScript) => {
    // Build command string with options for display
    const optionFlags = [
      executionOptions.showOutput && '-ShowOutput',
      executionOptions.showTranscript && '-ShowTranscript',
      executionOptions.verbose && '-Verbose',
      executionOptions.dryRun && '-DryRun'
    ].filter(Boolean).join(' ')

    const paramFlags = Object.entries(scriptParams)
      .filter(([, v]) => v)
      .map(([k, v]) => `-${k} ${v}`)
      .join(' ')

    const commandDisplay = `Invoke-AitherScript ${script.number}${optionFlags ? ' ' + optionFlags : ''}${paramFlags ? ' ' + paramFlags : ''}`

    const historyItem: CommandHistoryItem = {
      id: `cmd-${Date.now()}`,
      type: 'script',
      command: commandDisplay,
      args: { ...scriptParams, ...executionOptions },
      status: 'running',
      startedAt: new Date().toISOString()
    }
    
    setCommandHistory(prev => [...prev, historyItem])
    setIsExecuting(true)

    try {
      const result = await aitherZeroService.executeScript({
        scriptNumber: script.number,
        params: scriptParams,
        verbose: executionOptions.verbose,
        dryRun: executionOptions.dryRun,
        showOutput: executionOptions.showOutput,
        showTranscript: executionOptions.showTranscript
      })

      setCommandHistory(prev => prev.map(item => 
        item.id === historyItem.id 
          ? {
              ...item,
              result,
              status: result.success ? 'success' : 'error',
              completedAt: new Date().toISOString(),
              duration: result.duration
            }
          : item
      ))
    } catch (error) {
      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result: { success: false, output: '', error: String(error) },
              status: 'error',
              completedAt: new Date().toISOString()
            }
          : item
      ))
    } finally {
      setIsExecuting(false)
    }
  }, [scriptParams, executionOptions])

  // Execute playbook
  const executePlaybook = useCallback(async (playbook: Playbook) => {
    const historyItem: CommandHistoryItem = {
      id: `cmd-${Date.now()}`,
      type: 'playbook',
      command: `Invoke-AitherPlaybook ${playbook.name}`,
      status: 'running',
      startedAt: new Date().toISOString()
    }

    setCommandHistory(prev => [...prev, historyItem])
    setIsExecuting(true)

    try {
      const result = await aitherZeroService.executePlaybook({
        playbookName: playbook.name,
        profile: 'standard'
      })

      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result,
              status: result.success ? 'success' : 'error',
              completedAt: new Date().toISOString(),
              duration: result.duration
            }
          : item
      ))
    } catch (error) {
      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result: { success: false, output: '', error: String(error) },
              status: 'error',
              completedAt: new Date().toISOString()
            }
          : item
      ))
    } finally {
      setIsExecuting(false)
    }
  }, [])

  // Execute agent task
  const executeAgentTask = useCallback(async (agent: AitherAgent, prompt: string) => {
    if (!prompt.trim()) return

    const historyItem: CommandHistoryItem = {
      id: `cmd-${Date.now()}`,
      type: 'agent',
      command: `${agent.name}: ${prompt.substring(0, 50)}...`,
      args: { prompt },
      status: 'running',
      startedAt: new Date().toISOString()
    }

    setCommandHistory(prev => [...prev, historyItem])
    setIsExecuting(true)
    setPromptInput('')

    try {
      const result = await aitherOSService.executeAgentTask({
        agentId: agent.id,
        prompt
      })

      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result,
              status: result.success ? 'success' : 'error',
              completedAt: new Date().toISOString(),
              duration: result.latencyMs
            }
          : item
      ))
    } catch (error) {
      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result: { success: false, output: '', error: String(error) },
              status: 'error',
              completedAt: new Date().toISOString()
            }
          : item
      ))
    } finally {
      setIsExecuting(false)
    }
  }, [])

  // Query local model
  const queryLocalModel = useCallback(async (model: LocalModel, prompt: string) => {
    if (!prompt.trim()) return

    const historyItem: CommandHistoryItem = {
      id: `cmd-${Date.now()}`,
      type: 'local-model',
      command: `${model.displayName}: ${prompt.substring(0, 50)}...`,
      args: { prompt, model: model.name },
      status: 'running',
      startedAt: new Date().toISOString()
    }

    setCommandHistory(prev => [...prev, historyItem])
    setIsExecuting(true)
    setPromptInput('')

    try {
      const result = await aitherOSService.queryLocalModel({
        model: model.name,
        prompt,
        temperature: 0.7
      })

      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result,
              status: result.success ? 'success' : 'error',
              completedAt: new Date().toISOString(),
              duration: result.latencyMs
            }
          : item
      ))
    } catch (error) {
      setCommandHistory(prev => prev.map(item =>
        item.id === historyItem.id
          ? {
              ...item,
              result: { success: false, output: '', error: String(error) },
              status: 'error',
              completedAt: new Date().toISOString()
            }
          : item
      ))
    } finally {
      setIsExecuting(false)
    }
  }, [])

  // Copy output to clipboard
  const copyOutput = useCallback((id: string, text: string) => {
    navigator.clipboard.writeText(text)
    setCopiedId(id)
    setTimeout(() => setCopiedId(null), 2000)
  }, [])

  // Clear history
  const clearHistory = useCallback(() => {
    setCommandHistory([])
  }, [])

  // Format duration
  const formatDuration = (ms?: number) => {
    if (!ms) return '-'
    if (ms < 1000) return `${ms}ms`
    return `${(ms / 1000).toFixed(2)}s`
  }

  // Get status icon
  const getStatusIcon = (status: CommandHistoryItem['status']) => {
    switch (status) {
      case 'pending':
        return <Clock className="w-4 h-4 text-muted-foreground" />
      case 'running':
        return <Loader2 className="w-4 h-4 text-blue-500 animate-spin" />
      case 'success':
        return <CheckCircle2 className="w-4 h-4 text-green-500" />
      case 'error':
        return <XCircle className="w-4 h-4 text-red-500" />
    }
  }

  // Get type badge color
  const getTypeBadge = (type: CommandHistoryItem['type']) => {
    switch (type) {
      case 'script':
        return <Badge variant="outline" className="bg-blue-500/10 text-blue-500 border-blue-500/20">Script</Badge>
      case 'playbook':
        return <Badge variant="outline" className="bg-purple-500/10 text-purple-500 border-purple-500/20">Playbook</Badge>
      case 'agent':
        return <Badge variant="outline" className="bg-green-500/10 text-green-500 border-green-500/20">Agent</Badge>
      case 'local-model':
        return <Badge variant="outline" className="bg-orange-500/10 text-orange-500 border-orange-500/20">Local</Badge>
      default:
        return <Badge variant="outline">Custom</Badge>
    }
  }

  return (
    <div className={`grid grid-cols-1 lg:grid-cols-3 gap-6 h-full ${className}`}>
      {/* Left Panel: Selection */}
      <Card className="lg:col-span-1 flex flex-col">
        <CardHeader className="pb-3">
          <div className="flex items-center justify-between">
            <CardTitle className="text-base flex items-center gap-2">
              <CommandIcon className="w-4 h-4 text-primary" />
              Command Palette
            </CardTitle>
            <Badge variant="secondary" className="font-mono text-xs">
              {activeTab === 'scripts' ? scripts.length : 
               activeTab === 'playbooks' ? playbooks.length :
               activeTab === 'agents' ? agents.length : localModels.length}
            </Badge>
          </div>
          <CardDescription>Select tools, agents, or models to execute</CardDescription>
        </CardHeader>

        <div className="px-4 pb-3">
          <Input
            placeholder="Search..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="h-9"
          />
        </div>

        <Tabs value={activeTab} onValueChange={(v) => setActiveTab(v as typeof activeTab)} className="flex-1 flex flex-col">
          <TabsList className="mx-4 h-9">
            <TabsTrigger value="scripts" className="text-xs flex-1">
              <FileCode className="w-3 h-3 mr-1" /> Scripts
            </TabsTrigger>
            <TabsTrigger value="playbooks" className="text-xs flex-1">
              <Zap className="w-3 h-3 mr-1" /> Playbooks
            </TabsTrigger>
            <TabsTrigger value="agents" className="text-xs flex-1">
              <Bot className="w-3 h-3 mr-1" /> Agents
            </TabsTrigger>
            <TabsTrigger value="models" className="text-xs flex-1">
              <Cpu className="w-3 h-3 mr-1" /> Models
            </TabsTrigger>
          </TabsList>

          <CardContent className="flex-1 p-0 pt-3">
            <ScrollArea className="h-[400px] px-4">
              <TabsContent value="scripts" className="m-0 space-y-2">
                {isLoading ? (
                  <div className="flex items-center justify-center py-8">
                    <Loader2 className="w-6 h-6 animate-spin text-muted-foreground" />
                  </div>
                ) : (
                  filteredScripts.map(script => (
                    <motion.div
                      key={script.number}
                      initial={{ opacity: 0, y: 5 }}
                      animate={{ opacity: 1, y: 0 }}
                      className={`p-3 rounded-lg border cursor-pointer transition-all hover:bg-accent ${
                        selectedScript?.number === script.number ? 'bg-accent border-primary' : ''
                      }`}
                      onClick={() => setSelectedScript(script)}
                    >
                      <div className="flex items-center justify-between mb-1">
                        <span className="font-mono text-xs text-muted-foreground">{script.number}</span>
                        <Badge variant="secondary" className="text-[10px]">{script.category}</Badge>
                      </div>
                      <div className="font-medium text-sm">{script.name}</div>
                      <div className="text-xs text-muted-foreground mt-1 line-clamp-2">{script.description}</div>
                    </motion.div>
                  ))
                )}
              </TabsContent>

              <TabsContent value="playbooks" className="m-0 space-y-2">
                {filteredPlaybooks.map(playbook => (
                  <motion.div
                    key={playbook.name}
                    initial={{ opacity: 0, y: 5 }}
                    animate={{ opacity: 1, y: 0 }}
                    className={`p-3 rounded-lg border cursor-pointer transition-all hover:bg-accent ${
                      selectedPlaybook?.name === playbook.name ? 'bg-accent border-primary' : ''
                    }`}
                    onClick={() => setSelectedPlaybook(playbook)}
                  >
                    <div className="flex items-center gap-2 mb-1">
                      <Sparkles className="w-3 h-3 text-purple-500" />
                      <span className="font-medium text-sm">{playbook.name}</span>
                    </div>
                    <div className="text-xs text-muted-foreground">{playbook.description}</div>
                    <div className="flex gap-1 mt-2 flex-wrap">
                      {playbook.scripts.slice(0, 4).map((s: string) => (
                        <Badge key={s} variant="outline" className="text-[10px] h-5">{s}</Badge>
                      ))}
                      {playbook.scripts.length > 4 && (
                        <Badge variant="outline" className="text-[10px] h-5">+{playbook.scripts.length - 4}</Badge>
                      )}
                    </div>
                  </motion.div>
                ))}
              </TabsContent>

              <TabsContent value="agents" className="m-0 space-y-2">
                {agents.map(agent => (
                  <motion.div
                    key={agent.id}
                    initial={{ opacity: 0, y: 5 }}
                    animate={{ opacity: 1, y: 0 }}
                    className={`p-3 rounded-lg border cursor-pointer transition-all hover:bg-accent ${
                      selectedAgent?.id === agent.id ? 'bg-accent border-primary' : ''
                    }`}
                    onClick={() => setSelectedAgent(agent)}
                  >
                    <div className="flex items-center justify-between mb-1">
                      <div className="flex items-center gap-2">
                        <Bot className="w-4 h-4 text-green-500" />
                        <span className="font-medium text-sm">{agent.name}</span>
                      </div>
                      <Badge 
                        variant={agent.status === 'running' ? 'default' : 'secondary'} 
                        className="text-[10px]"
                      >
                        {agent.status}
                      </Badge>
                    </div>
                    <div className="text-xs text-muted-foreground">{agent.persona}</div>
                    <div className="text-xs text-muted-foreground/70 mt-1 font-mono">
                      {agent.currentModel}
                    </div>
                  </motion.div>
                ))}
              </TabsContent>

              <TabsContent value="models" className="m-0 space-y-2">
                {localModels.length === 0 ? (
                  <div className="text-center py-8 text-muted-foreground text-sm">
                    <Cpu className="w-8 h-8 mx-auto mb-2 opacity-50" />
                    <p>No local models available</p>
                    <p className="text-xs mt-1">Start Ollama to see models</p>
                  </div>
                ) : (
                  localModels.map(model => (
                    <motion.div
                      key={model.id}
                      initial={{ opacity: 0, y: 5 }}
                      animate={{ opacity: 1, y: 0 }}
                      className={`p-3 rounded-lg border cursor-pointer transition-all hover:bg-accent ${
                        selectedModel?.id === model.id ? 'bg-accent border-primary' : ''
                      }`}
                      onClick={() => setSelectedModel(model)}
                    >
                      <div className="flex items-center justify-between mb-1">
                        <span className="font-medium text-sm">{model.displayName}</span>
                        <Badge variant="outline" className="text-[10px]">{model.size}</Badge>
                      </div>
                      <div className="text-xs text-muted-foreground font-mono">{model.name}</div>
                      {model.quantization && (
                        <div className="text-[10px] text-muted-foreground/70 mt-1">
                          {model.quantization} • {model.parameters}
                        </div>
                      )}
                    </motion.div>
                  ))
                )}
              </TabsContent>
            </ScrollArea>
          </CardContent>
        </Tabs>

        {/* Action Footer */}
        <div className="p-4 border-t space-y-3">
          {(activeTab === 'agents' && selectedAgent) || (activeTab === 'models' && selectedModel) ? (
            <div className="space-y-2">
              <Textarea
                placeholder={`Send a message to ${selectedAgent?.name || selectedModel?.displayName}...`}
                value={promptInput}
                onChange={(e) => setPromptInput(e.target.value)}
                className="min-h-[80px] resize-none text-sm"
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault()
                    if (selectedAgent) executeAgentTask(selectedAgent, promptInput)
                    if (selectedModel) queryLocalModel(selectedModel, promptInput)
                  }
                }}
              />
              <Button 
                className="w-full" 
                disabled={isExecuting || !promptInput.trim()}
                onClick={() => {
                  if (selectedAgent) executeAgentTask(selectedAgent, promptInput)
                  if (selectedModel) queryLocalModel(selectedModel, promptInput)
                }}
              >
                {isExecuting ? (
                  <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Executing...</>
                ) : (
                  <><Send className="w-4 h-4 mr-2" /> Send</>
                )}
              </Button>
            </div>
          ) : (
            <div className="space-y-3">
              {/* Execution Options Panel (for scripts) */}
              {activeTab === 'scripts' && selectedScript && (
                <Collapsible open={showOptionsPanel} onOpenChange={setShowOptionsPanel}>
                  <CollapsibleTrigger asChild>
                    <Button variant="ghost" size="sm" className="w-full justify-between h-8 text-xs">
                      <span className="flex items-center gap-2">
                        <Settings className="w-3 h-3" />
                        Execution Options
                        {(executionOptions.showOutput || executionOptions.verbose || executionOptions.dryRun || executionOptions.showTranscript) && (
                          <Badge variant="secondary" className="text-[10px] h-4 px-1">
                            {[
                              executionOptions.showOutput && 'Output',
                              executionOptions.showTranscript && 'Transcript',
                              executionOptions.verbose && 'Verbose',
                              executionOptions.dryRun && 'DryRun'
                            ].filter(Boolean).length} active
                          </Badge>
                        )}
                      </span>
                      {showOptionsPanel ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
                    </Button>
                  </CollapsibleTrigger>
                  <CollapsibleContent className="pt-2 space-y-3">
                    {/* Output Switches */}
                    <div className="grid grid-cols-2 gap-3 p-3 rounded-lg border bg-muted/30">
                      <TooltipProvider>
                        <div className="flex items-center justify-between">
                          <Tooltip>
                            <TooltipTrigger asChild>
                              <Label htmlFor="showOutput" className="text-xs flex items-center gap-1.5 cursor-pointer">
                                <Eye className="w-3 h-3 text-blue-500" />
                                Show Output
                              </Label>
                            </TooltipTrigger>
                            <TooltipContent side="top" className="text-xs">
                              Display script output in console
                            </TooltipContent>
                          </Tooltip>
                          <Switch
                            id="showOutput"
                            checked={executionOptions.showOutput}
                            onCheckedChange={(checked) => 
                              setExecutionOptions(prev => ({ ...prev, showOutput: checked }))
                            }
                          />
                        </div>
                        
                        <div className="flex items-center justify-between">
                          <Tooltip>
                            <TooltipTrigger asChild>
                              <Label htmlFor="showTranscript" className="text-xs flex items-center gap-1.5 cursor-pointer">
                                <FileText className="w-3 h-3 text-purple-500" />
                                Transcript
                              </Label>
                            </TooltipTrigger>
                            <TooltipContent side="top" className="text-xs">
                              Display transcript after execution
                            </TooltipContent>
                          </Tooltip>
                          <Switch
                            id="showTranscript"
                            checked={executionOptions.showTranscript}
                            onCheckedChange={(checked) => 
                              setExecutionOptions(prev => ({ ...prev, showTranscript: checked }))
                            }
                          />
                        </div>
                        
                        <div className="flex items-center justify-between">
                          <Tooltip>
                            <TooltipTrigger asChild>
                              <Label htmlFor="verbose" className="text-xs flex items-center gap-1.5 cursor-pointer">
                                <Bug className="w-3 h-3 text-orange-500" />
                                Verbose
                              </Label>
                            </TooltipTrigger>
                            <TooltipContent side="top" className="text-xs">
                              Enable verbose logging output
                            </TooltipContent>
                          </Tooltip>
                          <Switch
                            id="verbose"
                            checked={executionOptions.verbose}
                            onCheckedChange={(checked) => 
                              setExecutionOptions(prev => ({ ...prev, verbose: checked }))
                            }
                          />
                        </div>
                        
                        <div className="flex items-center justify-between">
                          <Tooltip>
                            <TooltipTrigger asChild>
                              <Label htmlFor="dryRun" className="text-xs flex items-center gap-1.5 cursor-pointer">
                                <HelpCircle className="w-3 h-3 text-yellow-500" />
                                Dry Run
                              </Label>
                            </TooltipTrigger>
                            <TooltipContent side="top" className="text-xs">
                              Preview execution without running
                            </TooltipContent>
                          </Tooltip>
                          <Switch
                            id="dryRun"
                            checked={executionOptions.dryRun}
                            onCheckedChange={(checked) => 
                              setExecutionOptions(prev => ({ ...prev, dryRun: checked }))
                            }
                          />
                        </div>
                      </TooltipProvider>
                    </div>

                    {/* Script Parameters */}
                    {selectedScript.parameters && selectedScript.parameters.length > 0 && (
                      <div className="space-y-2">
                        <Label className="text-xs text-muted-foreground">Script Parameters</Label>
                        <div className="space-y-2 p-3 rounded-lg border bg-muted/30">
                          {selectedScript.parameters.map((param) => (
                            <div key={param.name} className="space-y-1">
                              <Label htmlFor={param.name} className="text-xs flex items-center gap-1">
                                {param.name}
                                {param.required && <span className="text-red-500">*</span>}
                                <span className="text-muted-foreground font-normal">({param.type})</span>
                              </Label>
                              {param.type === 'boolean' ? (
                                <Switch
                                  id={param.name}
                                  checked={scriptParams[param.name] === 'true'}
                                  onCheckedChange={(checked) => 
                                    setScriptParams(prev => ({ ...prev, [param.name]: String(checked) }))
                                  }
                                />
                              ) : (
                                <Input
                                  id={param.name}
                                  placeholder={param.description || param.name}
                                  value={scriptParams[param.name] || ''}
                                  onChange={(e) => 
                                    setScriptParams(prev => ({ ...prev, [param.name]: e.target.value }))
                                  }
                                  className="h-7 text-xs"
                                />
                              )}
                              {param.description && (
                                <p className="text-[10px] text-muted-foreground">{param.description}</p>
                              )}
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                  </CollapsibleContent>
                </Collapsible>
              )}
              
              <Button 
                className="w-full"
                disabled={
                  isExecuting || 
                  (activeTab === 'scripts' && !selectedScript) ||
                  (activeTab === 'playbooks' && !selectedPlaybook)
                }
                onClick={() => {
                  if (selectedScript) executeScript(selectedScript)
                  if (selectedPlaybook) executePlaybook(selectedPlaybook)
                }}
              >
                {isExecuting ? (
                  <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Executing...</>
                ) : executionOptions.dryRun ? (
                  <><HelpCircle className="w-4 h-4 mr-2" /> Preview</>
                ) : (
                  <><Play className="w-4 h-4 mr-2" /> Execute</>
                )}
              </Button>
            </div>
          )}
        </div>
      </Card>

      {/* Right Panel: Output */}
      <Card className="lg:col-span-2 flex flex-col">
        <CardHeader className="pb-3">
          <div className="flex items-center justify-between">
            <CardTitle className="text-base flex items-center gap-2">
              <Terminal className="w-4 h-4 text-green-500" />
              Execution Output
            </CardTitle>
            <div className="flex items-center gap-2">
              <Badge variant="secondary" className="font-mono text-xs">
                <History className="w-3 h-3 mr-1" />
                {commandHistory.length}
              </Badge>
              <Button variant="ghost" size="icon-sm" onClick={clearHistory} disabled={commandHistory.length === 0}>
                <Trash2 className="w-4 h-4" />
              </Button>
            </div>
          </div>
        </CardHeader>

        <CardContent className="flex-1 p-0 overflow-hidden">
          <ScrollArea ref={outputRef} className="h-[600px]">
            <div className="p-4 space-y-4">
              {commandHistory.length === 0 ? (
                <div className="flex flex-col items-center justify-center py-16 text-muted-foreground">
                  <Terminal className="w-12 h-12 mb-4 opacity-30" />
                  <p className="text-sm">No commands executed yet</p>
                  <p className="text-xs mt-1">Select a script, playbook, or agent to get started</p>
                </div>
              ) : (
                commandHistory.map((item, index) => (
                  <motion.div
                    key={item.id}
                    initial={{ opacity: 0, y: 10 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ delay: index * 0.05 }}
                    className="border rounded-lg overflow-hidden"
                  >
                    {/* Header */}
                    <div className="flex items-center justify-between px-4 py-2 bg-muted/50 border-b">
                      <div className="flex items-center gap-3">
                        {getStatusIcon(item.status)}
                        <code className="text-sm font-mono">{item.command}</code>
                        {getTypeBadge(item.type)}
                      </div>
                      <div className="flex items-center gap-2 text-xs text-muted-foreground">
                        <Clock className="w-3 h-3" />
                        {formatDuration(item.duration)}
                        {item.result && 'output' in item.result && item.result.output && (
                          <Button
                            variant="ghost"
                            size="icon-sm"
                            onClick={() => copyOutput(item.id, item.result && 'output' in item.result ? item.result.output : '')}
                            className="h-6 w-6"
                          >
                            {copiedId === item.id ? (
                              <Check className="w-3 h-3 text-green-500" />
                            ) : (
                              <Copy className="w-3 h-3" />
                            )}
                          </Button>
                        )}
                      </div>
                    </div>

                    {/* Output */}
                    <div className="p-4 bg-black/5 dark:bg-black/20">
                      {item.status === 'running' ? (
                        <div className="flex items-center gap-2 text-sm text-muted-foreground">
                          <Loader2 className="w-4 h-4 animate-spin" />
                          Executing...
                        </div>
                      ) : item.result && 'error' in item.result && item.result.error ? (
                        <div className="text-red-500 text-sm font-mono whitespace-pre-wrap">
                          Error: {item.result.error}
                        </div>
                      ) : item.result && 'output' in item.result ? (
                        <pre className="text-sm font-mono whitespace-pre-wrap text-foreground/90 overflow-x-auto">
                          {item.result.output || 'No output'}
                        </pre>
                      ) : (
                        <div className="text-muted-foreground text-sm">Awaiting result...</div>
                      )}
                    </div>
                  </motion.div>
                ))
              )}
            </div>
          </ScrollArea>
        </CardContent>
      </Card>
    </div>
  )
}
