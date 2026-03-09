/**
 * API Route: Service Status
 * 
 * Returns the status of AitherZero infrastructure services (ComfyUI, Ollama, AitherNode, etc.)
 * by directly calling the 0012_Get-ServiceStatus.ps1 script.
 */

import { NextRequest, NextResponse } from 'next/server'
import { spawn } from 'child_process'
import path from 'path'

interface ServiceStatus {
  Name: string
  Status: 'Running' | 'Stopped'
  PID: number | null
  Port: number
  PortOpen: boolean
  MemoryMB: number
  Uptime: object | null
}

const AITHERZERO_ROOT = process.env.AITHERZERO_ROOT || process.cwd()

/**
 * Execute PowerShell script and get JSON output
 */
async function execPowerShellScript(scriptPath: string, args: string[] = []): Promise<string> {
  return new Promise((resolve, reject) => {
    const ps = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-File', scriptPath, ...args], {
      env: {
        ...process.env,
        AITHERZERO_ROOT: AITHERZERO_ROOT
      }
    })
    
    let output = ''
    let errorOutput = ''
    
    ps.stdout.on('data', (data) => {
      output += data.toString()
    })
    
    ps.stderr.on('data', (data) => {
      errorOutput += data.toString()
    })
    
    ps.on('close', (code) => {
      if (code === 0) {
        resolve(output.trim())
      } else {
        reject(new Error(`PowerShell exited with code ${code}: ${errorOutput}`))
      }
    })
    
    ps.on('error', reject)
    
    // Timeout after 10 seconds
    setTimeout(() => {
      ps.kill()
      reject(new Error('Script execution timeout'))
    }, 10000)
  })
}

/**
 * GET - Get service statuses
 */
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url)
    const servicesParam = searchParams.get('services')
    
    // Build script path
    const scriptPath = path.join(
      AITHERZERO_ROOT,
      'AitherZero',
      'library',
      'automation-scripts',
      '0012_Get-ServiceStatus.ps1'
    )
    
    // Execute the script with -AsJson
    const args = ['-AsJson']
    if (servicesParam) {
      args.push('-Services', servicesParam)
    }
    
    const output = await execPowerShellScript(scriptPath, args)
    
    // Parse the JSON output
    const services: ServiceStatus[] = JSON.parse(output)
    
    return NextResponse.json({
      success: true,
      services,
      timestamp: new Date().toISOString()
    })
  } catch (error) {
    console.error('[Services API] Error:', error)
    return NextResponse.json(
      { 
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
        services: []
      },
      { status: 500 }
    )
  }
}

/**
 * POST - Start/Stop a service
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json()
    const { action, service, port } = body

    if (!action || !service) {
      return NextResponse.json(
        { success: false, error: 'Missing action or service parameter' },
        { status: 400 }
      )
    }

    let scriptPath: string
    const args: string[] = []

    if (action === 'start') {
      // Map service ID to start script name
      let scriptName: string
      switch (service) {
        case 'comfyui':
          scriptName = '0734_Start-ComfyUI.ps1'
          break
        case 'comfyui-gateway':
          scriptName = '0732_Start-ComfyUIGateway.ps1'
          break
        case 'ollama':
          scriptName = '0737_Start-Ollama.ps1'
          break
        case 'aithernode':
          scriptName = '0762_Start-AitherNode.ps1'
          break
        default:
          return NextResponse.json(
            { success: false, error: `Unknown service: ${service}` },
            { status: 400 }
          )
      }
      
      scriptPath = path.join(
        AITHERZERO_ROOT,
        'AitherZero',
        'library',
        'automation-scripts',
        scriptName
      )
      
      if (port) {
        args.push('-Port', String(port))
      }
      args.push('-Detached')
      
    } else if (action === 'stop') {
      scriptPath = path.join(
        AITHERZERO_ROOT,
        'AitherZero',
        'library',
        'automation-scripts',
        '0013_Stop-Service.ps1'
      )
      
      // Map frontend ID to backend name
      let backendName: string
      switch (service) {
        case 'comfyui':
          backendName = 'ComfyUI'
          break
        case 'ollama':
          backendName = 'Ollama'
          break
        case 'aithernode':
          backendName = 'AitherNode'
          break
        case 'comfyui-gateway':
          backendName = 'Cloudflared'
          break
        default:
          backendName = service
      }
      
      args.push('-Name', backendName, '-Force')
    } else {
      return NextResponse.json(
        { success: false, error: `Unknown action: ${action}` },
        { status: 400 }
      )
    }

    const output = await execPowerShellScript(scriptPath, args)
    
    return NextResponse.json({
      success: true,
      output,
      timestamp: new Date().toISOString()
    })
  } catch (error) {
    console.error('[Services API] Error:', error)
    return NextResponse.json(
      { 
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    )
  }
}
