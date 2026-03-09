# =============================================================================
# AitherOS GCP Destroy Playbook
# =============================================================================
# Usage: Invoke-AitherPlaybook -Name destroy-gcp -Parameters @{ProjectId="xxx"}
# =============================================================================

@{
    Name        = "destroy-gcp"
    Description = "Destroy AitherOS deployment on Google Cloud Platform"
    Author      = "Aither"
    Version     = "1.0.0"

    # Parameters
    Parameters = @{
        ProjectId   = ""              # REQUIRED
        Environment = "dev"
    }

    # Confirmation prompt
    RequiresConfirmation = $true
    ConfirmationMessage  = "This will DESTROY all AitherOS resources in GCP. Are you sure?"

    # Scripts to execute
    Scripts = @(
        @{
            Path        = "0831_Destroy-AitherGCP.ps1"
            Description = "Destroy GCP resources"
            Required    = $true
            Parameters  = @{
                ProjectId   = '${ProjectId}'
                Environment = '${Environment}'
                ShowOutput  = $true
            }
        }
    )

    OnSuccess = @"
═══════════════════════════════════════════════════════════════
  ✅ AitherOS Destroyed Successfully!
═══════════════════════════════════════════════════════════════

Resources have been removed from GCP.
State bucket preserved for safety.
"@
}
