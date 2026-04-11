/**
 * API Route: Health Check
 * 
 * Simple health endpoint for monitoring
 */

import { NextResponse } from 'next/server'

export async function GET() {
  return NextResponse.json({
    status: 'healthy',
    service: 'AitherVeil-WebDash',
    timestamp: new Date().toISOString(),
    version: '1.0.0'
  })
}
