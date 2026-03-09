#!/usr/bin/env node

/**
 * AitherOS Windows Integration MCP Server
 * 
 * Provides deep Windows OS integration tools:
 * - Desktop notifications with actions
 * - Clipboard read/write with content detection
 * - Protocol handler registration (aither://)
 * - System tray management
 * - Startup registration
 * - File/folder watching
 * - Windows Terminal integration
 * 
 * Usage: npx @aitheros/mcp-windows
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from '@modelcontextprotocol/sdk/types.js';
import { spawn } from 'child_process';
import { promisify } from 'util';
import { exec as execCallback } from 'child_process';
import * as path from 'path';
import * as os from 'os';

const exec = promisify(execCallback);

// Configuration
const AITHEROS_ROOT = process.env.AITHEROS_ROOT || path.resolve(__dirname, '..', '..', '..', '..', '..');
const ICON_PATH = path.join(AITHEROS_ROOT, 'assets', 'icons', 'aitheros-logo.png');

/**
 * Execute a PowerShell command and return the result
 */
async function runPowerShell(script: string): Promise<{ stdout: string; stderr: string; success: boolean }> {
  try {
    const { stdout, stderr } = await exec(
      `pwsh -NoProfile -NonInteractive -Command "${script.replace(/"/g, '\\"')}"`,
      { maxBuffer: 10 * 1024 * 1024 }
    );
    return { stdout: stdout.trim(), stderr: stderr.trim(), success: true };
  } catch (error: any) {
    return {
      stdout: error.stdout || '',
      stderr: error.stderr || error.message,
      success: false
    };
  }
}

/**
 * Ensure BurntToast module is available
 */
async function ensureBurntToast(): Promise<boolean> {
  const check = await runPowerShell("Get-Module -ListAvailable -Name BurntToast | Select-Object -First 1");
  if (!check.stdout) {
    await runPowerShell("Install-Module -Name BurntToast -Force -Scope CurrentUser -AllowClobber");
  }
  return true;
}

// Tool definitions
const TOOLS: Tool[] = [
  {
    name: "windows_notify",
    description: "Send a Windows desktop notification with optional action buttons. Use for alerts, completions, reminders.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Notification title (bold, first line)" },
        message: { type: "string", description: "Notification body text" },
        type: { 
          type: "string", 
          enum: ["info", "success", "warning", "error", "critical"],
          description: "Notification type - affects icon/sound" 
        },
        actions: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              url: { type: "string" }
            }
          },
          description: "Optional action buttons with labels and URLs"
        },
        silent: { type: "boolean", description: "If true, no sound plays" }
      },
      required: ["title", "message"]
    }
  },
  {
    name: "windows_clipboard_read",
    description: "Read the current Windows clipboard contents. Returns text and detected content type (json, url, error, code, plain).",
    inputSchema: {
      type: "object",
      properties: {},
      required: []
    }
  },
  {
    name: "windows_clipboard_write",
    description: "Write text to the Windows clipboard.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "Text to copy to clipboard" }
      },
      required: ["text"]
    }
  },
  {
    name: "windows_json_validate",
    description: "Validate JSON from clipboard or provided text. Returns validation result.",
    inputSchema: {
      type: "object",
      properties: {
        json: { type: "string", description: "JSON to validate. If empty, reads from clipboard." }
      },
      required: []
    }
  },
  {
    name: "windows_json_format",
    description: "Pretty-print JSON from clipboard or provided text. Copies formatted result to clipboard.",
    inputSchema: {
      type: "object",
      properties: {
        json: { type: "string", description: "JSON to format. If empty, reads from clipboard." }
      },
      required: []
    }
  },
  {
    name: "windows_protocol_invoke",
    description: "Invoke an aither:// protocol URL. Examples: aither://dashboard, aither://service/moltbook/restart, aither://health",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "The aither:// URL to invoke" }
      },
      required: ["url"]
    }
  },
  {
    name: "windows_startup_register",
    description: "Register or unregister AitherOS to start with Windows.",
    inputSchema: {
      type: "object",
      properties: {
        mode: { 
          type: "string", 
          enum: ["full", "minimal", "monitor"],
          description: "Startup mode: full (all services), minimal (genesis only), monitor (health monitoring)" 
        },
        remove: { type: "boolean", description: "If true, removes from startup instead of adding" }
      },
      required: []
    }
  },
  {
    name: "windows_terminal_profile",
    description: "Add AitherOS profile to Windows Terminal for quick access.",
    inputSchema: {
      type: "object",
      properties: {},
      required: []
    }
  },
  {
    name: "windows_system_info",
    description: "Get Windows system information - OS version, memory, CPU, etc.",
    inputSchema: {
      type: "object",
      properties: {},
      required: []
    }
  },
  {
    name: "windows_process_list",
    description: "List running processes, optionally filtered by name.",
    inputSchema: {
      type: "object",
      properties: {
        filter: { type: "string", description: "Process name filter (supports wildcards)" },
        top: { type: "number", description: "Limit to top N processes by memory" }
      },
      required: []
    }
  },
  {
    name: "windows_service_control",
    description: "Control Windows services (start, stop, restart, status).",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Service name" },
        action: { 
          type: "string", 
          enum: ["start", "stop", "restart", "status"],
          description: "Action to perform" 
        }
      },
      required: ["name", "action"]
    }
  },
  {
    name: "windows_open",
    description: "Open a file, folder, or URL with the default Windows application.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Path to file/folder or URL to open" }
      },
      required: ["path"]
    }
  }
];

