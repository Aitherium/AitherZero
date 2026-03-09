/**
 * API Route: Execute PowerShell Commands
 * 
 * This route executes actual PowerShell commands on the server.
 * Supports script execution, playbooks, and raw commands.
 */

import { NextRequest, NextResponse } from 'next/server'
import { spawn } from 'child_process'
import path from 'path'

// Get the AitherZero root directory (relative to this file)
const AITHERZERO_ROOT = process.env.AITHERZERO_ROOT || path.resolve(process.cwd(), '../../../../..')

interface ExecuteRequest {
  type: 'script' | 'playbook' | 'command' | 'module-function'
  target: string
  params?: Record<string, unknown>
  verbose?: boolean
  dryRun?: boolean
}

interface ExecuteResponse {
  success: boolean
  output: string
  exitCode: number
  duration: number
  error?: string
}

/**
 * Execute a PowerShell command and return the output
 */
async function executePowerShell(command: string, cwd?: string): Promise<ExecuteResponse> {
  const startTime = Date.now()
  
  return new Promise((resolve) => {
    const ps = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
      cwd: cwd || AITHERZERO_ROOT,
      env: {
        ...process.env,
        AITHERZERO_ROOT: AITHERZERO_ROOT,
        FORCE_COLOR: '1'
      }
    })

    let stdout = ''
    let stderr = ''

    ps.stdout.on('data', (data) => {
      stdout += data.toString()
    })

    ps.stderr.on('data', (data) => {
      stderr += data.toString()
    })

    ps.on('close', (code) => {
      const duration = Date.now() - startTime
      resolve({
        success: code === 0,
        output: stdout || stderr,
        exitCode: code || 0,
        duration,
        error: code !== 0 ? stderr : undefined
      })
    })

    ps.on('error', (err) => {
      const duration = Date.now() - startTime
      resolve({
        success: false,
        output: '',
        exitCode: -1,
        duration,
        error: err.message
      })
    })
  })
}

/**
 * Build command for script execution
 */
function buildScriptCommand(scriptNumber: string, params?: Record<string, unknown>, verbose?: boolean): string {
  const scriptsPath = path.join(AITHERZERO_ROOT, 'AitherZero', 'library', 'automation-scripts')
  
  // Find the script file
  const scriptPattern = `${scriptNumber}_*.ps1`
  
  let command = `
    $ErrorActionPreference = 'Continue'
    $scriptPath = Get-ChildItem -Path '${scriptsPath}' -Filter '${scriptPattern}' | Select-Object -First 1
    if (-not $scriptPath) {
      Write-Error "Script ${scriptNumber} not found"
      exit 1
    }
  `
  
  // Add parameters
  const paramStrings: string[] = []
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (typeof value === 'boolean') {
        if (value) paramStrings.push(`-${key}`)
      } else if (typeof value === 'string') {
        paramStrings.push(`-${key} '${value}'`)
      } else {
        paramStrings.push(`-${key} ${value}`)
      }
    }
  }
  
  if (verbose) {
    paramStrings.push('-Verbose')
  }
  
  command += `& $scriptPath.FullName ${paramStrings.join(' ')}`
  
  return command
}

/**
 * Build command for playbook execution
 */
function buildPlaybookCommand(playbookName: string, profile?: string): string {
  const command = `
    Import-Module '${path.join(AITHERZERO_ROOT, 'AitherZero', 'AitherZero.psd1')}' -Force
    Invoke-AitherPlaybook -Name '${playbookName}'${profile ? ` -Profile '${profile}'` : ''}
  `
  return command
}

/**
 * Build command for module function execution
 */
function buildModuleFunctionCommand(functionName: string, params?: Record<string, unknown>): string {
  const paramStrings: string[] = []
  if (params) {
    for (const [key, value] of Object.entries(params)) {
      if (typeof value === 'boolean') {
        if (value) paramStrings.push(`-${key}`)
      } else if (typeof value === 'string') {
        paramStrings.push(`-${key} '${value}'`)
      } else if (Array.isArray(value)) {
        paramStrings.push(`-${key} @(${value.map(v => `'${v}'`).join(',')})`)
      } else {
        paramStrings.push(`-${key} ${value}`)
      }
    }
  }
  
  const command = `
    Import-Module '${path.join(AITHERZERO_ROOT, 'AitherZero', 'AitherZero.psd1')}' -Force
    ${functionName} ${paramStrings.join(' ')}
  `
  return command
}

export async function POST(request: NextRequest) {
  try {
    const body: ExecuteRequest = await request.json()
    
    if (!body.type || !body.target) {
      return NextResponse.json(
        { success: false, error: 'Missing required fields: type, target' },
        { status: 400 }
      )
    }

    let command: string
    
    switch (body.type) {
      case 'script':
        command = buildScriptCommand(body.target, body.params, body.verbose)
        break
      
      case 'playbook':
        command = buildPlaybookCommand(body.target, body.params?.profile as string)
        break
      
      case 'module-function':
        command = buildModuleFunctionCommand(body.target, body.params)
        break
      
      case 'command':
        // Direct command execution (use with caution)
        command = body.target
        break
      
      default:
        return NextResponse.json(
          { success: false, error: `Unknown execution type: ${body.type}` },
          { status: 400 }
        )
    }

    // Execute the command
    const result = await executePowerShell(command)
    
    return NextResponse.json(result)
  } catch (error) {
    return NextResponse.json(
      { 
        success: false, 
        output: '', 
        exitCode: -1, 
        duration: 0,
        error: error instanceof Error ? error.message : 'Unknown error' 
      },
      { status: 500 }
    )
  }
}

// GET endpoint for testing
export async function GET() {
  // Quick test to verify PowerShell is available
  const result = await executePowerShell('$PSVersionTable | ConvertTo-Json')
  
  return NextResponse.json({
    status: result.success ? 'ok' : 'error',
    powershellAvailable: result.success,
    aitherZeroRoot: AITHERZERO_ROOT,
    ...result
  })
}
