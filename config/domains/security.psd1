@{
    # ===================================================================
    # CERTIFICATE AUTHORITY - CA Configuration
    # ===================================================================
    CertificateAuthority     = @{
        CommonName    = 'default-lab-RootCA'
        ValidityYears = 5
        InstallCA     = $false
    }

    # ===================================================================
    # SECURITY - Security and Access Control
    # ===================================================================
    Security                 = @{
        CredentialStore        = 'LocalMachine'
        EncryptionType         = 'AES256'
        PasswordComplexity     = 'Medium'
        RequireSecureTransport = $true
        RequireAdminForInstall = $false
        EnforceExecutionPolicy = $false
        AllowUnsignedScripts   = $true
        MaxLoginAttempts       = 3
        SessionTimeout         = 3600
    }

    # ===================================================================
    # SSH KEY MANAGEMENT - SSH Key Generation and Management
    # ===================================================================
    SSHKeyManagement            = @{
        # Default key storage location
        KeyPath                  = if ($IsWindows) { "$env:USERPROFILE\.ssh" } else { "$env:HOME/.ssh" }

        # Default key type (RSA or ED25519)
        DefaultKeyType          = 'ED25519'

        # RSA key size (when RSA is used)
        RSAKeySize              = 4096

        # Key naming convention
        KeyNamingPattern        = 'id_{type}_{name}'

        # Security settings
        RequirePassphrase       = $false  # Set to $true for production
        AutoBackupKeys          = $true
        BackupLocation          = './library/ssh-keys-backup'

        # SSH agent integration
        UseSSHAgent             = $true
        AgentTimeout            = 300  # seconds
    }
}
