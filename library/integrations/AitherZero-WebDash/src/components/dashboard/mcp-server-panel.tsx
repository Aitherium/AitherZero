'use client'

import React, { useState, useEffect, useCallback } from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import {
  Server, Wifi, WifiOff, RefreshCw, Play, Square, Settings,
  Terminal, Loader2, ChevronDown, ChevronUp, Plus, Trash2,
  CheckCircle2, XCircle, AlertTriangle, Clock, Zap, Code2,
  ExternalLink, Copy, Check, Search, Filter, MoreVertical,
  Plug, PlugZap, Database, Globe, HardDrive, Brain, Cpu,
  FileJson, MessageSquare, Wrench, Eye, EyeOff, Send
} from 'lucide-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle, CardDescription, CardFooter } from '@/components/ui/card'
import { Badge } from '@/components/ui/badge'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter } from '@/components/ui/dialog'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger, DropdownMenuSeparator } from '@/components/ui/dropdown-menu'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import { Progress } from '@/components/ui/progress'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@/components/ui/collapsible'

import { 
  mcpService, 
  MCPServerInfo, 
  MCPServerStatus, 
  MCPToolExecution,
  MCPServerRegistration 
} from '@/lib/mcp-service'
import type { MCPTool } from '@/lib/mcp-client'

// ============================================================================
// TYPES
// ============================================================================

interface MCPServerPanelProps {
  className?: string
  compact?: boolean
  onToolExecute?: (execution: MCPToolExecution) => void
}

// ============================================================================
// HELPER COMPONENTS
// ============================================================================

function ServerStatusBadge({ status }: { status: MCPServerStatus }) {
  const config: Record<string, { variant: 'default' | 'secondary' | 'destructive' | 'outline', color: string, icon: typeof Wifi, label: string }> = {
    connected: { variant: 'default', color: 'bg-green-500', icon: Wifi, label: 'Connected' },
    disconnected: { variant: 'secondary', color: 'bg-gray-500', icon: WifiOff, label: 'Disconnected' },
    connecting: { variant: 'secondary', color: 'bg-blue-500', icon: Loader2, label: 'Connecting' },
    error: { variant: 'destructive', color: 'bg-red-500', icon: AlertTriangle, label: 'Error' },
    unknown: { variant: 'outline', color: 'bg-gray-400', icon: HardDrive, label: 'Unknown' }
  }

  const { variant, color, icon: Icon, label } = config[status] || config.unknown

  return (
    <Badge variant={variant} className="gap-1.5">
      <Icon className={`w-3 h-3 ${status === 'connecting' ? 'animate-spin' : ''}`} />
      {label}
    </Badge>
  )
}

function ServerTypeIcon({ type }: { type: MCPServerInfo['type'] }) {
  const icons: Record<string, React.ReactElement> = {
    aitherzero: <Zap className="w-4 h-4 text-purple-500" />,
    aithernode: <Cpu className="w-4 h-4 text-orange-500" />,
    filesystem: <HardDrive className="w-4 h-4 text-blue-500" />,
    github: <Globe className="w-4 h-4 text-gray-500" />,
    browser: <Globe className="w-4 h-4 text-green-500" />,
    custom: <Server className="w-4 h-4 text-muted-foreground" />
  }
  return icons[type] || icons.custom
}

// ============================================================================
// SERVER CARD COMPONENT
// ============================================================================

