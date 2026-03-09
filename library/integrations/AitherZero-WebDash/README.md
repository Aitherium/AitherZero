# AitherZero WebDash

A sophisticated CI/CD orchestration and AI agent management platform built with Next.js 14, TypeScript, and Tailwind CSS.

## Features

- **AI Agent Management** - Start, stop, restart, and monitor AI agents (Claude, Gemini, custom)
- **Pipeline Orchestration** - Execute multi-stage CI/CD pipelines with visual status tracking
- **Infrastructure Management** - Terraform/OpenTofu infrastructure as code management
- **Repository Ingestion** - Analyze GitHub repositories to discover AitherZero components
- **Configuration Editing** - In-app editing for YAML, JSON, HCL, TOML files
- **Remote Endpoint Management** - SSH connections to remote servers
- **CLI Command Execution** - Execute AitherZero CLI commands with live output

## Tech Stack

- **Framework**: Next.js 14 with App Router
- **Language**: TypeScript
- **Styling**: Tailwind CSS with oklch color theme
- **UI Components**: shadcn/ui
- **Icons**: Phosphor Icons
- **Charts**: Recharts
- **Animations**: Framer Motion
- **Notifications**: Sonner
- **Fonts**: Inter (UI), JetBrains Mono (code)

## Getting Started

### Prerequisites

- Node.js 18+
- npm or pnpm

### Installation

```bash
# Install dependencies
npm install

# Start development server
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) with your browser to see the result.

### Development

```bash
# Run development server with Turbopack
npm run dev

# Build for production
npm run build

# Start production server
npm start

# Lint code
npm run lint
```

## Project Structure

```text
src/
 app/ # Next.js App Router
 globals.css # Global styles with oklch theme
 layout.tsx # Root layout with fonts
 page.tsx # Main dashboard page
 components/
 dashboard/ # Dashboard components
 agent-card.tsx # AI agent card
 dashboard.tsx # Main dashboard
 infra-card.tsx # Infrastructure card
 ingest-dialog.tsx # Repository ingestion
 pipeline-card.tsx # Pipeline card
 ui/ # UI components
 cli-output-viewer.tsx # Terminal output
 log-stream.tsx # Real-time logs
 status-dot.tsx # Status indicator
 ... # shadcn/ui components
 lib/
 spark-kv.ts # Local storage state management
 types.ts # TypeScript definitions
 utils.ts # Utility functions
```

## Design System

### Colors (oklch)

- **Primary**: `oklch(0.45 0.15 250)` - Deep technical blue
- **Agent Purple**: `oklch(0.60 0.18 290)` - AI/agent elements
- **Accent**: `oklch(0.68 0.18 45)` - CTAs and warnings
- **Success**: `oklch(0.65 0.20 150)` - Green indicators
- **Background**: `oklch(0.15 0.02 250)` - Dark base

### Typography

- **UI**: Inter (Regular/Semibold/Bold)
- **Code/Metrics**: JetBrains Mono

## License

MIT
