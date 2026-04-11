# AitherZero CI/CD Control Platform - Development Guidelines

## Project Overview
AitherZero WebDash is a sophisticated CI/CD orchestration and AI agent management platform built with Next.js 14, TypeScript, and Tailwind CSS.

## Tech Stack
- **Framework**: Next.js 14 with App Router
- **Language**: TypeScript
- **Styling**: Tailwind CSS with custom oklch color theme
- **UI Components**: shadcn/ui (Card, Tabs, Dialog, Button, Input, Badge, ScrollArea)
- **Icons**: Phosphor Icons (@phosphor-icons/react)
- **Charts**: Recharts
- **Animations**: Framer Motion
- **Notifications**: Sonner
- **Fonts**: Inter (UI), JetBrains Mono (code/metrics)

## Design System

### Color Palette (oklch)
- Primary: `oklch(0.45 0.15 250)` - Deep technical blue
- Secondary Cyan: `oklch(0.70 0.15 200)` - Lighter cyan-blue
- Agent Purple: `oklch(0.60 0.18 290)` - AI/agent elements
- Accent Orange: `oklch(0.68 0.18 45)` - CTAs and warnings
- Background: `oklch(0.15 0.02 250)` - Dark base
- Card: `oklch(0.20 0.03 250)` - Elevated surfaces
- Success: `oklch(0.65 0.20 150)` - Green indicators

### Typography
- H1: Inter Bold/20px/tight/-0.02em
- H2: Inter Semibold/16px
- H3: Inter Semibold/14px
- Body: Inter Regular/14px/1.5
- Small: Inter Regular/12px/muted
- Code: JetBrains Mono Regular/13px/1.6

### Spacing
- Container: px-6 py-4
- Card gaps: gap-4
- Section spacing: space-y-6
- Button groups: gap-2

## Key Components
- AgentCard - AI agent management with status, metrics, actions
- CLIOutputViewer - Terminal-style command output
- StatusDot - Animated pulse for active states
- LogStream - Real-time log viewer with auto-scroll

## State Management
Use Spark KV pattern for local storage persistence:
```typescript
import { sparkKV } from '@/lib/spark-kv'
```

## Coding Standards
- Use TypeScript strict mode
- Prefer server components where possible
- Use client components for interactivity
- Follow shadcn/ui patterns for component customization
- Use oklch() colors in CSS for consistency