function ServerCard({
  server,
  onConnect,
  onDisconnect,
  onRefresh,
  onRemove,
  onSelectTool,
  isExpanded,
  onToggleExpand
}: {
  server: MCPServerInfo
  onConnect: () => void
  onDisconnect: () => void
  onRefresh: () => void
  onRemove: () => void
  onSelectTool: (tool: MCPTool) => void
  isExpanded: boolean
  onToggleExpand: () => void
}) {
  const isConnected = server.status === 'connected'
  const isConnecting = server.status === 'connecting'

  return (
    <motion.div
      layout
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: -10 }}
    >
      <Card className={`relative overflow-hidden ${isConnected ? 'border-l-4 border-l-green-500' : ''}`}>
        {/* Header */}
        <CardHeader className="pb-2">
          <div className="flex items-start justify-between">
            <div className="flex items-center gap-3">
              <div className={`p-2 rounded-lg ${isConnected ? 'bg-primary/10' : 'bg-muted'}`}>
                <ServerTypeIcon type={server.type} />
              </div>
              <div>
                <CardTitle className="text-base flex items-center gap-2">
                  {server.name}
                  {server.version && (
                    <Badge variant="outline" className="text-[10px] h-4 font-mono">
                      v{server.version}
                    </Badge>
                  )}
                </CardTitle>
                <CardDescription className="text-xs font-mono">
                  {server.url}
                </CardDescription>
              </div>
            </div>

            <div className="flex items-center gap-2">
              <ServerStatusBadge status={server.status} />
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="ghost" size="icon-sm" className="h-7 w-7">
                    <MoreVertical className="w-4 h-4" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  {isConnected ? (
                    <DropdownMenuItem onClick={onDisconnect}>
                      <WifiOff className="w-4 h-4 mr-2" /> Disconnect
                    </DropdownMenuItem>
                  ) : (
                    <DropdownMenuItem onClick={onConnect} disabled={isConnecting}>
                      <Wifi className="w-4 h-4 mr-2" /> Connect
                    </DropdownMenuItem>
                  )}
                  <DropdownMenuItem onClick={onRefresh}>
                    <RefreshCw className="w-4 h-4 mr-2" /> Refresh
                  </DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onClick={onRemove} className="text-red-500">
                    <Trash2 className="w-4 h-4 mr-2" /> Remove
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
          </div>
        </CardHeader>

        <CardContent className="pt-0">
          {/* Metrics Row */}
          {isConnected && (
            <div className="flex items-center gap-4 mb-3 text-xs">
              <div className="flex items-center gap-1 text-muted-foreground">
                <Wrench className="w-3 h-3" />
                <span>{server.tools.length} tools</span>
              </div>
              {server.resources && server.resources.length > 0 && (
                <div className="flex items-center gap-1 text-muted-foreground">
                  <Database className="w-3 h-3" />
                  <span>{server.resources.length} resources</span>
                </div>
              )}
              {server.prompts && server.prompts.length > 0 && (
                <div className="flex items-center gap-1 text-muted-foreground">
                  <MessageSquare className="w-3 h-3" />
                  <span>{server.prompts.length} prompts</span>
                </div>
              )}
              {server.latencyMs && (
                <div className="flex items-center gap-1 text-muted-foreground">
                  <Clock className="w-3 h-3" />
                  <span>{server.latencyMs}ms</span>
                </div>
              )}
            </div>
          )}

          {/* Capabilities */}
          {isConnected && server.capabilities && server.capabilities.length > 0 && (
            <div className="flex gap-1 mb-3 flex-wrap">
              {server.capabilities.map((cap: string) => (
                <Badge key={cap} variant="secondary" className="text-[10px] h-5">
                  {cap}
                </Badge>
              ))}
            </div>
          )}

          {/* Error Display */}
          {server.error && (
            <div className="p-2 rounded-lg bg-red-500/10 border border-red-500/20 text-red-500 text-xs mb-3">
              {server.error}
            </div>
          )}

          {/* Expandable Tools Section */}
          {isConnected && server.tools.length > 0 && (
            <Collapsible open={isExpanded} onOpenChange={onToggleExpand}>
              <CollapsibleTrigger asChild>
                <Button variant="ghost" size="sm" className="w-full justify-between h-8">
                  <span className="text-xs flex items-center gap-2">
                    <Code2 className="w-3 h-3" />
                    Available Tools
                  </span>
                  {isExpanded ? (
                    <ChevronUp className="w-4 h-4" />
                  ) : (
                    <ChevronDown className="w-4 h-4" />
                  )}
                </Button>
              </CollapsibleTrigger>
              <CollapsibleContent>
                <div className="mt-2 space-y-1 max-h-[200px] overflow-y-auto">
                  {server.tools.map((tool: MCPTool) => (
                    <div
                      key={tool.name}
                      className="p-2 rounded-lg border bg-muted/30 hover:bg-muted/50 cursor-pointer transition-colors"
                      onClick={() => onSelectTool(tool)}
                    >
                      <div className="flex items-center justify-between">
                        <span className="font-mono text-xs font-medium">{tool.name}</span>
                        <Play className="w-3 h-3 text-muted-foreground" />
                      </div>
                      <p className="text-[10px] text-muted-foreground mt-1 line-clamp-2">
                        {tool.description}
                      </p>
                    </div>
                  ))}
                </div>
              </CollapsibleContent>
            </Collapsible>
          )}
        </CardContent>

        {/* Quick Actions */}
        <CardFooter className="pt-0 gap-2">
          <Button
            size="sm"
            variant={isConnected ? 'outline' : 'default'}
            className="flex-1 h-8 text-xs"
            onClick={isConnected ? onDisconnect : onConnect}
            disabled={isConnecting}
          >
            {isConnecting ? (
              <><Loader2 className="w-3 h-3 mr-2 animate-spin" /> Connecting</>
            ) : isConnected ? (
              <><WifiOff className="w-3 h-3 mr-2" /> Disconnect</>
            ) : (
              <><Wifi className="w-3 h-3 mr-2" /> Connect</>
            )}
          </Button>
          {isConnected && (
            <Button
              size="sm"
              variant="outline"
              className="h-8 text-xs"
              onClick={onToggleExpand}
            >
              <Wrench className="w-3 h-3 mr-2" />
              Tools
            </Button>
          )}
        </CardFooter>
      </Card>
    </motion.div>
  )
}

