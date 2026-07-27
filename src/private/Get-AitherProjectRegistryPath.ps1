function Get-AitherProjectRegistryPath {
    $moduleRoot = Get-AitherModuleRoot
    return Join-Path $moduleRoot "config/projects.json"
}

