#!/usr/bin/env pwsh

Write-Host ''
Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '║                    🚀 AitherZero Container                   ║' -ForegroundColor Cyan
Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''
Write-Host '✅ Ready to use!' -ForegroundColor Green
Write-Host ''
Write-Host '💡 Quick commands:' -ForegroundColor Cyan
Write-Host '   Get-Command -Module AitherZero - List all commands' -ForegroundColor White
Write-Host '   AitherZero Bootstrap             - Launch interactive menu' -ForegroundColor White
Write-Host '   aitherzero                   - Same as above (global cmd)' -ForegroundColor Gray
Write-Host ''
Write-Host '📍 Working directory: /opt/aitherzero' -ForegroundColor Gray
Write-Host '📦 Module: ' -NoNewline -ForegroundColor Gray

if (Get-Module AitherZero) {
    Write-Host 'Loaded (' -NoNewline -ForegroundColor Green
    Write-Host (Get-Module AitherZero).Version -NoNewline -ForegroundColor Green
    Write-Host ')' -ForegroundColor Green
} else {
    Write-Host 'Not loaded - run: Import-Module /opt/aitherzero/AitherZero/AitherZero.psd1' -ForegroundColor Yellow
}

Write-Host ''

# Keep the container running
while ($true) {
    Start-Sleep 3600
}
