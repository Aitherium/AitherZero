'use client';

import { useState, useRef, useEffect, useCallback } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { ScrollArea } from '@/components/ui/scroll-area';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Terminal,
  Play,
  Trash,
  Copy,
  ChevronRight as CaretRight,
  Clock,
  CheckCircle,
  AlertTriangle as Warning,
  Loader2 as Spinner,
  FolderOpen,
  ArrowUp,
  ArrowDown,
} from 'lucide-react';
import { toast } from 'sonner';
import { cn } from '@/lib/utils';
import type { AitherAgent, CLICommand } from '@/lib/types';

interface CLILine {
  id: string;
  type: 'input' | 'output' | 'error' | 'info' | 'success' | 'system';
  content: string;
  timestamp: string;
  command?: string;
  exitCode?: number;
  duration?: number;
}

interface CLIExecutorProps {
  agents: AitherAgent[];
  onExecuteCommand: (command: string, agentId?: string) => Promise<{
    output: string;
    exitCode: number;
    duration: number;
  }>;
}

// Common commands for quick access
const QUICK_COMMANDS = [
  { label: 'List Agents', command: 'aitherzero agent list' },
  { label: 'Agent Status', command: 'aitherzero agent status' },
  { label: 'System Info', command: 'aitherzero system info' },
  { label: 'MCP Servers', command: 'aitherzero mcp list' },
  { label: 'Workflows', command: 'aitherzero workflow list' },
  { label: 'Help', command: 'aitherzero --help' },
];

