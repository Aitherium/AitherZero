#Requires -Version 7.0
# StrictMode-safe member access.
#
# Under `Set-StrictMode -Version Latest` (PS 7+), accessing a MISSING key of a
# hashtable OR a missing property of an object via dot notation THROWS
# ("property X cannot be found"). AitherZero config/manifest data are hashtables
# with many optional sections (Automation, Services, Options, ...), so bare
# `$config.Automation.Foo` is unsafe. Use this to read optional members safely:
# returns the value if present, else $null. Chain it for nested access.
#
# WHY THIS LIVES IN public/ AND NOT private/ (D-844 - do not move it back).
#   Every automation script dot-sources `library/automation-scripts/_init.ps1`,
#   which runs `Import-Module <AitherZero.psd1> -Force`. `-Force` REMOVES and
#   re-imports the module - including while `Invoke-AitherPlaybook` is mid-run
#   executing a step. From that moment the still-executing runner belongs to a
#   session state that no longer exists, so its PRIVATE helpers are gone, while
#   exported functions still resolve through the global scope. That is why the
#   runner died with "The term 'Get-AitherMember' is not recognized" at the
#   START of the step AFTER the first step that ran a script - earlier steps
#   succeeded, then the loop's very first statement failed.
#   Exporting makes this helper survive the re-import. The `-Force` itself is
#   the underlying root cause and is tracked separately (D-848).
function Get-AitherMember {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]$Object,
        [Parameter(Position = 1, Mandatory)][string]$Name
    )
    # The body MUST live in a `process` block. The parameter declares
    # ValueFromPipeline, but without one PowerShell runs the body once, in the
    # end block, with $Object holding only the LAST piped item - so
    # `$configs | Get-AitherMember -Name 'x'` silently returned a single value
    # instead of one per input, and every earlier item was dropped without a
    # word. Harmless while this was private and only ever called positionally;
    # it became a real trap the moment the function was exported (D-844).
    # (`$objs | Get-AitherMember 'x'` is still an error, correctly: piped, the
    # positional slot 0 is taken by the pipeline object, so a bare 'x' cannot
    # bind to -Name. Pass -Name explicitly when piping.)
    process {
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }
}
