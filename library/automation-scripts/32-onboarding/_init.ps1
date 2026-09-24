# Per-directory shim: scripts in this folder dot-source "$PSScriptRoot/_init.ps1",
# but the real _init.ps1 lives one level up (library/automation-scripts/_init.ps1)
# in BOTH the monorepo and the public repo. Without this file the dot-source fails,
# the module is never imported, and the script dies on its first Aither* call.
# Dot-sourcing chains keep the caller's scope.
. (Join-Path $PSScriptRoot '..' '_init.ps1')
