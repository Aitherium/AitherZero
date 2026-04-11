/**
 * API Route: MCP Bridge
 * 
 * This route acts as an HTTP-to-MCP bridge for the AitherZero MCP server.
 * It spawns the MCP server and communicates via JSON-RPC over stdio.
 */

import { NextRequest, NextResponse } from 'next/server'
import { spawn, ChildProcess } from 'child_process'

// ============================================================================
// TYPES
// ============================================================================

interface PendingRequest {
  resolve: (value: unknown) => void
  reject: (reason: unknown) => void
}

// ============================================================================
// MODULE-LEVEL STATE (Singleton per process)
// ============================================================================

let mcpProcess: ChildProcess | null = null
let mcpReady = false
let outputBuffer = ''
let requestId = 0
const pendingRequests = new Map<number, PendingRequest>()

// Runtime config - must be queried at runtime, not build time
let cachedServerPath: string | null = null
let cachedAitherZeroRoot: string | null = null

// ============================================================================
// CONFIGURATION HELPERS
// ============================================================================

function getAitherZeroRoot(): string {
  if (!cachedAitherZeroRoot) {
    cachedAitherZeroRoot = process.env['AITHERZERO_ROOT'] || process.cwd()
  }
  return cachedAitherZeroRoot
}

function getMCPServerPath(): string {
  if (!cachedServerPath) {
    // Check for explicit path first
    const envPath = process.env['MCP_SERVER_PATH']
    if (envPath) {
      cachedServerPath = envPath
    } else {
      // Default: relative to AITHERZERO_ROOT
      const root = getAitherZeroRoot()
      cachedServerPath = [root, 'AitherZero', 'library', 'integrations', 'mcp-server', 'dist', 'index.js'].join('/')
    }
  }
  return cachedServerPath
}

// ============================================================================
// MCP SERVER MANAGEMENT
// ============================================================================

// Use eval to prevent Turbopack from analyzing spawn arguments
const spawnProcess = eval('require')('child_process').spawn as typeof spawn

/**
 * Start the MCP server process
 */
function startMCPServer(): Promise<void> {
  return new Promise((resolve, reject) => {
    if (mcpProcess && !mcpProcess.killed) {
      resolve()
      return
    }

    const serverPath = getMCPServerPath()
    const aitherZeroRoot = getAitherZeroRoot()

    console.log('[MCP Bridge] Starting MCP server at:', serverPath)
    console.log('[MCP Bridge] AITHERZERO_ROOT:', aitherZeroRoot)

    // Use spawnProcess to avoid Turbopack static analysis
    mcpProcess = spawnProcess('node', [serverPath], {
      env: {
        ...process.env,
        AITHERZERO_ROOT: aitherZeroRoot,
        AITHERZERO_NONINTERACTIVE: '1'
      },
      stdio: ['pipe', 'pipe', 'pipe']
    })

    mcpProcess.stdout?.on('data', (data: Buffer) => {
      outputBuffer += data.toString()
      
      // Process complete JSON-RPC messages
      const lines = outputBuffer.split('\n')
      outputBuffer = lines.pop() || '' // Keep incomplete line in buffer
      
      for (const line of lines) {
        if (!line.trim()) continue
        try {
          const response = JSON.parse(line)
          const pending = pendingRequests.get(response.id)
          if (pending) {
            pendingRequests.delete(response.id)
            if (response.error) {
              pending.reject(response.error)
            } else {
              pending.resolve(response.result)
            }
          }
        } catch {
          // Not JSON, might be log output
          console.log('[MCP stdout]', line)
        }
      }
    })

    mcpProcess.stderr?.on('data', (data: Buffer) => {
      console.error('[MCP stderr]', data.toString())
    })

    mcpProcess.on('error', (err: Error) => {
      console.error('[MCP Bridge] Process error:', err)
      mcpReady = false
      reject(err)
    })

    mcpProcess.on('close', (code: number | null) => {
      console.log('[MCP Bridge] Process closed with code:', code)
      mcpReady = false
      mcpProcess = null
    })

    // Give it a moment to start
    setTimeout(() => {
      mcpReady = true
      resolve()
    }, 500)
  })
}

/**
 * Send a JSON-RPC request to the MCP server
 */
async function sendMCPRequest(method: string, params: unknown = {}): Promise<unknown> {
  if (!mcpProcess || mcpProcess.killed) {
    await startMCPServer()
  }

  const id = ++requestId
  const request = {
    jsonrpc: '2.0',
    id,
    method,
    params
  }

  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject })
    
    const timeout = setTimeout(() => {
      pendingRequests.delete(id)
      reject(new Error('MCP request timeout'))
    }, 60000) // 60 second timeout

    try {
      mcpProcess?.stdin?.write(JSON.stringify(request) + '\n')
    } catch (err) {
      clearTimeout(timeout)
      pendingRequests.delete(id)
      reject(err)
    }

    // Clear timeout on success
    const pending = pendingRequests.get(id)
    if (pending) {
      const originalResolve = pending.resolve
      const originalReject = pending.reject
      pendingRequests.set(id, {
        resolve: (value) => {
          clearTimeout(timeout)
          originalResolve(value)
        },
        reject: (reason) => {
          clearTimeout(timeout)
          originalReject(reason)
        }
      })
    }
  })
}

// ============================================================================
// API HANDLERS
// ============================================================================

/**
 * POST - Execute an MCP tool
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json()
    const { method, params } = body

    if (!method) {
      return NextResponse.json(
        { error: 'Missing method parameter' },
        { status: 400 }
      )
    }

    const result = await sendMCPRequest(method, params)
    
    return NextResponse.json({ 
      success: true,
      result 
    })
  } catch (error) {
    console.error('[MCP Bridge] Error:', error)
    return NextResponse.json(
      { 
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error' 
      },
      { status: 500 }
    )
  }
}

/**
 * GET - Get MCP server status and available tools
 */
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url)
  const action = searchParams.get('action') || 'status'

  try {
    switch (action) {
      case 'status':
        return NextResponse.json({
          running: mcpProcess !== null && !mcpProcess.killed,
          ready: mcpReady,
          serverPath: getMCPServerPath(),
          aitherZeroRoot: getAitherZeroRoot()
        })

      case 'tools': {
        const tools = await sendMCPRequest('tools/list', {})
        return NextResponse.json({ success: true, tools })
      }

      case 'resources': {
        const resources = await sendMCPRequest('resources/list', {})
        return NextResponse.json({ success: true, resources })
      }

      case 'prompts': {
        const prompts = await sendMCPRequest('prompts/list', {})
        return NextResponse.json({ success: true, prompts })
      }

      case 'start':
        await startMCPServer()
        return NextResponse.json({ success: true, message: 'MCP server started' })

      case 'stop':
        if (mcpProcess) {
          mcpProcess.kill()
          mcpProcess = null
          mcpReady = false
        }
        return NextResponse.json({ success: true, message: 'MCP server stopped' })

      default:
        return NextResponse.json(
          { error: `Unknown action: ${action}` },
          { status: 400 }
        )
    }
  } catch (error) {
    console.error('[MCP Bridge] Error:', error)
    return NextResponse.json(
      { 
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error' 
      },
      { status: 500 }
    )
  }
}
