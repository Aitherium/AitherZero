'use client';

import { cn } from '@/lib/utils';
import { ScrollArea } from '@/components/ui/scroll-area';
import { Badge } from '@/components/ui/badge';
import { useEffect, useRef } from 'react';

interface CLILine {
  id: string;
  content: string;
  type?: 'input' | 'output' | 'error' | 'info' | 'success';
  timestamp?: string;
}

interface CLIOutputViewerProps {
  lines: CLILine[];
  title?: string;
  showLineNumbers?: boolean;
  autoScroll?: boolean;
  maxHeight?: string;
  className?: string;
}

const lineTypeStyles: Record<string, string> = {
  input: 'text-cyan',
  output: 'text-foreground',
  error: 'text-destructive',
  info: 'text-muted-foreground',
  success: 'text-success',
};

export function CLIOutputViewer({
  lines,
  title,
  showLineNumbers = true,
  autoScroll = true,
  maxHeight = '400px',
  className,
}: CLIOutputViewerProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (autoScroll && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [lines, autoScroll]);

  return (
    <div
      className={cn(
        'rounded-lg border border-border bg-[oklch(0.12_0.02_250)] overflow-hidden',
        className
      )}
    >
      {title && (
        <div className="flex items-center justify-between px-4 py-2 border-b border-border bg-[oklch(0.15_0.02_250)]">
          <div className="flex items-center gap-2">
            <div className="flex gap-1.5">
              <span className="w-3 h-3 rounded-full bg-destructive/80" />
              <span className="w-3 h-3 rounded-full bg-warning/80" />
              <span className="w-3 h-3 rounded-full bg-success/80" />
            </div>
            <span className="font-mono text-sm text-muted-foreground ml-2">
              {title}
            </span>
          </div>
          <Badge variant="outline" className="font-mono text-xs">
            {lines.length} lines
          </Badge>
        </div>
      )}
      <ScrollArea
        ref={scrollRef}
        className="p-4 font-mono text-sm"
        style={{ maxHeight }}
      >
        {lines.length === 0 ? (
          <div className="text-muted-foreground flex items-center gap-2">
            <span className="animate-terminal-blink">▋</span>
            <span>Waiting for output...</span>
          </div>
        ) : (
          <div className="space-y-0.5">
            {lines.map((line, index) => (
              <div key={line.id} className="flex">
                {showLineNumbers && (
                  <span className="w-10 text-right pr-4 text-muted-foreground/50 select-none shrink-0">
                    {index + 1}
                  </span>
                )}
                <span
                  className={cn(
                    'whitespace-pre-wrap break-all flex-1',
                    lineTypeStyles[line.type || 'output']
                  )}
                >
                  {line.type === 'input' && (
                    <span className="text-primary mr-2">$</span>
                  )}
                  {line.content}
                </span>
              </div>
            ))}
          </div>
        )}
      </ScrollArea>
    </div>
  );
}

export default CLIOutputViewer;
