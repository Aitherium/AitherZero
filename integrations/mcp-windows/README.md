# MCP Windows Integration Server

Windows OS integration tools for AI agents via Model Context Protocol.

## Tools Available

| Tool | Description |
|------|-------------|
| `windows_notify` | Send desktop notifications with action buttons |
| `windows_clipboard_read` | Read clipboard with content type detection |
| `windows_clipboard_write` | Write to clipboard |
| `windows_json_validate` | Validate JSON (from clipboard or arg) |
| `windows_json_format` | Pretty-print JSON to clipboard |
| `windows_protocol_invoke` | Invoke `aither://` deep links |
| `windows_startup_register` | Register/unregister Windows startup |
| `windows_terminal_profile` | Add profile to Windows Terminal |
| `windows_system_info` | Get OS version, CPU, memory info |
| `windows_process_list` | List processes with memory usage |
| `windows_service_control` | Start/stop/restart Windows services |
| `windows_open` | Open files/URLs with default app |

## Usage

### In VS Code (mcp.json)

```json
{
  "mcpServers": {
    "windows": {
      "type": "stdio",
      "command": "npx",
      "args": ["tsx", "${workspaceFolder}/AitherZero/library/integrations/mcp-windows/src/index.ts"],
      "env": {
        "AITHEROS_ROOT": "${workspaceFolder}"
      }
    }
  }
}
```

### Standalone

```bash
cd AitherZero/library/integrations/mcp-windows
npm install
npx tsx src/index.ts
```

## Examples

### Send a notification
```json
{
  "method": "tools/call",
  "params": {
    "name": "windows_notify",
    "arguments": {
      "title": "Build Complete",
      "message": "Your project built successfully!",
      "type": "success",
      "actions": [
        {"label": "Open Folder", "url": "file:///C:/project"},
        {"label": "View Logs", "url": "aither://logs"}
      ]
    }
  }
}
```

### Read clipboard and detect content type
```json
{
  "method": "tools/call",
  "params": {
    "name": "windows_clipboard_read",
    "arguments": {}
  }
}
// Returns: {"text": "...", "contentType": "json|url|error|code|plain", "length": 123}
```

### Validate JSON from clipboard
```json
{
  "method": "tools/call",
  "params": {
    "name": "windows_json_validate",
    "arguments": {}
  }
}
// Returns: {"valid": true, "message": "JSON is valid"}
```

### Invoke deep link
```json
{
  "method": "tools/call",
  "params": {
    "name": "windows_protocol_invoke",
    "arguments": {"url": "aither://service/moltbook/restart"}
  }
}
```

## Protocol URLs (aither://)

| URL | Action |
|-----|--------|
| `aither://dashboard` | Open AitherVeil dashboard |
| `aither://health` | Show system health notification |
| `aither://service/{name}/restart` | Restart a service |
| `aither://service/{name}/logs` | Open service logs |
| `aither://tools/json/validate` | Validate clipboard JSON |
| `aither://tools/json/format` | Format clipboard JSON |

## Requirements

- Windows 10/11
- PowerShell 7+
- Node.js 18+
- BurntToast PowerShell module (auto-installed)

## License

MIT
