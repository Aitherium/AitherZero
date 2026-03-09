'use client';

import { useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
  DialogFooter,
} from '@/components/ui/dialog';
import { Label } from '@/components/ui/label';
import {
  Plugs,
  Play,
  Plus,
  Trash,
  ArrowClockwise,
  CheckCircle,
  Warning,
  Clock,
  Lightning,
  Code,
  Terminal,
  Database,
  Globe,
  CaretDown,
  CaretRight,
} from '@phosphor-icons/react';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';
import type { MCPServer, MCPTool, MCPExecution } from '@/lib/types';

interface MCPToolsPanelProps {
  servers: MCPServer[];
  onAddServer: (server: Omit<MCPServer, 'id' | 'status' | 'tools'>) => void;
  onRemoveServer: (serverId: string) => void;
  onRefreshServer: (serverId: string) => void;
  onExecuteTool: (serverId: string, toolName: string, args: Record<string, unknown>) => Promise<MCPExecution>;
  executions: MCPExecution[];
}

const SERVER_ICONS: Record<string, typeof Lightning> = {
  github: Globe,
  filesystem: Database,
  terminal: Terminal,
  custom: Lightning,
  aither: Lightning,
  aithernode: Lightning,
};

export function MCPToolsPanel({
  servers,
  onAddServer,
  onRemoveServer,
  onRefreshServer,
  onExecuteTool,
  executions,
}: MCPToolsPanelProps) {
  const [activeTab, setActiveTab] = useState('servers');
  const [expandedServer, setExpandedServer] = useState<string | null>(null);
  const [isAddingServer, setIsAddingServer] = useState(false);
  const [newServer, setNewServer] = useState({
    name: '',
    url: '',
    type: 'custom' as const,
  });
  const [executingTool, setExecutingTool] = useState<{ serverId: string; tool: MCPTool } | null>(null);
  const [toolArgs, setToolArgs] = useState<string>('{}');

  const connectedServers = servers.filter((s) => s.status === 'connected');
  const totalTools = servers.reduce((acc, s) => acc + s.tools.length, 0);

  const handleAddServer = () => {
    if (!newServer.name || !newServer.url) {
      toast.error('Please fill in all fields');
      return;
    }
    onAddServer(newServer);
    setNewServer({ name: '', url: '', type: 'custom' });
    setIsAddingServer(false);
    toast.success(`Added MCP server: ${newServer.name}`);
  };

  const handleExecuteTool = async () => {
    if (!executingTool) return;

    try {
      const args = JSON.parse(toolArgs);
      await onExecuteTool(executingTool.serverId, executingTool.tool.name, args);
      toast.success(`Executed: ${executingTool.tool.name}`);
      setExecutingTool(null);
      setToolArgs('{}');
    } catch (error) {
      toast.error(`Error: ${error instanceof Error ? error.message : 'Invalid JSON'}`);
    }
  };

  const getStatusColor = (status: MCPServer['status']) => {
    switch (status) {
      case 'connected':
        return 'text-success';
      case 'disconnected':
        return 'text-muted-foreground';
      case 'error':
        return 'text-destructive';
      default:
        return 'text-muted-foreground';
    }
  };

  const getStatusBadge = (status: MCPServer['status']) => {
    switch (status) {
      case 'connected':
        return <Badge className="bg-success/20 text-success border-success/30">Connected</Badge>;
      case 'disconnected':
        return <Badge variant="secondary">Disconnected</Badge>;
      case 'error':
        return <Badge variant="destructive">Error</Badge>;
      default:
        return <Badge variant="secondary">{status}</Badge>;
    }
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold flex items-center gap-2">
            <Plugs className="h-5 w-5 text-agent-purple" weight="duotone" />
            MCP Tools
          </h2>
          <p className="text-sm text-muted-foreground">
            Model Context Protocol servers and tools
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Badge variant="outline">
            {connectedServers.length} / {servers.length} servers
          </Badge>
          <Badge variant="outline">{totalTools} tools</Badge>
          <Dialog open={isAddingServer} onOpenChange={setIsAddingServer}>
            <DialogTrigger asChild>
              <Button size="sm">
                <Plus className="h-4 w-4 mr-2" />
                Add Server
              </Button>
            </DialogTrigger>
            <DialogContent>
              <DialogHeader>
                <DialogTitle>Add MCP Server</DialogTitle>
              </DialogHeader>
              <div className="space-y-4 py-4">
                <div className="space-y-2">
                  <Label>Server Name</Label>
                  <Input
                    placeholder="e.g., GitHub MCP"
                    value={newServer.name}
                    onChange={(e) => setNewServer({ ...newServer, name: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <Label>Server URL / Command</Label>
                  <Input
                    placeholder="e.g., npx -y @modelcontextprotocol/server-github"
                    value={newServer.url}
                    onChange={(e) => setNewServer({ ...newServer, url: e.target.value })}
                  />
                </div>
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={() => setIsAddingServer(false)}>
                  Cancel
                </Button>
                <Button onClick={handleAddServer}>Add Server</Button>
              </DialogFooter>
            </DialogContent>
          </Dialog>
        </div>
      </div>

      <Tabs value={activeTab} onValueChange={setActiveTab}>
        <TabsList className="grid w-full grid-cols-3">
          <TabsTrigger value="servers">Servers</TabsTrigger>
          <TabsTrigger value="tools">All Tools</TabsTrigger>
          <TabsTrigger value="history">Execution History</TabsTrigger>
        </TabsList>

        {/* Servers Tab */}
        <TabsContent value="servers" className="space-y-4">
          {servers.length === 0 ? (
            <Card className="border-dashed">
              <CardContent className="py-8 text-center">
                <Plugs className="h-12 w-12 mx-auto text-muted-foreground mb-4" />
                <p className="text-muted-foreground mb-4">
                  No MCP servers configured
                </p>
                <Button onClick={() => setIsAddingServer(true)}>
                  <Plus className="h-4 w-4 mr-2" />
                  Add Your First Server
                </Button>
              </CardContent>
            </Card>
          ) : (
            <div className="space-y-3">
              {servers.map((server) => {
                const IconComponent = SERVER_ICONS[server.type] || Lightning;
                const isExpanded = expandedServer === server.id;

                return (
                  <Card key={server.id} className="overflow-hidden">
                    <div
                      className="flex items-center justify-between p-4 cursor-pointer hover:bg-muted/50"
                      onClick={() => setExpandedServer(isExpanded ? null : server.id)}
                    >
                      <div className="flex items-center gap-3">
                        {isExpanded ? (
                          <CaretDown className="h-4 w-4 text-muted-foreground" />
                        ) : (
                          <CaretRight className="h-4 w-4 text-muted-foreground" />
                        )}
                        <div
                          className={cn(
                            'w-10 h-10 rounded-lg flex items-center justify-center',
                            server.status === 'connected'
                              ? 'bg-success/10 text-success'
                              : 'bg-muted text-muted-foreground'
                          )}
                        >
                          <IconComponent className="h-5 w-5" weight="duotone" />
                        </div>
                        <div>
                          <div className="font-semibold flex items-center gap-2">
                            {server.name}
                            {getStatusBadge(server.status)}
                          </div>
                          <p className="text-sm text-muted-foreground font-mono">
                            {server.url}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2">
                        <Badge variant="outline">{server.tools.length} tools</Badge>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={(e) => {
                            e.stopPropagation();
                            onRefreshServer(server.id);
                          }}
                        >
                          <ArrowClockwise className="h-4 w-4" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={(e) => {
                            e.stopPropagation();
                            onRemoveServer(server.id);
                          }}
                        >
                          <Trash className="h-4 w-4 text-destructive" />
                        </Button>
                      </div>
                    </div>

                    {isExpanded && server.tools.length > 0 && (
                      <div className="border-t border-border bg-muted/30">
                        <div className="p-4 grid grid-cols-1 md:grid-cols-2 gap-2">
                          {server.tools.map((tool) => (
                            <div
                              key={tool.name}
                              className="flex items-center justify-between p-3 bg-card rounded-lg border border-border"
                            >
                              <div className="flex-1 min-w-0">
                                <div className="font-medium text-sm font-mono truncate">
                                  {tool.name}
                                </div>
                                <p className="text-xs text-muted-foreground line-clamp-1">
                                  {tool.description}
                                </p>
                              </div>
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() => {
                                  setExecutingTool({ serverId: server.id, tool });
                                  setToolArgs(JSON.stringify(tool.inputSchema?.example || {}, null, 2));
                                }}
                              >
                                <Play className="h-4 w-4" />
                              </Button>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}
                  </Card>
                );
              })}
            </div>
          )}
        </TabsContent>

        {/* All Tools Tab */}
        <TabsContent value="tools">
          <Card>
            <CardContent className="p-4">
              <ScrollArea className="h-[400px]">
                <div className="space-y-2">
                  {servers.flatMap((server) =>
                    server.tools.map((tool) => (
                      <div
                        key={`${server.id}-${tool.name}`}
                        className="flex items-center justify-between p-3 border border-border rounded-lg hover:bg-muted/50"
                      >
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center gap-2">
                            <Code className="h-4 w-4 text-primary" />
                            <span className="font-medium font-mono text-sm">
                              {tool.name}
                            </span>
                            <Badge variant="outline" className="text-xs">
                              {server.name}
                            </Badge>
                          </div>
                          <p className="text-xs text-muted-foreground mt-1 line-clamp-2">
                            {tool.description}
                          </p>
                        </div>
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => {
                            setExecutingTool({ serverId: server.id, tool });
                            setToolArgs(JSON.stringify(tool.inputSchema?.example || {}, null, 2));
                          }}
                          disabled={server.status !== 'connected'}
                        >
                          <Play className="h-4 w-4 mr-1" />
                          Run
                        </Button>
                      </div>
                    ))
                  )}
                  {totalTools === 0 && (
                    <div className="text-center py-8 text-muted-foreground">
                      No tools available. Connect to an MCP server to see available tools.
                    </div>
                  )}
                </div>
              </ScrollArea>
            </CardContent>
          </Card>
        </TabsContent>

        {/* Execution History Tab */}
        <TabsContent value="history">
          <Card>
            <CardContent className="p-4">
              <ScrollArea className="h-[400px]">
                <div className="space-y-3">
                  {executions.length === 0 ? (
                    <div className="text-center py-8 text-muted-foreground">
                      No tool executions yet. Run a tool to see history here.
                    </div>
                  ) : (
                    executions.map((exec) => (
                      <div
                        key={exec.id}
                        className={cn(
                          'p-3 border rounded-lg',
                          exec.status === 'success'
                            ? 'border-success/30 bg-success/5'
                            : exec.status === 'error'
                            ? 'border-destructive/30 bg-destructive/5'
                            : 'border-border'
                        )}
                      >
                        <div className="flex items-center justify-between mb-2">
                          <div className="flex items-center gap-2">
                            {exec.status === 'success' && (
                              <CheckCircle className="h-4 w-4 text-success" />
                            )}
                            {exec.status === 'error' && (
                              <Warning className="h-4 w-4 text-destructive" />
                            )}
                            {exec.status === 'running' && (
                              <div className="h-4 w-4 border-2 border-primary border-t-transparent rounded-full animate-spin" />
                            )}
                            <span className="font-medium font-mono text-sm">
                              {exec.toolName}
                            </span>
                          </div>
                          <div className="flex items-center gap-2 text-xs text-muted-foreground">
                            {exec.duration && (
                              <span className="flex items-center gap-1">
                                <Clock className="h-3 w-3" />
                                {exec.duration}ms
                              </span>
                            )}
                            <span>
                              {new Date(exec.timestamp).toLocaleTimeString()}
                            </span>
                          </div>
                        </div>

                        <div className="grid grid-cols-2 gap-2 text-xs">
                          <div>
                            <div className="text-muted-foreground mb-1">Input:</div>
                            <pre className="bg-muted p-2 rounded font-mono overflow-x-auto">
                              {JSON.stringify(exec.args, null, 2)}
                            </pre>
                          </div>
                          {exec.result !== undefined && (
                            <div>
                              <div className="text-muted-foreground mb-1">Output:</div>
                              <pre className="bg-muted p-2 rounded font-mono overflow-x-auto max-h-24">
                                {typeof exec.result === 'string'
                                  ? exec.result
                                  : JSON.stringify(exec.result as object, null, 2)}
                              </pre>
                            </div>
                          )}
                        </div>
                      </div>
                    ))
                  )}
                </div>
              </ScrollArea>
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>

      {/* Execute Tool Dialog */}
      <Dialog open={!!executingTool} onOpenChange={(open) => !open && setExecutingTool(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Play className="h-5 w-5 text-primary" />
              Execute Tool: {executingTool?.tool.name}
            </DialogTitle>
          </DialogHeader>
          <div className="space-y-4 py-4">
            <p className="text-sm text-muted-foreground">
              {executingTool?.tool.description}
            </p>
            <div className="space-y-2">
              <Label>Arguments (JSON)</Label>
              <Textarea
                value={toolArgs}
                onChange={(e) => setToolArgs(e.target.value)}
                className="font-mono text-sm min-h-[150px]"
                placeholder="{}"
              />
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setExecutingTool(null)}>
              Cancel
            </Button>
            <Button onClick={handleExecuteTool}>
              <Play className="h-4 w-4 mr-2" />
              Execute
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default MCPToolsPanel;
