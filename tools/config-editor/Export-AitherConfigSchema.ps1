#Requires -Version 7.0
<#
.SYNOPSIS
  Generate a config schema from the AitherZero automation-script inventory.

.DESCRIPTION
  Walks every automation script (public AND private — whatever is present under
  -ScriptRoot), extracts each script's configurable surface via the PowerShell AST,
  and emits a single config-schema.json that the Config Builder renders. This is what
  makes config.psd1 extensible: drop a new *.ps1 with a param() block into the inventory
  and its settings appear in the editor automatically — no hand-editing a schema.

  For each script it captures, per parameter:
    name, type (mapped: string/enum/number/bool/array), ValidateSet options (enum),
    Mandatory, default value, and the .PARAMETER help text.
  It also records which config.psd1 keys the script reads ($Config.X / $config.X),
  so the editor knows the config-key ⇄ script binding.

.PARAMETER ScriptRoot
  Root folder of the numbered automation scripts (NN-category/NNNN_Name.ps1).
  Default: the AitherZero library/automation-scripts folder relative to this file.

.PARAMETER PlaybookRoot
  Optional folder of playbook definitions (*.psd1 / *.yaml / *.json) to include.

.PARAMETER OutFile
  Where to write the schema JSON. Default: ./config-schema.json next to this script.

.EXAMPLE
  ./Export-AitherConfigSchema.ps1
  ./Export-AitherConfigSchema.ps1 -ScriptRoot 'D:\my-private\automation-scripts' -OutFile private-schema.json
