function Get-AitherProjectRegistryPath {
    $moduleRoot = Get-AitherModuleRoot
    return Join-Path $moduleRoot "AitherZero/config/projects.json"
}

