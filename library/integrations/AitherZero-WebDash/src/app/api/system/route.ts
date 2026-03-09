/**
 * API Route: System Metrics
 * 
 * Returns real system metrics including CPU, memory, disk, and process info.
 */

import { NextRequest, NextResponse } from 'next/server'
import { spawn } from 'child_process'
import os from 'os'
import path from 'path'

const AITHERZERO_ROOT = process.env.AITHERZERO_ROOT || path.resolve(process.cwd(), '../../../../..')

interface SystemMetrics {
  hostname: string
  platform: string
  arch: string
  uptime: number
  uptimeFormatted: string
  
  cpu: {
    model: string
    cores: number
    usage: number
    loadAverage: number[]
  }
  
  memory: {
    total: number
    free: number
    used: number
    usagePercent: number
  }
  
  disk?: {
    total: number
    free: number
    used: number
    usagePercent: number
  }
  
  powershell?: {
    version: string
    edition: string
  }
  
  node: {
    version: string
    memoryUsage: NodeJS.MemoryUsage
  }

  processes?: {
    pwsh: number
    python: number
    node: number
  }
}

/**
 * Execute PowerShell and get output
 */
async function execPowerShell(command: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const ps = spawn('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command])
    let output = ''
    
    ps.stdout.on('data', (data) => {
      output += data.toString()
    })
    
    ps.on('close', (code) => {
      if (code === 0) {
        resolve(output.trim())
      } else {
        reject(new Error(`PowerShell exited with code ${code}`))
      }
    })
    
    ps.on('error', reject)
  })
}

/**
 * Get CPU usage (approximate using load average on non-Windows)
 */
function getCPUUsage(): number {
  const cpus = os.cpus()
  const loadAvg = os.loadavg()[0]
  return Math.min(100, (loadAvg / cpus.length) * 100)
}

/**
 * Format uptime to human readable
 */
function formatUptime(seconds: number): string {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  
  const parts = []
  if (days > 0) parts.push(`${days}d`)
  if (hours > 0) parts.push(`${hours}h`)
  if (minutes > 0) parts.push(`${minutes}m`)
  
  return parts.join(' ') || '< 1m'
}

/**
 * Format bytes to human readable
 */
function formatBytes(bytes: number): string {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0
  while (bytes >= 1024 && i < units.length - 1) {
    bytes /= 1024
    i++
  }
  return `${bytes.toFixed(1)} ${units[i]}`
}

export async function GET(request: NextRequest) {
  try {
    const cpus = os.cpus()
    const totalMem = os.totalmem()
    const freeMem = os.freemem()
    const usedMem = totalMem - freeMem

    const metrics: SystemMetrics = {
      hostname: os.hostname(),
      platform: os.platform(),
      arch: os.arch(),
      uptime: os.uptime(),
      uptimeFormatted: formatUptime(os.uptime()),
      
      cpu: {
        model: cpus[0]?.model || 'Unknown',
        cores: cpus.length,
        usage: getCPUUsage(),
        loadAverage: os.loadavg()
      },
      
      memory: {
        total: totalMem,
        free: freeMem,
        used: usedMem,
        usagePercent: (usedMem / totalMem) * 100
      },
      
      node: {
        version: process.version,
        memoryUsage: process.memoryUsage()
      }
    }

    // Try to get PowerShell version
    try {
      const psVersion = await execPowerShell('$PSVersionTable.PSVersion.ToString()')
      const psEdition = await execPowerShell('$PSVersionTable.PSEdition')
      metrics.powershell = {
        version: psVersion,
        edition: psEdition
      }
    } catch {
      // PowerShell not available
    }

    // Try to get disk usage (Windows-specific)
    if (os.platform() === 'win32') {
      try {
        const diskInfo = await execPowerShell(`
          $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
          @{
            Total = $disk.Size
            Free = $disk.FreeSpace
          } | ConvertTo-Json
        `)
        const disk = JSON.parse(diskInfo)
        metrics.disk = {
          total: disk.Total,
          free: disk.Free,
          used: disk.Total - disk.Free,
          usagePercent: ((disk.Total - disk.Free) / disk.Total) * 100
        }
      } catch {
        // Disk info not available
      }
    }

    // Try to get process counts
    try {
      const processInfo = await execPowerShell(`
        @{
          pwsh = (Get-Process -Name pwsh -ErrorAction SilentlyContinue | Measure-Object).Count
          python = (Get-Process -Name python* -ErrorAction SilentlyContinue | Measure-Object).Count
          node = (Get-Process -Name node -ErrorAction SilentlyContinue | Measure-Object).Count
        } | ConvertTo-Json
      `)
      metrics.processes = JSON.parse(processInfo)
    } catch {
      // Process info not available
    }

    return NextResponse.json(metrics)
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : 'Unknown error' },
      { status: 500 }
    )
  }
}