export function CLIExecutor({ agents, onExecuteCommand }: CLIExecutorProps) {
  const [lines, setLines] = useState<CLILine[]>([
    {
      id: 'welcome',
      type: 'system',
      content: '╔════════════════════════════════════════════════════════════╗',
      timestamp: new Date().toISOString(),
    },
    {
      id: 'welcome-2',
      type: 'system',
      content: '║            AitherZero CLI v1.0.0 - Ready                   ║',
      timestamp: new Date().toISOString(),
    },
    {
      id: 'welcome-3',
      type: 'system',
      content: '╚════════════════════════════════════════════════════════════╝',
      timestamp: new Date().toISOString(),
    },
    {
      id: 'welcome-4',
      type: 'info',
      content: 'Type "help" for available commands or select a quick command below.',
      timestamp: new Date().toISOString(),
    },
  ]);
  const [currentInput, setCurrentInput] = useState('');
  const [isExecuting, setIsExecuting] = useState(false);
  const [commandHistory, setCommandHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState(-1);
  const [selectedAgentId, setSelectedAgentId] = useState<string | null>(null);
  const [currentDir, setCurrentDir] = useState('~');

  const inputRef = useRef<HTMLInputElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);

  const selectedAgent = agents.find((a) => a.id === selectedAgentId);
  const runningAgents = agents.filter((a) => a.status === 'running');

  // Auto-scroll to bottom
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [lines]);

  // Focus input on mount
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const addLine = useCallback((line: Omit<CLILine, 'id' | 'timestamp'>) => {
    setLines((prev) => [
      ...prev,
      {
        ...line,
        id: `line-${Date.now()}-${Math.random().toString(36).substring(7)}`,
        timestamp: new Date().toISOString(),
      },
    ]);
  }, []);

  const handleExecute = useCallback(async (command: string) => {
    if (!command.trim()) return;

    // Add to history
    setCommandHistory((prev) => [...prev.filter((c) => c !== command), command].slice(-50));
    setHistoryIndex(-1);

    // Show input line
    addLine({
      type: 'input',
      content: command,
      command,
    });

    // Handle built-in commands
    if (command === 'clear' || command === 'cls') {
      setLines([]);
      setCurrentInput('');
      return;
    }

    if (command === 'help') {
      addLine({
        type: 'info',
        content: `
Available Commands:
  aitherzero agent list      - List all agents
  aitherzero agent status    - Show agent status
  aitherzero agent start <id> - Start an agent
  aitherzero agent stop <id>  - Stop an agent
  aitherzero mcp list        - List MCP servers
  aitherzero mcp tools       - List available MCP tools
  aitherzero workflow list   - List workflows
  aitherzero system info     - Show system information
  clear                      - Clear terminal
  help                       - Show this help

Use arrow up/down to navigate command history.
        `.trim(),
      });
      setCurrentInput('');
      return;
    }

    setIsExecuting(true);
    const startTime = Date.now();

    try {
      const result = await onExecuteCommand(command, selectedAgentId || undefined);
      
      // Split output into lines - ensure output is a string
      const output = typeof result.output === 'string' ? result.output : JSON.stringify(result.output, null, 2);
      const outputLines = output.split('\n');
      outputLines.forEach((line) => {
        addLine({
          type: result.exitCode === 0 ? 'output' : 'error',
          content: line,
          exitCode: result.exitCode,
          duration: result.duration,
        });
      });

      if (result.exitCode === 0) {
        addLine({
          type: 'success',
          content: `✓ Command completed in ${result.duration}ms`,
          exitCode: result.exitCode,
          duration: result.duration,
        });
      } else {
        addLine({
          type: 'error',
          content: `✗ Command failed with exit code ${result.exitCode}`,
          exitCode: result.exitCode,
          duration: result.duration,
        });
      }
    } catch (error) {
      addLine({
        type: 'error',
        content: `Error: ${error instanceof Error ? error.message : 'Unknown error'}`,
      });
    } finally {
      setIsExecuting(false);
      setCurrentInput('');
    }
  }, [addLine, onExecuteCommand, selectedAgentId]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter' && !isExecuting) {
      handleExecute(currentInput);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (commandHistory.length > 0) {
        const newIndex = historyIndex < commandHistory.length - 1 ? historyIndex + 1 : historyIndex;
        setHistoryIndex(newIndex);
        setCurrentInput(commandHistory[commandHistory.length - 1 - newIndex] || '');
      }
    } else if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (historyIndex > 0) {
        const newIndex = historyIndex - 1;
        setHistoryIndex(newIndex);
        setCurrentInput(commandHistory[commandHistory.length - 1 - newIndex] || '');
      } else if (historyIndex === 0) {
        setHistoryIndex(-1);
        setCurrentInput('');
      }
    } else if (e.key === 'Tab') {
      e.preventDefault();
      // Simple tab completion for common commands
      const completions = QUICK_COMMANDS.map((c) => c.command).filter((c) =>
        c.startsWith(currentInput)
      );
      if (completions.length === 1) {
        setCurrentInput(completions[0]);
      }
    } else if (e.key === 'l' && e.ctrlKey) {
      e.preventDefault();
      setLines([]);
    }
  };

  const handleClear = () => {
    setLines([]);
    toast.success('Terminal cleared');
  };

  const handleCopy = () => {
    const text = lines
      .map((line) => {
        if (line.type === 'input') return `$ ${line.content}`;
        return line.content;
      })
      .join('\n');
    navigator.clipboard.writeText(text);
    toast.success('Copied to clipboard');
  };

  const getLineColor = (type: CLILine['type']) => {
    switch (type) {
      case 'input':
        return 'text-cyan-400';
      case 'output':
        return 'text-foreground';
      case 'error':
        return 'text-red-500';
      case 'info':
        return 'text-muted-foreground';
      case 'success':
        return 'text-green-500';
      case 'system':
        return 'text-purple-400';
      default:
        return 'text-foreground';
    }
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-bold flex items-center gap-2">
            <Terminal className="h-5 w-5 text-primary" weight="duotone" />
            CLI Executor
          </h2>
          <p className="text-sm text-muted-foreground">
            Execute AitherZero commands and scripts
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Select
            value={selectedAgentId || 'none'}
            onValueChange={(v) => setSelectedAgentId(v === 'none' ? null : v)}
          >
            <SelectTrigger className="w-[200px]">
              <SelectValue placeholder="Target agent (optional)" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">No specific agent</SelectItem>
              {runningAgents.map((agent) => (
                <SelectItem key={agent.id} value={agent.id}>
                  {agent.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {/* Quick Commands */}
      <div className="flex flex-wrap gap-2">
        {QUICK_COMMANDS.map((cmd) => (
          <Button
            key={cmd.command}
            variant="outline"
            size="sm"
            onClick={() => handleExecute(cmd.command)}
            disabled={isExecuting}
            className="text-xs"
          >
            <CaretRight className="h-3 w-3 mr-1" />
            {cmd.label}
          </Button>
        ))}
      </div>

      {/* Terminal */}
      <Card className="bg-black/90 border-border">
        {/* Terminal Header */}
        <div className="flex items-center justify-between px-4 py-2 border-b border-border bg-muted/20">
          <div className="flex items-center gap-2">
            <div className="flex gap-1.5">
              <span className="w-3 h-3 rounded-full bg-red-500/80" />
              <span className="w-3 h-3 rounded-full bg-yellow-500/80" />
              <span className="w-3 h-3 rounded-full bg-green-500/80" />
            </div>
            <span className="font-mono text-sm text-muted-foreground ml-2">
              aitherzero-cli
              {selectedAgent && (
                <span className="ml-2 text-primary">
                  @ {selectedAgent.name}
                </span>
              )}
            </span>
          </div>
          <div className="flex items-center gap-2">
            <Badge variant="outline" className="font-mono text-xs">
              {lines.length} lines
            </Badge>
            <Button variant="ghost" size="sm" onClick={handleCopy}>
              <Copy className="h-4 w-4" />
            </Button>
            <Button variant="ghost" size="sm" onClick={handleClear}>
              <Trash className="h-4 w-4" />
            </Button>
          </div>
        </div>

        {/* Terminal Content */}
        <ScrollArea
          ref={scrollRef}
          className="p-4 font-mono text-sm"
          style={{ height: '400px' }}
        >
          <div className="space-y-1">
            {lines.map((line) => (
              <div key={line.id} className="flex">
                <span
                  className={cn(
                    'whitespace-pre-wrap break-all flex-1',
                    getLineColor(line.type)
                  )}
                >
                  {line.type === 'input' && (
                    <span className="text-green-500 mr-2">
                      {currentDir} $
                    </span>
                  )}
                  {line.content}
                </span>
              </div>
            ))}

            {/* Current Input Line */}
            <div className="flex items-center">
              <span className="text-green-500 mr-2">{currentDir} $</span>
              <Input
                ref={inputRef}
                value={currentInput}
                onChange={(e) => setCurrentInput(e.target.value)}
                onKeyDown={handleKeyDown}
                className="flex-1 bg-transparent border-none shadow-none focus-visible:ring-0 p-0 h-auto font-mono text-sm text-foreground"
                placeholder={isExecuting ? 'Executing...' : ''}
                disabled={isExecuting}
                autoFocus
              />
              {isExecuting && (
                <Spinner className="h-4 w-4 animate-spin text-muted-foreground" />
              )}
            </div>
          </div>
        </ScrollArea>

        {/* Status Bar */}
        <div className="flex items-center justify-between px-4 py-2 border-t border-border bg-muted/20 text-xs text-muted-foreground">
          <div className="flex items-center gap-4">
            <span className="flex items-center gap-1">
              <FolderOpen className="h-3 w-3" />
              {currentDir}
            </span>
            {commandHistory.length > 0 && (
              <span className="flex items-center gap-1">
                <Clock className="h-3 w-3" />
                {commandHistory.length} in history
              </span>
            )}
          </div>
          <div className="flex items-center gap-2">
            <span>
              <ArrowUp className="h-3 w-3 inline" />
              <ArrowDown className="h-3 w-3 inline" /> History
            </span>
            <span>Tab: Complete</span>
            <span>Ctrl+L: Clear</span>
          </div>
        </div>
      </Card>

      {/* Command History */}
      {commandHistory.length > 0 && (
        <Card>
          <CardHeader className="pb-2">
            <CardTitle className="text-sm flex items-center gap-2">
              <Clock className="h-4 w-4" />
              Recent Commands
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="flex flex-wrap gap-2">
              {commandHistory.slice(-10).reverse().map((cmd, i) => (
                <Badge
                  key={i}
                  variant="secondary"
                  className="cursor-pointer font-mono text-xs hover:bg-muted"
                  onClick={() => {
                    setCurrentInput(cmd);
                    inputRef.current?.focus();
                  }}
                >
                  {cmd}
                </Badge>
              ))}
            </div>
          </CardContent>
        </Card>
      )}
    </div>
  );
}

export default CLIExecutor;
