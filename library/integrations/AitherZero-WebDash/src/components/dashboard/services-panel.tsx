'use client'

import React, { useState, useEffect, useCallback } from 'react'
import { toast } from 'sonner'
import { motion, AnimatePresence } from 'framer-motion'
import { 
  Server, Play, Square, RefreshCw, Activity, Loader2, 
  CheckCircle2, XCircle, Clock, Globe, Zap, Image as ImageIcon,
  ExternalLink, Terminal, Settings, MoreVertical, Wifi, WifiOff,
  MonitorPlay, Cloud, HardDrive, Cpu, MemoryStick
} from 'lucide-react'

import { Card, CardContent, CardDescription, CardHeader, CardTitle, CardFooter } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Progress } from '@/components/ui/progress'
import { StatusDot } from '@/components/ui/status-dot'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'

import { mcpService } from '@/lib/mcp-service'

// ============================================================================
// TYPES
// ============================================================================

interface ServiceInfo {
  id: string
  name: string
  description: string
  type: 'local' | 'gateway' | 'agent' | 'node'
  status: 'running' | 'stopped' | 'starting' | 'stopping' | 'error' | 'unknown'
  url?: string
  port?: number
  gatewayUrl?: string
  icon: React.ComponentType<{ className?: string }>
  startScript?: string
  stopScript?: string
  checkEndpoint?: string
  lastChecked?: string
  uptime?: string
  metrics?: {
    cpu?: number
    memory?: number
    memoryMB?: number
    vram?: number
  }
}

const defaultServices: ServiceInfo[] = [
  {
    id: 'comfyui',
    name: 'ComfyUI',
    description: 'Local Stable Diffusion image generation server',
    type: 'local',
    status: 'unknown',
    port: 8188,
    url: 'http://127.0.0.1:8188',
    icon: ImageIcon,
    startScript: '0734',
    checkEndpoint: 'http://127.0.0.1:8188/system/stats',
  },
  {
    id: 'comfyui-gateway',
    name: 'ComfyUI Gateway',
    description: 'ComfyUI with Cloudflare Tunnel for remote access',
    type: 'gateway',
    status: 'unknown',
    port: 8188,
    icon: Globe,
    startScript: '0732',
  },
  {
    id: 'aithernode',
    name: 'AitherNode',
    description: 'AI media server for animations and processing',
    type: 'node',
    status: 'unknown',
    port: 8080,
    url: 'http://127.0.0.1:8080',
    icon: MonitorPlay,
    checkEndpoint: 'http://127.0.0.1:8080/health',
  },
  {
    id: 'ollama',
    name: 'Ollama',
    description: 'Local LLM inference server',
    type: 'local',
    status: 'unknown',
    port: 11434,
    url: 'http://127.0.0.1:11434',
    icon: Cpu,
    checkEndpoint: 'http://127.0.0.1:11434/api/tags',
  },
]

// ============================================================================
// SERVICE CARD COMPONENT
// ============================================================================

