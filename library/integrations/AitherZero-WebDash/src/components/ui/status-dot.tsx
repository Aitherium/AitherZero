'use client';

import { cn } from '@/lib/utils';

type StatusType = 'success' | 'warning' | 'error' | 'info' | 'idle' | 'running';

interface StatusDotProps {
  status: StatusType;
  pulse?: boolean;
  size?: 'sm' | 'md' | 'lg';
  className?: string;
}

const statusColors: Record<StatusType, string> = {
  success: 'bg-success',
  warning: 'bg-warning',
  error: 'bg-destructive',
  info: 'bg-primary',
  idle: 'bg-muted-foreground',
  running: 'bg-cyan',
};

const sizeClasses: Record<'sm' | 'md' | 'lg', string> = {
  sm: 'w-2 h-2',
  md: 'w-2.5 h-2.5',
  lg: 'w-3 h-3',
};

export function StatusDot({ 
  status, 
  pulse = false, 
  size = 'md',
  className 
}: StatusDotProps) {
  const shouldPulse = pulse || status === 'running';
  
  return (
    <span className={cn('relative flex', className)}>
      <span
        className={cn(
          'rounded-full',
          sizeClasses[size],
          statusColors[status],
          shouldPulse && 'animate-pulse-glow'
        )}
      />
      {shouldPulse && (
        <span
          className={cn(
            'absolute inset-0 rounded-full opacity-75',
            statusColors[status],
            'animate-ping'
          )}
          style={{ animationDuration: '1.5s' }}
        />
      )}
    </span>
  );
}

export default StatusDot;
