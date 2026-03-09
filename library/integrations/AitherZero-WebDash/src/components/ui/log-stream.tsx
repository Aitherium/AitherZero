'use client';

import { cn } from '@/lib/utils';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { useEffect, useRef, useState } from 'react';
import { Pause, Play, Trash, ArrowDown } from '@phosphor-icons/react';
import type { LogEntry, LogLevel } from '@/lib/types';

interface LogStreamProps {
  logs: LogEntry[];
  title?: string;
  maxHeight?: string;
  showFilters?: boolean;
  onClear?: () => void;
  className?: string;
}

const levelStyles: Record<LogLevel, { badge: string; text: string }> = {
  debug: {
    badge: 'bg-muted text-muted-foreground',
    text: 'text-muted-foreground',
  },
  info: {
    badge: 'bg-primary/20 text-primary',
    text: 'text-foreground',
  },
  warn: {
    badge: 'bg-warning/20 text-warning',
    text: 'text-warning',
  },
  error: {
    badge: 'bg-destructive/20 text-destructive',
    text: 'text-destructive',
  },
};

export function LogStream({
  logs,
  title = 'Log Stream',
  maxHeight = '400px',
  showFilters = true,
  onClear,
  className,
}: LogStreamProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [isPaused, setIsPaused] = useState(false);
  const [activeFilters, setActiveFilters] = useState<LogLevel[]>([
    'debug',
    'info',
    'warn',
    'error',
  ]);
  const [isAtBottom, setIsAtBottom] = useState(true);

  const filteredLogs = logs.filter((log) => activeFilters.includes(log.level));

  useEffect(() => {
    if (!isPaused && isAtBottom && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [filteredLogs, isPaused, isAtBottom]);

  const handleScroll = (e: React.UIEvent<HTMLDivElement>) => {
    const target = e.target as HTMLDivElement;
    const atBottom =
      Math.abs(target.scrollHeight - target.scrollTop - target.clientHeight) < 10;
    setIsAtBottom(atBottom);
  };

  const toggleFilter = (level: LogLevel) => {
    setActiveFilters((prev) =>
      prev.includes(level)
        ? prev.filter((l) => l !== level)
        : [...prev, level]
    );
  };

  const scrollToBottom = () => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
      setIsAtBottom(true);
    }
  };

  return (
    <div
      className={cn(
        'rounded-lg border border-border bg-card overflow-hidden flex flex-col',
        className
      )}
    >
      <div className="flex items-center justify-between px-4 py-2 border-b border-border bg-muted/30">
        <div className="flex items-center gap-3">
          <span className="font-semibold text-sm">{title}</span>
          <Badge variant="outline" className="font-mono text-xs">
            {filteredLogs.length}
          </Badge>
        </div>
        <div className="flex items-center gap-2">
          {showFilters && (
            <div className="flex gap-1 mr-2">
              {(['debug', 'info', 'warn', 'error'] as LogLevel[]).map((level) => (
                <button
                  key={level}
                  onClick={() => toggleFilter(level)}
                  className={cn(
                    'px-2 py-0.5 rounded text-xs font-mono uppercase transition-opacity',
                    levelStyles[level].badge,
                    !activeFilters.includes(level) && 'opacity-30'
                  )}
                >
                  {level}
                </button>
              ))}
            </div>
          )}
          <Button
            variant="ghost"
            size="icon"
            className="h-7 w-7"
            onClick={() => setIsPaused(!isPaused)}
          >
            {isPaused ? (
              <Play className="h-4 w-4" />
            ) : (
              <Pause className="h-4 w-4" />
            )}
          </Button>
          {onClear && (
            <Button
              variant="ghost"
              size="icon"
              className="h-7 w-7"
              onClick={onClear}
            >
              <Trash className="h-4 w-4" />
            </Button>
          )}
        </div>
      </div>

      <ScrollArea
        ref={scrollRef}
        className="flex-1 p-3 font-mono text-xs"
        style={{ maxHeight }}
        onScroll={handleScroll}
      >
        {filteredLogs.length === 0 ? (
          <div className="text-muted-foreground text-center py-8">
            No logs to display
          </div>
        ) : (
          <div className="space-y-1">
            {filteredLogs.map((log) => (
              <div key={log.id} className="flex gap-2 items-start group">
                <span className="text-muted-foreground/60 shrink-0 w-20">
                  {new Date(log.timestamp).toLocaleTimeString()}
                </span>
                <span
                  className={cn(
                    'uppercase w-12 shrink-0',
                    levelStyles[log.level].text
                  )}
                >
                  [{log.level}]
                </span>
                {log.source && (
                  <span className="text-primary/70 shrink-0">
                    [{log.source}]
                  </span>
                )}
                <span className={cn('flex-1', levelStyles[log.level].text)}>
                  {log.message}
                </span>
              </div>
            ))}
          </div>
        )}
      </ScrollArea>

      {!isAtBottom && (
        <button
          onClick={scrollToBottom}
          className="absolute bottom-4 right-4 p-2 rounded-full bg-primary text-primary-foreground shadow-lg hover:bg-primary/90 transition-colors"
        >
          <ArrowDown className="h-4 w-4" />
        </button>
      )}
    </div>
  );
}

export default LogStream;
