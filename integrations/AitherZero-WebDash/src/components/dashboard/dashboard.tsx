'use client'

import React, { useState, useEffect, useRef } from 'react'
import { useSparkKV } from '@/lib/spark-kv'
import { motion, AnimatePresence } from 'framer-motion'
import { 
  Zap, TrendingDown, TrendingUp,
  Terminal, Server, Activity, GitBranch, 
  Settings,
  HardDrive,
  Command, Code2, PlugZap,
  StickyNote, XCircle, ChevronDown
} from 'lucide-react'

// UI Components
import { Card, CardContent } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Textarea } from '@/components/ui/textarea'

// Dashboard Components
import CommandCenter from '@/components/dashboard/command-center'
import MCPServerPanel from '@/components/dashboard/mcp-server-panel'
import ServicesPanel from '@/components/dashboard/services-panel'
import UtilitySidebar from '@/components/dashboard/utility-sidebar'

// Types & Libs
import { aitherZeroService, SystemInfo } from '@/lib/aitherzero-service'

// ============================================================================
// SUB-COMPONENTS
// ============================================================================

function MetricCard({ title, value, subtitle, icon: Icon, accentColor = "bg-primary", trend }: any) {
  return (
    <Card className="relative overflow-hidden border-l-4" style={{ borderLeftColor: accentColor.replace('bg-', '') }}>
      <div className={`absolute inset-0 ${accentColor} opacity-[0.03]`} />
      <CardContent className="p-6">
        <div className="flex items-center justify-between space-y-0 pb-2">
          <p className="text-sm font-medium text-muted-foreground">{title}</p>
          <div className={`p-2 rounded-full ${accentColor}/10`}>
            <Icon className={`h-4 w-4 ${accentColor.replace('bg-', 'text-')}`} />
          </div>
        </div>
        <div className="flex items-center justify-between pt-4">
          <div>
            <div className="text-2xl font-bold font-mono">{value}</div>
            <p className="text-xs text-muted-foreground mt-1">{subtitle}</p>
          </div>
          {trend && (
            <div className={`flex items-center gap-1 text-xs ${trend === 'up' ? 'text-green-500' : 'text-red-500'}`}>
              {trend === 'up' ? <TrendingUp className="h-3 w-3" /> : <TrendingDown className="h-3 w-3" />}
              <span>{trend === 'up' ? '+12%' : '-5%'}</span>
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  )
}

function TerminalPanel({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const [history, setHistory] = useState<string[]>(['> AitherZero System initialized...', '> Ready for input.'])
  const [input, setInput] = useState('')
  const scrollRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight
    }
  }, [history])

  const handleCommand = (e: React.FormEvent) => {
    e.preventDefault()
    if (!input.trim()) return
    setHistory(prev => [...prev, `> ${input}`, `  Executing command: ${input}...`, '  Done.'])
    setInput('')
  }

  if (!isOpen) return null

  return (
    <motion.div 
      initial={{ y: 300, opacity: 0 }}
      animate={{ y: 0, opacity: 1 }}
      exit={{ y: 300, opacity: 0 }}
      className="fixed bottom-0 left-0 right-0 h-64 bg-black/90 border-t border-border z-50 shadow-2xl backdrop-blur-sm"
    >
      <div className="flex items-center justify-between px-4 py-2 bg-muted/20 border-b border-border/50">
        <div className="flex items-center gap-2 text-xs font-mono text-muted-foreground">
          <Terminal className="w-3 h-3" />
          AitherZero Console (pwsh)
        </div>
        <Button variant="ghost" size="icon-sm" onClick={onClose} className="h-6 w-6">
          <ChevronDown className="w-4 h-4" />
        </Button>
      </div>
      <div className="p-4 h-[calc(100%-40px)] flex flex-col font-mono text-sm">
        <div ref={scrollRef} className="flex-1 overflow-y-auto space-y-1 text-green-400/90 pb-2">
          {history.map((line, i) => (
            <div key={i}>{line}</div>
          ))}
        </div>
        <form onSubmit={handleCommand} className="flex gap-2 items-center border-t border-border/30 pt-2">
          <span className="text-green-500">{'>'}</span>
          <input 
            value={input}
            onChange={e => setInput(e.target.value)}
            className="flex-1 bg-transparent border-none outline-none text-foreground placeholder:text-muted-foreground/50"
            placeholder="Enter command..."
            autoFocus
          />
        </form>
      </div>
    </motion.div>
  )
}