function ServiceCard({ 
  service, 
  onStart, 
  onStop, 
  onRefresh,
  onOpenUI,
  isLoading 
}: { 
  service: ServiceInfo
  onStart: () => void
  onStop: () => void
  onRefresh: () => void
  onOpenUI: () => void
  isLoading: boolean
}) {
  const Icon = service.icon
  
  const statusColors: Record<ServiceInfo['status'], string> = {
    running: 'text-green-500',
    stopped: 'text-muted-foreground',
    starting: 'text-yellow-500',
    stopping: 'text-orange-500',
    error: 'text-red-500',
    unknown: 'text-muted-foreground/50',
  }

  const statusBadgeVariant: Record<ServiceInfo['status'], 'default' | 'secondary' | 'destructive' | 'outline'> = {
    running: 'default',
    stopped: 'secondary',
    starting: 'outline',
    stopping: 'outline',
    error: 'destructive',
    unknown: 'secondary',
  }

  return (
    <Card className="relative overflow-hidden group">
      <div className={`absolute inset-y-0 left-0 w-1 ${service.status === 'running' ? 'bg-green-500' : service.status === 'error' ? 'bg-red-500' : 'bg-muted'}`} />
      
      <CardHeader className="pb-2">
        <div className="flex items-start justify-between">
          <div className="flex items-center gap-3">
            <div className={`p-2 rounded-lg ${service.status === 'running' ? 'bg-green-500/10' : 'bg-muted'}`}>
              <Icon className={`h-5 w-5 ${statusColors[service.status]}`} />
            </div>
            <div>
              <CardTitle className="text-base flex items-center gap-2">
                {service.name}
                <Badge variant={statusBadgeVariant[service.status]} className="text-[10px] h-5">
                  {service.status}
                </Badge>
              </CardTitle>
              <CardDescription className="text-xs mt-0.5">
                {service.description}
              </CardDescription>
            </div>
          </div>
          
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="icon-sm" className="h-7 w-7 opacity-0 group-hover:opacity-100 transition-opacity">
                <MoreVertical className="h-4 w-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={onRefresh}>
                <RefreshCw className="h-4 w-4 mr-2" />
                Refresh Status
              </DropdownMenuItem>
              {service.url && (
                <DropdownMenuItem onClick={onOpenUI}>
                  <ExternalLink className="h-4 w-4 mr-2" />
                  Open UI
                </DropdownMenuItem>
              )}
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => toast.info('View logs coming soon')}>
                <Terminal className="h-4 w-4 mr-2" />
                View Logs
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => toast.info('Settings coming soon')}>
                <Settings className="h-4 w-4 mr-2" />
                Settings
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </CardHeader>

      <CardContent className="pb-3">
        <div className="space-y-3">
          {/* Connection Info */}
          <div className="flex items-center gap-4 text-xs text-muted-foreground">
            {service.port && (
              <div className="flex items-center gap-1">
                <Server className="h-3 w-3" />
                Port {service.port}
              </div>
            )}
            {service.lastChecked && (
              <div className="flex items-center gap-1">
                <Clock className="h-3 w-3" />
                {new Date(service.lastChecked).toLocaleTimeString()}
              </div>
            )}
          </div>

          {/* Gateway URL if available */}
          {service.gatewayUrl && (
            <div className="text-xs bg-muted/50 rounded p-2 font-mono truncate">
              <Globe className="h-3 w-3 inline mr-1" />
              {service.gatewayUrl}
            </div>
          )}

          {/* Metrics if running */}
          {service.status === 'running' && service.metrics && (
            <div className="grid grid-cols-3 gap-2">
              {service.metrics.cpu !== undefined && (
                <div className="text-xs">
                  <div className="text-muted-foreground mb-1">CPU</div>
                  <Progress value={service.metrics.cpu} className="h-1" />
                  <div className="text-[10px] mt-0.5">{service.metrics.cpu}%</div>
                </div>
              )}
              {(service.metrics.memory !== undefined || service.metrics.memoryMB !== undefined) && (
                <div className="text-xs">
                  <div className="text-muted-foreground mb-1">RAM</div>
                  {service.metrics.memory !== undefined ? (
                    <>
                      <Progress value={service.metrics.memory} className="h-1" />
                      <div className="text-[10px] mt-0.5">{service.metrics.memory}%</div>
                    </>
                  ) : (
                    <div className="text-[10px] font-mono mt-1">
                      {service.metrics.memoryMB ? (service.metrics.memoryMB > 1024 ? `${(service.metrics.memoryMB / 1024).toFixed(1)} GB` : `${service.metrics.memoryMB} MB`) : 'N/A'}
                    </div>
                  )}
                </div>
              )}
              {service.metrics.vram !== undefined && (
                <div className="text-xs">
                  <div className="text-muted-foreground mb-1">VRAM</div>
                  <Progress value={service.metrics.vram} className="h-1" />
                  <div className="text-[10px] mt-0.5">{service.metrics.vram}%</div>
                </div>
              )}
            </div>
          )}
        </div>
      </CardContent>

      <CardFooter className="pt-0">
        <div className="flex gap-2 w-full">
          {service.status === 'running' ? (
            <>
              <Button 
                variant="outline" 
                size="sm" 
                className="flex-1"
                onClick={onStop}
                disabled={isLoading}
              >
                {isLoading ? (
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                ) : (
                  <Square className="h-4 w-4 mr-2" />
                )}
                Stop
              </Button>
              {service.url && (
                <Button 
                  variant="default" 
                  size="sm"
                  onClick={onOpenUI}
                >
                  <ExternalLink className="h-4 w-4" />
                </Button>
              )}
            </>
          ) : (
            <Button 
              variant="default" 
              size="sm" 
              className="flex-1"
              onClick={onStart}
              disabled={isLoading || service.status === 'starting'}
            >
              {isLoading || service.status === 'starting' ? (
                <Loader2 className="h-4 w-4 mr-2 animate-spin" />
              ) : (
                <Play className="h-4 w-4 mr-2" />
              )}
              {service.status === 'starting' ? 'Starting...' : 'Start'}
            </Button>
          )}
        </div>
      </CardFooter>
    </Card>
  )
}

// ============================================================================
// MAIN SERVICES PANEL
// ============================================================================

