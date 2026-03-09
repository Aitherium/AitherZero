@{
    Name            = 'my-plugin'
    Version         = '0.1.0'
    Description     = 'A template plugin for AitherZero'
    Author          = 'Your Name'
    URL             = ''

    # Configuration overlay — merged on top of base config.psd1
    # Set to $null or remove if no config overlay needed
    ConfigOverlay   = 'config/plugin.psd1'

    # Additional script directories to register with the script engine
    # Scripts are discovered recursively and added to Invoke-AitherScript
    ScriptPaths     = @(
        'scripts/'
    )

    # Additional PowerShell function files to dot-source
    # Each .ps1 file should contain one function
    FunctionPaths   = @(
        'functions/'
    )

    # Playbook directories to register
    PlaybookPaths   = @(
        'playbooks/'
    )

    # Minimum AitherZero version required
    MinimumVersion  = '3.0.0'

    # Other plugins this depends on (by name)
    RequiredPlugins = @()
}
