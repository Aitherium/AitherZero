# AitherZero Docker Container Profile
# Auto-loads AitherZero module for interactive sessions

$env:AITHERZERO_ROOT = '/opt/aitherzero'
$env:AITHERZERO_MODULE_ROOT = '/opt/aitherzero/AitherZero'

if (Test-Path '/opt/aitherzero/AitherZero/AitherZero.psd1') {
    Import-Module '/opt/aitherzero/AitherZero/AitherZero.psd1' -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
}

Set-Location '/opt/aitherzero'