export default function ServicesPanel({ className = '' }: { className?: string }) {
  const [services, setServices] = useState<ServiceInfo[]>(defaultServices)
  const [loadingServices, setLoadingServices] = useState<Set<string>>(new Set())
  const [mcpConnected, setMcpConnected] = useState(false)
  const [confirmDialog, setConfirmDialog] = useState<{ open: boolean; service: ServiceInfo | null; action: 'start' | 'stop' }>({
    open: false,
    service: null,
    action: 'start'
  })

  // Check MCP connection status
  useEffect(() => {
    const checkMcpStatus = async () => {
      try {
        const info = await mcpService.checkStatus()
        setMcpConnected(info.running && info.ready)
      } catch {
        setMcpConnected(false)
      }
    }
    checkMcpStatus()

    // Subscribe to MCP status changes
    const unsubscribe = mcpService.subscribe(() => {
      const status = mcpService.getStatus()
      setMcpConnected(status === 'connected')
    })

    return unsubscribe
  }, [])

  // Refresh all service statuses using direct API
  const refreshAllStatuses = useCallback(async () => {
    try {
      // Use direct API endpoint instead of MCP for reliability
      const response = await fetch('/api/services')
      const data = await response.json()
      
      if (!data.success || !data.services) {
        console.error('Failed to fetch service statuses:', data.error)
        return
      }
      
      const statuses = data.services
      
      setServices(prevServices => prevServices.map(service => {
        // Map backend service names to frontend IDs
        let backendName = ''
        switch (service.id) {
          case 'comfyui': backendName = 'ComfyUI'; break;
          case 'ollama': backendName = 'Ollama'; break;
          case 'aithernode': backendName = 'AitherNode'; break;
          case 'comfyui-gateway': backendName = 'Cloudflared'; break;
        }

        const statusData = statuses.find((s: { Name: string }) => s.Name === backendName)
        
        if (statusData) {
          return {
            ...service,
            status: statusData.Status.toLowerCase() as 'running' | 'stopped',
            lastChecked: new Date().toISOString(),
            metrics: statusData.Status === 'Running' ? {
              ...service.metrics,
              memoryMB: statusData.MemoryMB
            } : undefined
          }
        }
        return service
      }))
    } catch (error) {
      console.error('Failed to fetch service statuses:', error)
    }
  }, [])

  // Initial status check
  useEffect(() => {
    refreshAllStatuses()
    // Check every 30 seconds
    const interval = setInterval(refreshAllStatuses, 30000)
    return () => clearInterval(interval)
  }, []) // Only run once on mount

  // Start a service using direct API
  const startService = async (service: ServiceInfo) => {
    setLoadingServices(prev => new Set(prev).add(service.id))
    
    // Update status to starting
    setServices(prev => prev.map(s => 
      s.id === service.id ? { ...s, status: 'starting' as const } : s
    ))

    try {
      const response = await fetch('/api/services', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'start',
          service: service.id,
          port: service.port
        })
      })
      
      const result = await response.json()

      if (result.success) {
        toast.success(`${service.name} started successfully`)
        
        // Wait a moment then check status
        setTimeout(() => {
          refreshAllStatuses()
        }, 3000)

        // Check for gateway URL in the result
        const resultText = result.output || ''
        const gatewayMatch = resultText.match(/https:\/\/[^\s]+\.trycloudflare\.com/)
        if (gatewayMatch) {
          setServices(prev => prev.map(s => 
            s.id === service.id ? { ...s, gatewayUrl: gatewayMatch[0] } : s
          ))
        }
      } else {
        throw new Error(result.error || 'Failed to start service')
      }
    } catch (error) {
      toast.error(`Failed to start ${service.name}: ${error instanceof Error ? error.message : 'Unknown error'}`)
      setServices(prev => prev.map(s => 
        s.id === service.id ? { ...s, status: 'error' as const } : s
      ))
    } finally {
      setLoadingServices(prev => {
        const next = new Set(prev)
        next.delete(service.id)
        return next
      })
    }
  }

  // Stop a service using direct API
  const stopService = async (service: ServiceInfo) => {
    setLoadingServices(prev => new Set(prev).add(service.id))
    
    setServices(prev => prev.map(s => 
      s.id === service.id ? { ...s, status: 'stopping' as const } : s
    ))

    try {
      const response = await fetch('/api/services', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          action: 'stop',
          service: service.id
        })
      })
      
      const result = await response.json()
      
      if (result.success) {
        toast.success(`${service.name} stopped`)
        // Wait a moment then check status
        setTimeout(() => {
          refreshAllStatuses()
        }, 2000)
      } else {
        throw new Error(result.error || 'Failed to stop service')
      }
    } catch (error) {
      toast.error(`Failed to stop ${service.name}: ${error instanceof Error ? error.message : 'Unknown error'}`)
      setServices(prev => prev.map(s => 
        s.id === service.id ? { ...s, status: 'error' as const } : s
      ))
    } finally {
      setLoadingServices(prev => {
        const next = new Set(prev)
        next.delete(service.id)
        return next
      })
    }
  }

  const openServiceUI = (service: ServiceInfo) => {
    const url = service.gatewayUrl || service.url
    if (url) {
      window.open(url, '_blank')
    }
  }

  const handleStartClick = (service: ServiceInfo) => {
    // For gateway services, confirm first
    if (service.type === 'gateway') {
      setConfirmDialog({ open: true, service, action: 'start' })
    } else {
      startService(service)
    }
  }

  const handleStopClick = (service: ServiceInfo) => {
    setConfirmDialog({ open: true, service, action: 'stop' })
  }

  const runningCount = services.filter(s => s.status === 'running').length

  return (
    <div className={`space-y-6 ${className}`}>
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-2xl font-bold tracking-tight flex items-center gap-2">
            <Server className="h-6 w-6" />
            Services
          </h2>
          <p className="text-muted-foreground">
            Manage local AI services and infrastructure
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant={mcpConnected ? 'default' : 'secondary'} className="gap-1">
            {mcpConnected ? <Wifi className="h-3 w-3" /> : <WifiOff className="h-3 w-3" />}
            MCP {mcpConnected ? 'Connected' : 'Disconnected'}
          </Badge>
          <Button variant="outline" size="sm" onClick={refreshAllStatuses}>
            <RefreshCw className="h-4 w-4 mr-2" />
            Refresh All
          </Button>
        </div>
      </div>

      {/* Stats Bar */}
      <div className="grid grid-cols-4 gap-4">
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="p-2 rounded-lg bg-green-500/10">
              <Activity className="h-4 w-4 text-green-500" />
            </div>
            <div>
              <div className="text-2xl font-bold">{runningCount}</div>
              <div className="text-xs text-muted-foreground">Running</div>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="p-2 rounded-lg bg-muted">
              <Square className="h-4 w-4 text-muted-foreground" />
            </div>
            <div>
              <div className="text-2xl font-bold">{services.filter(s => s.status === 'stopped').length}</div>
              <div className="text-xs text-muted-foreground">Stopped</div>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="p-2 rounded-lg bg-blue-500/10">
              <Globe className="h-4 w-4 text-blue-500" />
            </div>
            <div>
              <div className="text-2xl font-bold">{services.filter(s => s.gatewayUrl).length}</div>
              <div className="text-xs text-muted-foreground">Gateways</div>
            </div>
          </div>
        </Card>
        <Card className="p-4">
          <div className="flex items-center gap-3">
            <div className="p-2 rounded-lg bg-purple-500/10">
              <Zap className="h-4 w-4 text-purple-500" />
            </div>
            <div>
              <div className="text-2xl font-bold">{services.length}</div>
              <div className="text-xs text-muted-foreground">Total</div>
            </div>
          </div>
        </Card>
      </div>

      {/* Services Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {services.map(service => (
          <ServiceCard
            key={service.id}
            service={service}
            onStart={() => handleStartClick(service)}
            onStop={() => handleStopClick(service)}
            onRefresh={refreshAllStatuses}
            onOpenUI={() => openServiceUI(service)}
            isLoading={loadingServices.has(service.id)}
          />
        ))}
      </div>

      {/* Confirmation Dialog */}
      <Dialog open={confirmDialog.open} onOpenChange={(open) => setConfirmDialog(prev => ({ ...prev, open }))}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>
              {confirmDialog.action === 'start' ? 'Start' : 'Stop'} {confirmDialog.service?.name}?
            </DialogTitle>
            <DialogDescription>
              {confirmDialog.action === 'start' ? (
                confirmDialog.service?.type === 'gateway' 
                  ? 'This will start ComfyUI and create a public Cloudflare tunnel. The URL will be accessible from the internet.'
                  : `This will start ${confirmDialog.service?.name} on port ${confirmDialog.service?.port}.`
              ) : (
                `This will stop ${confirmDialog.service?.name}. Any running processes will be terminated.`
              )}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmDialog(prev => ({ ...prev, open: false }))}>
              Cancel
            </Button>
            <Button 
              variant={confirmDialog.action === 'stop' ? 'destructive' : 'default'}
              onClick={() => {
                if (confirmDialog.service) {
                  if (confirmDialog.action === 'start') {
                    startService(confirmDialog.service)
                  } else {
                    stopService(confirmDialog.service)
                  }
                }
                setConfirmDialog(prev => ({ ...prev, open: false }))
              }}
            >
              {confirmDialog.action === 'start' ? 'Start' : 'Stop'} Service
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
