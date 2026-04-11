# AitherZero Module Loader
# Auto-loads functions from src/public and src/private

\ = Get-ChildItem -Path (Join-Path \/workspaces/AitherZero/AitherZero 'src/public') -Filter '*.ps1' -Recurse
\ = Get-ChildItem -Path (Join-Path \/workspaces/AitherZero/AitherZero 'src/private') -Filter '*.ps1' -Recurse

foreach (\ in \) {
    . \.FullName
}

foreach (\ in \) {
    . \.FullName
    Export-ModuleMember -Function \.BaseName
}