// Tool handlers
async function handleTool(name: string, args: Record<string, any>): Promise<string> {
  switch (name) {
    case "windows_notify": {
      await ensureBurntToast();
      const emoji: Record<string, string> = {
        info: 'ℹ️', success: '✅', warning: '⚠️', error: '❌', critical: '🚨'
      };
      const prefix = emoji[args.type || 'info'] || 'ℹ️';
      
      let script = `Import-Module BurntToast; `;
      
      // Build buttons if provided
      if (args.actions && args.actions.length > 0) {
        const buttons = args.actions.map((a: any, i: number) => 
          `$btn${i} = New-BTButton -Content '${a.label}' -Arguments '${a.url}'`
        ).join('; ');
        const btnVars = args.actions.map((_: any, i: number) => `$btn${i}`).join(', ');
        script += `${buttons}; New-BurntToastNotification -Text '${prefix} ${args.title}', '${args.message}' -Button ${btnVars}`;
      } else {
        script += `New-BurntToastNotification -Text '${prefix} ${args.title}', '${args.message}'`;
      }
      
      // Add icon if exists
      script += ` -AppLogo '${ICON_PATH}'`;
      
      const result = await runPowerShell(script);
      return result.success ? `Notification sent: ${args.title}` : `Error: ${result.stderr}`;
    }

    case "windows_clipboard_read": {
      const result = await runPowerShell("Get-Clipboard");
      const text = result.stdout;
      
      // Detect content type
      let contentType = 'plain';
      if (text.trim().startsWith('{') || text.trim().startsWith('[')) {
        try { JSON.parse(text); contentType = 'json'; } catch {}
      } else if (/^https?:\/\//.test(text)) {
        contentType = 'url';
      } else if (/Exception|Error|Traceback|at line \d+/.test(text)) {
        contentType = 'error';
      } else if (/function|def |class |import |const |let /.test(text)) {
        contentType = 'code';
      }
      
      return JSON.stringify({ text, contentType, length: text.length });
    }

    case "windows_clipboard_write": {
      const escaped = args.text.replace(/'/g, "''");
      const result = await runPowerShell(`Set-Clipboard -Value '${escaped}'`);
      return result.success ? `Copied ${args.text.length} characters to clipboard` : `Error: ${result.stderr}`;
    }

    case "windows_json_validate": {
      let json = args.json;
      if (!json) {
        const clip = await runPowerShell("Get-Clipboard");
        json = clip.stdout;
      }
      try {
        JSON.parse(json);
        return JSON.stringify({ valid: true, message: "JSON is valid" });
      } catch (e: any) {
        return JSON.stringify({ valid: false, message: e.message });
      }
    }

    case "windows_json_format": {
      let json = args.json;
      if (!json) {
        const clip = await runPowerShell("Get-Clipboard");
        json = clip.stdout;
      }
      try {
        const formatted = JSON.stringify(JSON.parse(json), null, 2);
        await runPowerShell(`Set-Clipboard -Value '${formatted.replace(/'/g, "''")}'`);
        return JSON.stringify({ success: true, message: "Formatted JSON copied to clipboard", preview: formatted.slice(0, 200) });
      } catch (e: any) {
        return JSON.stringify({ success: false, error: e.message });
      }
    }

    case "windows_protocol_invoke": {
      const handlerPath = path.join(AITHEROS_ROOT, 'AitherZero', 'src', 'public', 'Invoke-AitherProtocol.ps1');
      const result = await runPowerShell(`& '${handlerPath}' '${args.url}'`);
      return result.stdout || result.stderr || `Invoked: ${args.url}`;
    }

    case "windows_startup_register": {
      const mode = args.mode || 'monitor';
      const remove = args.remove ? '-Remove' : '';
      const script = `
        $startupPath = "$env:APPDATA\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"
        $shortcutPath = Join-Path $startupPath "AitherOS.lnk"
        ${args.remove ? `
          if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force; 'Removed from startup' } else { 'Not in startup' }
        ` : `
          $scriptPath = switch ('${mode}') {
            'full' { '${AITHEROS_ROOT}\\Start-AitherOS.ps1' }
            'minimal' { '${AITHEROS_ROOT}\\start_genesis.ps1' }
            'monitor' { '${AITHEROS_ROOT}\\AitherZero\\library\\automation-scripts\\40-lifecycle\\4010_Start-Monitor.ps1' }
          }
          $WshShell = New-Object -ComObject WScript.Shell
          $Shortcut = $WshShell.CreateShortcut($shortcutPath)
          $Shortcut.TargetPath = 'pwsh.exe'
          $Shortcut.Arguments = "-NoProfile -WindowStyle Hidden -File \`"$scriptPath\`""
          $Shortcut.WorkingDirectory = '${AITHEROS_ROOT}'
          $Shortcut.Save()
          "Registered for startup: $mode mode"
        `}
      `;
      const result = await runPowerShell(script);
      return result.stdout || result.stderr;
    }

    case "windows_terminal_profile": {
      const script = `
        $settingsPath = "$env:LOCALAPPDATA\\Packages\\Microsoft.WindowsTerminal_8wekyb3d8bbwe\\LocalState\\settings.json"
        if (-not (Test-Path $settingsPath)) { 'Windows Terminal not found'; return }
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $existing = $settings.profiles.list | Where-Object { $_.name -eq 'AitherOS' }
        if ($existing) { 'AitherOS profile already exists' }
        else {
          $profile = @{
            name = 'AitherOS'
            commandline = 'pwsh.exe -NoExit -Command "cd ${AITHEROS_ROOT}; Import-Module .\\AitherZero\\AitherZero.psd1"'
            startingDirectory = '${AITHEROS_ROOT}'
            icon = '🤖'
            tabTitle = 'AitherOS'
          }
          $settings.profiles.list += $profile
          $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
          'Added AitherOS profile to Windows Terminal'
        }
      `;
      const result = await runPowerShell(script);
      return result.stdout || result.stderr;
    }

    case "windows_system_info": {
      const script = `
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $mem = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        $memFree = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        @{
          os = $os.Caption
          version = $os.Version
          arch = $os.OSArchitecture
          computer = $env:COMPUTERNAME
          user = $env:USERNAME
          cpu = $cpu.Name
          cores = $cpu.NumberOfCores
          memory_gb = $mem
          memory_free_gb = $memFree
          uptime_hours = [math]::Round((Get-Date) - $os.LastBootUpTime | Select-Object -ExpandProperty TotalHours, 2)
        } | ConvertTo-Json
      `;
      const result = await runPowerShell(script);
      return result.stdout || result.stderr;
    }

    case "windows_process_list": {
      const filter = args.filter ? `-Name '${args.filter}'` : '';
      const top = args.top || 20;
      const script = `
        Get-Process ${filter} -ErrorAction SilentlyContinue | 
        Sort-Object WorkingSet64 -Descending | 
        Select-Object -First ${top} Name, Id, @{N='MemoryMB';E={[math]::Round($_.WorkingSet64/1MB,2)}}, CPU |
        ConvertTo-Json
      `;
      const result = await runPowerShell(script);
      return result.stdout || result.stderr;
    }

    case "windows_service_control": {
      const script = args.action === 'status'
        ? `Get-Service -Name '${args.name}' -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | ConvertTo-Json`
        : `${args.action === 'restart' ? 'Restart' : args.action === 'start' ? 'Start' : 'Stop'}-Service -Name '${args.name}' -PassThru | Select-Object Name, Status | ConvertTo-Json`;
      const result = await runPowerShell(script);
      return result.stdout || result.stderr;
    }

    case "windows_open": {
      const result = await runPowerShell(`Start-Process '${args.path}'`);
      return result.success ? `Opened: ${args.path}` : `Error: ${result.stderr}`;
    }

    default:
      return `Unknown tool: ${name}`;
  }
}

// Create and run server
const server = new Server(
  { name: "mcp-windows", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const result = await handleTool(request.params.name, request.params.arguments || {});
  return {
    content: [{ type: "text", text: result }]
  };
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("MCP Windows server running");
}

main().catch(console.error);
