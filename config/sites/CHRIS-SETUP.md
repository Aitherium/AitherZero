# Chris's AitherOS Node Setup

Lightweight deployment — connects your IDE to Elysium via AitherNode.
This is NOT a full Docker stack. Your machine runs the ADK + MCP server.

## Quick Start (3 commands)

```bash
# 1. Install
pip install aither-adk

# 2. Register + connect
aither register --email chris@aitherium.com
aither connect

# 3. Onboard (auto-configures Claude Code, Cursor, OpenClaw)
aither onboard --tenant welchman-labs
```

That's it. Your IDE now has 100+ MCP tools connected to Elysium.

## What Gets Installed

| Component | What | How |
|-----------|------|-----|
| **aither-adk** | Agent framework + CLI | `pip install aither-adk` |
| **AitherNode** | MCP server (localhost:8080) | Started by `aither onboard` |
| **MCP configs** | Claude Code, Cursor, OpenClaw | Auto-detected and configured |
| **AitherDesktop** | Native overlay app (optional) | `pip install aither-desktop` |

## What You DON'T Need

- No Docker
- No 85-container stack
- No GPU (cloud inference via Elysium)
- No manual MCP configuration

## Your Tenant

| Field | Value |
|-------|-------|
| Tenant | `welchman-labs` |
| Domain | `welchman-labs.aitherium.com` |
| Plan | Enterprise (unlimited) |
| Your user | `chris` / `welchman` |
| Personal tenant | `tnt_chris` |
| Org membership | `tnt_aitherium` |

## Your Credentials

| Credential | How to Get It |
|------------|---------------|
| API Key | `aither register` (self-service) |
| Tunnel Token | Generated when you click "Deploy Node" in settings |

## How AitherNode Works

```
Your Machine                    Elysium (Cloud)
┌────────────────────┐        ┌──────────────────────┐
│  Claude Code       │        │  gateway.aitherium.com│
│  Cursor            │        │  mcp.aitherium.com    │
│  OpenClaw          │        │  Full AitherOS stack  │
│       ↕ MCP        │        │  (85 containers)      │
│  AitherNode:8080   │───────→│  LLM inference        │
│       ↕            │        │  100+ tools           │
│  Local Ollama/vLLM │        │  Memory graph         │
│  (optional)        │        │  Agent dispatch       │
└────────────────────┘        └──────────────────────┘
```

AitherNode bridges your IDE tools to Elysium. When you call an MCP tool
in Claude Code, it routes through AitherNode to the full platform.

## MCP Server Details

- **URL**: `http://localhost:8080`
- **SSE**: `http://localhost:8080/sse`
- **Protocol**: JSON-RPC 2.0 over HTTP+SSE
- **Tools**: 100+ (code search, memory, agents, generation, etc.)

## Playbook (Alternative to Quick Start)

```powershell
# If you have PowerShell 7:
Import-Module ./AitherZero/AitherZero.psd1
Invoke-AitherPlaybook onboard-remote-site -ConfigOverlay sites/chris.psd1
```

## Commands

```bash
aither run              # Start your agent server
aither init my-agent    # Create a new agent project
aither connect          # Check Elysium connection
aither onboard          # Re-run setup (safe to re-run)
aither integrate        # Connect external tools
aither publish          # Submit agent to Elysium marketplace
aither aeon             # Multi-agent group chat
```

## Manage Your Account

- API Keys: https://demo.aitherium.com/settings/api-keys
- Profile: https://demo.aitherium.com/profile
- Settings: https://demo.aitherium.com/settings
- IRC: https://irc.aitherium.com
