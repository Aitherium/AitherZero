#Requires -Version 7.0

<#
.SYNOPSIS
    Refresh $env:PATH in the CURRENT session from the persisted Machine + User values.

.DESCRIPTION
    A package manager (winget, choco, brew, apt) writes new bin directories to the
    persisted PATH, but the running PowerShell process keeps the PATH it started
    with. So a script that installs Node and then runs `Get-Command node` in the
    same session fails with "not found after installation" even though the
    install succeeded — measured 2026-09-12 on a blank Windows 11 box for
    Node, Git, gh and pwsh in turn.

    This rebuilds $env:PATH as Machine + User + (any entries that were only in
    the process PATH, e.g. added by a venv or an earlier step), de-duplicated,
    order preserved. On Linux/macOS there is no registry to re-read, so it only
    appends the well-known user/tool bin dirs that installers drop into when
    they exist on disk but are missing from PATH.

.PARAMETER PassThru
    Return the new PATH string.

.EXAMPLE
    Install-AitherPackage -Name nodejs -WingetId OpenJS.NodeJS.LTS
    Update-AitherSessionPath
    node --version

.OUTPUTS
    None, or System.String with -PassThru.
#>
function Update-AitherSessionPath {
    [CmdletBinding()]
    param(
        [switch]$PassThru
    )

    $sep = [IO.Path]::PathSeparator
    $before = @($env:PATH -split $sep | Where-Object { $_ })

    if ($IsWindows) {
        $machine = @([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split $sep | Where-Object { $_ })
        $user    = @([Environment]::GetEnvironmentVariable('PATH', 'User')    -split $sep | Where-Object { $_ })
        $merged  = $machine + $user + $before
    }
    else {
        # Installers on Unix write to shell rc files, not anywhere we can re-read.
        # Append the directories they conventionally use, when present on disk.
        $candidates = @(
            "$HOME/.local/bin"
            "$HOME/.npm-global/bin"
            "$HOME/.cargo/bin"
            '/opt/homebrew/bin'
            '/usr/local/bin'
            '/snap/bin'
        )
        # macOS `pip install --user` console scripts land in ~/Library/Python/<ver>/bin
        $candidates += @(Get-ChildItem "$HOME/Library/Python/*/bin" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        $merged = $before + @($candidates | Where-Object { Test-Path $_ })
    }

    # De-duplicate, first occurrence wins, case-insensitive on Windows.
    # Direct assignment on purpose: `$seen = if (...) { [HashSet]::new() }`
    # streams the set through the pipeline, which ENUMERATES it — an empty
    # set yields nothing and $seen ends up $null.
    $comparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $seen = [System.Collections.Generic.HashSet[string]]::new($comparer)
    $result = foreach ($p in $merged) {
        $trimmed = $p.TrimEnd('\', '/')
        if ($trimmed -and $seen.Add($trimmed)) { $p }
    }

    $env:PATH = ($result -join $sep)

    $added = @($result | Where-Object { $before -notcontains $_ })
    if ($added.Count -gt 0) {
        Write-Verbose "PATH refreshed; new entries: $($added -join ', ')"
    }

    if ($PassThru) { return $env:PATH }
}