// ============================================================================
// TOOL EXECUTION DIALOG
// ============================================================================

function ToolExecutionDialog({
  tool,
  server,
  isOpen,
  onClose,
  onExecute
}: {
  tool: MCPTool | null
  server: MCPServerInfo | null
  isOpen: boolean
  onClose: () => void
  onExecute: (args: Record<string, unknown>) => void
}) {
  const [args, setArgs] = useState<Record<string, string>>({})
  const [isExecuting, setIsExecuting] = useState(false)
  const [result, setResult] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Reset state when dialog opens
  useEffect(() => {
    if (isOpen) {
      setArgs({})
      setResult(null)
      setError(null)
    }
  }, [isOpen, tool])

  const handleExecute = async () => {
    if (!tool || !server) return

    setIsExecuting(true)
    setResult(null)
    setError(null)

    try {
      // Convert string args to proper types based on schema
      const typedArgs: Record<string, unknown> = {}
      const props = tool.inputSchema.properties || {}
      
      for (const [key, value] of Object.entries(args)) {
        const propSchema = props[key] as { type?: string } | undefined
        if (propSchema?.type === 'number') {
          typedArgs[key] = parseFloat(value) || 0
        } else if (propSchema?.type === 'boolean') {
          typedArgs[key] = value === 'true'
        } else if (propSchema?.type === 'object' || propSchema?.type === 'array') {
          try {
            typedArgs[key] = JSON.parse(value)
          } catch {
            typedArgs[key] = value
          }
        } else {
          typedArgs[key] = value
        }
      }

      const execution = await mcpService.executeTool(server.id, tool.name, typedArgs)
      
      if (execution.status === 'error') {
        setError(execution.result?.content[0]?.text || 'Execution failed')
      } else {
        setResult(execution.result?.content.map((c: { text?: string }) => c.text || '').join('\n') || 'No output')
      }
      
      onExecute(typedArgs)
    } catch (err) {
      setError(String(err))
    } finally {
      setIsExecuting(false)
    }
  }

  if (!tool) return null

  const properties = tool.inputSchema.properties || {}
  const required = tool.inputSchema.required || []

  return (
    <Dialog open={isOpen} onOpenChange={onClose}>
      <DialogContent className="max-w-2xl max-h-[85vh] overflow-hidden flex flex-col">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Wrench className="w-5 h-5 text-primary" />
            {tool.name}
          </DialogTitle>
          <DialogDescription>
            {tool.description}
          </DialogDescription>
        </DialogHeader>

        <div className="flex-1 overflow-y-auto space-y-4 py-4">
          {/* Parameters */}
          {Object.keys(properties).length > 0 && (
            <div className="space-y-3">
              <Label className="text-sm font-medium">Parameters</Label>
              {Object.entries(properties).map(([key, schema]: [string, any]) => (
                <div key={key} className="space-y-1.5">
                  <Label className="text-xs flex items-center gap-2">
                    {key}
                    {required.includes(key) && (
                      <Badge variant="destructive" className="text-[9px] h-4">Required</Badge>
                    )}
                    <Badge variant="outline" className="text-[9px] h-4 font-mono">
                      {schema.type}
                    </Badge>
                  </Label>
                  {schema.type === 'object' || schema.type === 'array' ? (
                    <Textarea
                      placeholder={schema.description || `Enter ${key} as JSON...`}
                      value={args[key] || ''}
                      onChange={(e) => setArgs(prev => ({ ...prev, [key]: e.target.value }))}
                      className="font-mono text-xs min-h-[80px]"
                    />
                  ) : schema.enum ? (
                    <Select
                      value={args[key] || ''}
                      onValueChange={(v) => setArgs(prev => ({ ...prev, [key]: v }))}
                    >
                      <SelectTrigger className="h-9">
                        <SelectValue placeholder={`Select ${key}...`} />
                      </SelectTrigger>
                      <SelectContent>
                        {schema.enum.map((opt: string) => (
                          <SelectItem key={opt} value={opt}>{opt}</SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  ) : (
                    <Input
                      type={schema.type === 'number' ? 'number' : 'text'}
                      placeholder={schema.description || `Enter ${key}...`}
                      value={args[key] || ''}
                      onChange={(e) => setArgs(prev => ({ ...prev, [key]: e.target.value }))}
                      className="h-9"
                    />
                  )}
                  {schema.description && (
                    <p className="text-[10px] text-muted-foreground">{schema.description}</p>
                  )}
                </div>
              ))}
            </div>
          )}

          {/* Result */}
          {(result || error) && (
            <div className="space-y-2">
              <Label className="text-sm font-medium flex items-center gap-2">
                {error ? (
                  <><XCircle className="w-4 h-4 text-red-500" /> Error</>
                ) : (
                  <><CheckCircle2 className="w-4 h-4 text-green-500" /> Result</>
                )}
              </Label>
              <div className={`p-3 rounded-lg font-mono text-xs whitespace-pre-wrap max-h-[200px] overflow-y-auto ${
                error ? 'bg-red-500/10 text-red-500' : 'bg-muted'
              }`}>
                {error || result}
              </div>
            </div>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Close</Button>
          <Button onClick={handleExecute} disabled={isExecuting}>
            {isExecuting ? (
              <><Loader2 className="w-4 h-4 mr-2 animate-spin" /> Executing...</>
            ) : (
              <><Play className="w-4 h-4 mr-2" /> Execute</>
            )}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ============================================================================
// ADD SERVER DIALOG
// ============================================================================

function AddServerDialog({
  isOpen,
  onClose,
  onAdd
}: {
  isOpen: boolean
  onClose: () => void
  onAdd: (server: MCPServerRegistration) => void
}) {
  const [name, setName] = useState('')
  const [url, setUrl] = useState('')
  const [type, setType] = useState<MCPServerInfo['type']>('custom')

  const handleSubmit = () => {
    if (!name || !url) return
    onAdd({ name, url, type, autoConnect: true })
    setName('')
    setUrl('')
    setType('custom')
    onClose()
  }

  return (
    <Dialog open={isOpen} onOpenChange={onClose}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <Plus className="w-5 h-5" />
            Add MCP Server
          </DialogTitle>
          <DialogDescription>
            Register a new MCP server to connect to
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-4">
          <div className="space-y-2">
            <Label>Server Name</Label>
            <Input
              placeholder="My MCP Server"
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label>Server URL</Label>
            <Input
              placeholder="http://localhost:3000"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
            />
          </div>
          <div className="space-y-2">
            <Label>Server Type</Label>
            <Select value={type} onValueChange={(v) => setType(v as MCPServerInfo['type'])}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="aitherzero">AitherZero</SelectItem>
                <SelectItem value="aithernode">AitherNode</SelectItem>
                <SelectItem value="filesystem">Filesystem</SelectItem>
                <SelectItem value="github">GitHub</SelectItem>
                <SelectItem value="browser">Browser</SelectItem>
                <SelectItem value="custom">Custom</SelectItem>
              </SelectContent>
            </Select>
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={handleSubmit} disabled={!name || !url}>
            <Plus className="w-4 h-4 mr-2" /> Add Server
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

// ============================================================================
// MAIN COMPONENT
// ============================================================================

export default function MCPServerPanel({ className, compact = false, onToolExecute }: MCPServerPanelProps) {
  const [servers, setServers] = useState<MCPServerInfo[]>([])
  const [isLoading, setIsLoading] = useState(true)
  const [expandedServers, setExpandedServers] = useState<Set<string>>(new Set())
  const [selectedTool, setSelectedTool] = useState<{ tool: MCPTool; server: MCPServerInfo } | null>(null)
  const [isAddDialogOpen, setIsAddDialogOpen] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [executions, setExecutions] = useState<MCPToolExecution[]>([])

  // Load servers
  useEffect(() => {
    // Use mock data for now
    const mockServers = mcpService.getMockServers()
    setServers(mockServers)
    setIsLoading(false)

    // Subscribe to updates
    const unsubscribe = mcpService.subscribe(setServers)
    return unsubscribe
  }, [])

  // Server actions
  const handleConnect = useCallback(async (serverId: string) => {
    const success = await mcpService.connectServer(serverId)
    if (!success) {
      // For demo, update with mock data
      const mockServers = mcpService.getMockServers()
      const mockServer = mockServers.find((s: MCPServerInfo) => s.id === serverId)
      if (mockServer) {
        setServers(prev => prev.map(s => s.id === serverId ? { ...mockServer, status: 'connected' as const } : s))
      }
    }
  }, [])

  const handleDisconnect = useCallback(async (serverId: string) => {
    await mcpService.disconnectServer(serverId)
    setServers(prev => prev.map(s => 
      s.id === serverId ? { ...s, status: 'disconnected' as const } : s
    ))
  }, [])

  const handleRefresh = useCallback(async (serverId: string) => {
    await mcpService.refreshServer(serverId)
  }, [])

  const handleRemove = useCallback(async (serverId: string) => {
    await mcpService.removeServer(serverId)
    setServers(prev => prev.filter(s => s.id !== serverId))
  }, [])

  const handleAddServer = useCallback(async (registration: MCPServerRegistration) => {
    const server = await mcpService.registerServer(registration)
    setServers(prev => [...prev, server])
  }, [])

  const handleToolSelect = useCallback((tool: MCPTool, server: MCPServerInfo) => {
    setSelectedTool({ tool, server })
  }, [])

  const handleToolExecute = useCallback((args: Record<string, unknown>) => {
    if (selectedTool) {
      onToolExecute?.({
        id: `exec-${Date.now()}`,
        serverId: selectedTool.server.id,
        serverName: selectedTool.server.name,
        toolName: selectedTool.tool.name,
        args,
        status: 'success',
        startedAt: new Date().toISOString()
      })
    }
  }, [selectedTool, onToolExecute])

  const toggleExpanded = useCallback((serverId: string) => {
    setExpandedServers(prev => {
      const next = new Set(prev)
      if (next.has(serverId)) {
        next.delete(serverId)
      } else {
        next.add(serverId)
      }
      return next
    })
  }, [])

  const handleRefreshAll = useCallback(async () => {
    setIsLoading(true)
    await mcpService.refreshAllServers()
    setIsLoading(false)
  }, [])

  // Filter servers
  const filteredServers = servers.filter(s =>
    s.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    s.url.toLowerCase().includes(searchQuery.toLowerCase())
  )

  // Stats
  const stats = {
    total: servers.length,
    connected: servers.filter(s => s.status === 'connected').length,
    tools: servers.reduce((acc, s) => acc + s.tools.length, 0)
  }

  if (compact) {
    return (
      <Card className={className}>
        <CardContent className="p-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="p-2 rounded-lg bg-primary/10">
                <PlugZap className="w-5 h-5 text-primary" />
              </div>
              <div>
                <div className="font-semibold text-sm">MCP Servers</div>
                <div className="text-xs text-muted-foreground">
                  {stats.connected}/{stats.total} connected • {stats.tools} tools
                </div>
              </div>
            </div>
            <div className="flex items-center gap-2">
              {servers.slice(0, 3).map(server => (
                <TooltipProvider key={server.id}>
                  <Tooltip>
                    <TooltipTrigger>
                      <div className={`w-2 h-2 rounded-full ${
                        server.status === 'connected' ? 'bg-green-500' :
                        server.status === 'error' ? 'bg-red-500' : 'bg-gray-400'
                      }`} />
                    </TooltipTrigger>
                    <TooltipContent>{server.name}</TooltipContent>
                  </Tooltip>
                </TooltipProvider>
              ))}
            </div>
          </div>
        </CardContent>
      </Card>
    )
  }

  return (
    <div className={className}>
      {/* Header */}
      <div className="flex items-center justify-between mb-6">
        <div>
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <PlugZap className="w-5 h-5 text-primary" />
            MCP Servers
          </h2>
          <p className="text-sm text-muted-foreground mt-0.5">
            Model Context Protocol server connections
          </p>
        </div>

        <div className="flex items-center gap-3">
          {/* Stats */}
          <div className="flex items-center gap-4 px-4 py-2 bg-muted/50 rounded-lg">
            <div className="flex items-center gap-2 text-sm">
              <span className="w-2 h-2 rounded-full bg-green-500" />
              <span className="text-muted-foreground">Connected:</span>
              <span className="font-medium">{stats.connected}</span>
            </div>
            <div className="w-px h-4 bg-border" />
            <div className="flex items-center gap-2 text-sm">
              <Wrench className="w-3 h-3 text-muted-foreground" />
              <span className="text-muted-foreground">Tools:</span>
              <span className="font-medium">{stats.tools}</span>
            </div>
          </div>

          <Button variant="outline" size="sm" onClick={handleRefreshAll} disabled={isLoading}>
            <RefreshCw className={`w-4 h-4 mr-2 ${isLoading ? 'animate-spin' : ''}`} />
            Refresh All
          </Button>
          <Button size="sm" onClick={() => setIsAddDialogOpen(true)}>
            <Plus className="w-4 h-4 mr-2" />
            Add Server
          </Button>
        </div>
      </div>

      {/* Search */}
      <div className="mb-4">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-muted-foreground" />
          <Input
            placeholder="Search servers..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="pl-10"
          />
        </div>
      </div>

      {/* Server Grid */}
      {isLoading ? (
        <div className="flex items-center justify-center py-16">
          <Loader2 className="w-8 h-8 animate-spin text-muted-foreground" />
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          <AnimatePresence>
            {filteredServers.map(server => (
              <ServerCard
                key={server.id}
                server={server}
                isExpanded={expandedServers.has(server.id)}
                onToggleExpand={() => toggleExpanded(server.id)}
                onConnect={() => handleConnect(server.id)}
                onDisconnect={() => handleDisconnect(server.id)}
                onRefresh={() => handleRefresh(server.id)}
                onRemove={() => handleRemove(server.id)}
                onSelectTool={(tool) => handleToolSelect(tool, server)}
              />
            ))}
          </AnimatePresence>
        </div>
      )}

      {/* Tool Execution Dialog */}
      <ToolExecutionDialog
        tool={selectedTool?.tool || null}
        server={selectedTool?.server || null}
        isOpen={!!selectedTool}
        onClose={() => setSelectedTool(null)}
        onExecute={handleToolExecute}
      />

      {/* Add Server Dialog */}
      <AddServerDialog
        isOpen={isAddDialogOpen}
        onClose={() => setIsAddDialogOpen(false)}
        onAdd={handleAddServer}
      />
    </div>
  )
}
