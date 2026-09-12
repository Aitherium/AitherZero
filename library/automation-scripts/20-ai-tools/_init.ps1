# Per-directory shim: scripts dot-source "$PSScriptRoot/_init.ps1" (the monorepo
# layout) while the real _init.ps1 lives one level up in the public repo. Both
# spellings must work, so forward to it. Dot-sourcing chains keep the caller's scope.
. (Join-Path $PSScriptRoot '..' '_init.ps1')