function NotepadPanel({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const [notes, setNotes] = useSparkKV('user-notes', '')

  if (!isOpen) return null

  return (
    <motion.div 
      initial={{ x: 300, opacity: 0 }}
      animate={{ x: 0, opacity: 1 }}
      exit={{ x: 300, opacity: 0 }}
      className="fixed top-20 right-4 w-80 h-[500px] bg-background border border-border z-40 shadow-2xl rounded-lg flex flex-col"
    >
      <div className="flex items-center justify-between px-4 py-3 border-b">
        <div className="flex items-center gap-2 font-medium">
          <StickyNote className="w-4 h-4 text-yellow-500" />
          Scratchpad
        </div>
        <Button variant="ghost" size="icon-sm" onClick={onClose}>
          <XCircle className="w-4 h-4" />
        </Button>
      </div>
      <Textarea 
        value={notes}
        onChange={e => setNotes(e.target.value)}
        className="flex-1 resize-none border-none focus-visible:ring-0 p-4 font-mono text-sm"
        placeholder="Type your notes here..."
      />
    </motion.div>
  )
}

// ============================================================================
// MAIN DASHBOARD COMPONENT
// ============================================================================

export default function Dashboard() {
  const [activeTab, setActiveTab] = useState('command')
  const [isTerminalOpen, setIsTerminalOpen] = useState(false)
  const [isNotepadOpen, setIsNotepadOpen] = useState(false)
  const [isUtilitySidebarOpen, setIsUtilitySidebarOpen] = useState(false)
  
  // System Metrics State
  const [systemInfo, setSystemInfo] = useState<SystemInfo | null>(null)
  const [metricsLoading, setMetricsLoading] = useState(false)

  // Fetch System Metrics
  useEffect(() => {
    const fetchMetrics = async () => {
      setMetricsLoading(true)
      try {
        const info = await aitherZeroService.getSystemInfo()
        setSystemInfo(info)
      } catch (error) {
        console.error('Failed to fetch system metrics:', error)
      } finally {
        setMetricsLoading(false)
      }
    }

    fetchMetrics()
    const interval = setInterval(fetchMetrics, 60000)
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="min-h-screen bg-background flex flex-col">
      {/* Utility Sidebar */}
      <UtilitySidebar 
        isOpen={isUtilitySidebarOpen} 
        onToggle={() => setIsUtilitySidebarOpen(!isUtilitySidebarOpen)} 
      />
      
      <Tabs value={activeTab} onValueChange={setActiveTab} className="flex flex-col flex-1">
      {/* Top Navigation Bar */}
      <header className="border-b bg-card/50 backdrop-blur-sm sticky top-0 z-30">
        <div className="container mx-auto px-4 h-16 flex items-center justify-between max-w-[1800px]">
          <div className="flex items-center gap-4">
            <div className="flex items-center gap-2">
              <div className="p-2 rounded-lg bg-gradient-to-br from-primary to-purple-600">
                <Zap className="w-5 h-5 text-white" />
              </div>
              <div>
                <h1 className="font-bold text-lg leading-none tracking-tight">AitherZero</h1>
                <p className="text-[10px] text-muted-foreground font-mono">COMMAND // CONTROL</p>
              </div>
            </div>
            <div className="h-8 w-px bg-border mx-2" />
              <TabsList className="h-full bg-transparent p-0 gap-6">
                <TabsTrigger value="command" className="h-full rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent px-2">
                  <Command className="w-4 h-4 mr-2" /> Command
                </TabsTrigger>
                <TabsTrigger value="mcp" className="h-full rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent px-2">
                  <PlugZap className="w-4 h-4 mr-2" /> MCP
                </TabsTrigger>
                <TabsTrigger value="services" className="h-full rounded-none border-b-2 border-transparent data-[state=active]:border-primary data-[state=active]:bg-transparent px-2">
                  <Server className="w-4 h-4 mr-2" /> Services
                </TabsTrigger>
              </TabsList>
          </div>

          <div className="flex items-center gap-2">
            <Button variant="ghost" size="icon-sm" onClick={() => setIsTerminalOpen(!isTerminalOpen)} className={isTerminalOpen ? 'bg-accent' : ''}>
              <Terminal className="w-4 h-4" />
            </Button>
            <Button variant="ghost" size="icon-sm" onClick={() => setIsNotepadOpen(!isNotepadOpen)} className={isNotepadOpen ? 'bg-accent' : ''}>
              <StickyNote className="w-4 h-4" />
            </Button>
            <div className="h-4 w-px bg-border mx-1" />
            <Button variant="outline" size="sm" className="gap-2">
              <GitBranch className="w-3 h-3" />
              main
            </Button>
            <Button variant="ghost" size="icon-sm">
              <Settings className="w-4 h-4" />
            </Button>
          </div>
        </div>
      </header>

      {/* Main Content Area */}
      <main className={`flex-1 container mx-auto px-4 py-6 max-w-[1800px] overflow-hidden transition-all duration-300 ${isUtilitySidebarOpen ? 'mr-[320px]' : ''}`}>
        <TabsContent value="command" className="space-y-6 m-0 h-full">
          {/* Metrics Row */}
          <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
            <MetricCard
              title="Scripts Available"
              value="56+"
              subtitle="Automation library"
              icon={Code2}
              accentColor="bg-purple-500"
            />
            <MetricCard
              title="System Memory"
              value={systemInfo?.memory ? `${systemInfo.memory.used} GB` : "Loading..."}
              subtitle={systemInfo?.memory ? `${Math.round((systemInfo.memory.used / systemInfo.memory.total) * 100)}% of ${systemInfo.memory.total} GB` : "Fetching..."}
              icon={Activity}
              accentColor="bg-blue-500"
              trend={systemInfo?.memory && (systemInfo.memory.used / systemInfo.memory.total) > 0.8 ? "up" : undefined}
            />
            <MetricCard
              title="Disk Usage"
              value={systemInfo?.disk ? `${Math.round((systemInfo.disk.used / systemInfo.disk.total) * 100)}%` : "Loading..."}
              subtitle={systemInfo?.disk ? `${systemInfo.disk.free} GB free of ${systemInfo.disk.total} GB` : "Fetching..."}
              icon={HardDrive}
              accentColor="bg-green-500"
            />
            <MetricCard
              title="Platform"
              value={systemInfo?.os || "Loading..."}
              subtitle={systemInfo?.hostname || "Unknown Host"}
              icon={Server}
              accentColor="bg-orange-500"
            />
          </div>

          {/* Command Center */}
          <CommandCenter className="h-[700px]" />
        </TabsContent>

        <TabsContent value="mcp" className="space-y-6 m-0 h-full">
          <MCPServerPanel />
        </TabsContent>

        <TabsContent value="services" className="space-y-6 m-0 h-full">
          <ServicesPanel />
        </TabsContent>
      </main>
      </Tabs>

      {/* Global Tools */}
      <AnimatePresence>
        {isTerminalOpen && <TerminalPanel isOpen={isTerminalOpen} onClose={() => setIsTerminalOpen(false)} />}
        {isNotepadOpen && <NotepadPanel isOpen={isNotepadOpen} onClose={() => setIsNotepadOpen(false)} />}
      </AnimatePresence>
    </div>
  )
}
