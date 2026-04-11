# Model Context Protocol (MCP) Server Setup for AitherZero

To leverage AitherZero's automation capabilities within LLM environments like GitHub Copilot or Gemini, configure the AitherZero MCP server.

## 1. Installation

Install the AitherZero MCP server package via npm:

```bash
npm install @aitherzero/mcp-server
```

## 2. Copilot Integration Configuration

Add the following snippet to your `.github/mcp-servers.json` (or the appropriate configuration file for your MCP client) to register AitherZero as an MCP server.

```json
{
  "mcpServers": {
    "aitherzero": {
      "command": "node",
      "args": [
        "./node_modules/@aitherzero/mcp-server/dist/index.js",
        "--workspace",
        "${workspaceFolder}"
      ],
      "description": "AitherZero infrastructure automation and orchestration server"
    }
  }
}
```