#>
[CmdletBinding()]
param(
  [string]$ScriptRoot,
  [string]$PlaybookRoot,
  [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
if (-not $ScriptRoot) {
  $ScriptRoot = Resolve-Path (Join-Path $here '..' '..' 'library' 'automation-scripts') -ErrorAction SilentlyContinue
}
if (-not $ScriptRoot -or -not (Test-Path $ScriptRoot)) {
  throw "ScriptRoot not found. Pass -ScriptRoot <path to automation-scripts>."
}
# Absolute — so a script's FullName strips cleanly to its category-relative path.
$ScriptRoot = (Resolve-Path -LiteralPath $ScriptRoot).Path
if (-not $OutFile) { $OutFile = Join-Path $here 'config-schema.json' }

function Map-Type {
  param([string]$TypeName, [bool]$HasEnum)
  if ($HasEnum) { return 'e' }
  switch -Regex ($TypeName) {
    'SwitchParameter|Boolean|Bool' { 'b'; break }
    'Int|Double|Decimal|Single|Byte|Long' { 'n'; break }
    '\[\]|Array|Collection|List' { 'a'; break }
    default { 's' }
  }
}

# Parse comment-based help (.SYNOPSIS + .PARAMETER <name>) from the script text.
function Get-Help {
  param([string]$Text)
  $syn = ''
  if ($Text -match '(?ms)\.SYNOPSIS\s*\r?\n\s*(.+?)(\r?\n\s*\.[A-Z]|\r?\n\s*#>)') { $syn = ($Matches[1].Trim() -split '\r?\n')[0].Trim() }
  $ph = @{}
  foreach ($m in [regex]::Matches($Text, '(?ms)\.PARAMETER\s+(\w+)\s*\r?\n\s*(.+?)(?=\r?\n\s*\.[A-Z]|\r?\n\s*#>)')) {
    $ph[$m.Groups[1].Value] = ($m.Groups[2].Value.Trim() -split '\r?\n')[0].Trim()
  }
  [pscustomobject]@{ Synopsis = $syn; Params = $ph }
}

$scripts = @()
$files = Get-ChildItem -Path $ScriptRoot -Recurse -Filter '*.ps1' -File |
  Where-Object { $_.FullName -notmatch '[\\/]_archive[\\/]' } | Sort-Object FullName
foreach ($file in $files) {
  $text = Get-Content -LiteralPath $file.FullName -Raw
  $tokens = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errs)
  $pb = $ast.ParamBlock
  # Prefer a top-level param() block; else the first function's params.
  if (-not $pb) {
    $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -First 1
    if ($fn -and $fn.Body.ParamBlock) { $pb = $fn.Body.ParamBlock }
  }

  $help = Get-Help -Text $text
  $params = @()
  if ($pb) {
    foreach ($p in $pb.Parameters) {
      $name = $p.Name.VariablePath.UserPath
      $enum = @(); $mand = $false
      foreach ($a in $p.Attributes) {
        $an = $a.TypeName.Name
        if ($an -eq 'ValidateSet') { $enum = @($a.PositionalArguments | ForEach-Object { $_.Value }) }
        if ($an -eq 'Parameter') { foreach ($na in $a.NamedArguments) { if ($na.ArgumentName -eq 'Mandatory' -and -not $na.ExpressionOmitted) { $mand = $true } } }
      }
      $tname = if ($p.StaticType) { $p.StaticType.Name } else { 'Object' }
      $def = if ($p.DefaultValue) { $p.DefaultValue.Extent.Text.Trim("'`"") } else { $null }
      $params += [ordered]@{
        name = $name
        type = Map-Type -TypeName $tname -HasEnum ([bool]$enum.Count)
        enum = @($enum)
        default = $def
        mandatory = $mand
        help = if ($help.Params.ContainsKey($name)) { $help.Params[$name] } else { '' }
      }
    }
  }

  # config.psd1 keys the script reads. Two patterns:
  #   direct : $Config.Section.Key
  #   alias  : $infra = $config.Infrastructure ; $infra.VM.MemoryGB  (very common — ~85 scripts)
  $cfgKeys = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($m in [regex]::Matches($text, '\$[Cc]onfig(?:uration)?\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)+)')) {
    [void]$cfgKeys.Add($m.Groups[1].Value)
  }
  # Resolve one level of local alias: capture `$x = $config.Some.Path`, then rewrite every
  # `$x.Rest` read to the full `Some.Path.Rest` config key.
  $aliases = @{}
  foreach ($m in [regex]::Matches($text, '\$(\w+)\s*=\s*\$[Cc]onfig(?:uration)?\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*)')) {
    $al = $m.Groups[1].Value
    if ($al -notmatch '^(?i)config(uration)?$') { $aliases[$al] = $m.Groups[2].Value }
  }
  foreach ($al in $aliases.Keys) {
    $base = $aliases[$al]
    [void]$cfgKeys.Add($base)  # the subtree the alias points at is itself a read
    foreach ($m in [regex]::Matches($text, ('\$' + [regex]::Escape($al) + '\.((?:[A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)*)'))) {
      [void]$cfgKeys.Add("$base.$($m.Groups[1].Value)")
    }
  }

  $rel = $file.FullName.Substring($ScriptRoot.Length).TrimStart('\','/')
  # A script directly under ScriptRoot has no category folder — bucket it as 'misc'
  # instead of letting its filename masquerade as a category.
  $parts = $rel -split '[\\/]'
  $category = if ($parts.Count -gt 1) { $parts[0] } else { 'misc' }
  $num = if ($file.BaseName -match '^(\d{3,4})') { $Matches[1] } else { '' }
  $nm = ($file.BaseName -replace '^\d{3,4}[_-]?', '')

  # Only include scripts that expose a configurable surface (params or config keys).
  # Wrap arrays with @(...) at assignment so ConvertTo-Json keeps 1-element arrays as
  # JSON arrays (it otherwise collapses a lone element to a scalar — consumers then
  # can't tell a 1-item list from a string). Sorted for stable diffs.
  if ($params.Count -or $cfgKeys.Count) {
    $sortedKeys = @($cfgKeys | Sort-Object)
    $scripts += [ordered]@{
      id = $num; name = $nm; category = $category; file = $rel
      synopsis = $help.Synopsis
      params = @($params)
      configKeys = $sortedKeys
    }
  }
}

# Playbooks (optional)
$playbooks = @()
if ($PlaybookRoot -and (Test-Path $PlaybookRoot)) {
  foreach ($pf in Get-ChildItem -Path $PlaybookRoot -Recurse -Include '*.psd1','*.yaml','*.yml','*.json' -File) {
    $playbooks += [ordered]@{ name = $pf.BaseName; file = $pf.Name }
  }
}

# Group by the hashtable's 'category' KEY via a script block — Group-Object -Property
# 'category' can't read a key off an [ordered]@{} (no such NoteProperty), so every script
# would collapse into one null group. @($catCounts) forces an array even for 0/1 groups.
$catCounts = @($scripts | Group-Object { $_.category } |
  ForEach-Object { [ordered]@{ category = $_.Name; scripts = $_.Count } })
$schema = [ordered]@{
  # Record only the LEAF, never the absolute path. This field is committed into
  # the published config-schema.json, and an absolute path leaks the generating
  # machine's layout and username into a public artifact (the shipped copy read
  # "C:\Users\<name>\AppData\Local\Temp\...").
  generatedFrom = (Split-Path $ScriptRoot -Leaf)
  scriptCount = $scripts.Count
  categories = $catCounts
  scripts = $scripts
  playbooks = $playbooks
}
$schema | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutFile -Encoding utf8
Write-Host "Wrote $OutFile — $($scripts.Count) scripts with a configurable surface, $($catCounts.Count) categories." -ForegroundColor Green
