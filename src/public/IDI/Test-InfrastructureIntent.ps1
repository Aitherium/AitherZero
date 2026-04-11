#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Quick check if a prompt is infrastructure-related (for agent routing).

.DESCRIPTION
    Returns $true if the prompt matches infrastructure intent patterns.
    Uses the same patterns as IntentEngine's INTENT_PATTERNS[INFRASTRUCTURE]
    from AitherOS Pillar 1 "The Will".

    This function is used by:
    - Invoke-AitherAgent: Auto-routes infra intents to the IDI pipeline
    - Invoke-AitherInfra: Validates infrastructure intent before execution
    - External scripts: Quick intent classification without Genesis

    Pattern categories:
    - IaC tools: terraform, docker, kubernetes, helm
    - Cloud providers: aws, azure, gcp + specific services (ec2, rds, s3, etc.)
    - Infrastructure verbs: deploy, provision, spin up, tear down, scale
    - Orchestration: cluster, pod, namespace, container, serverless
    - IDI-specific: nuke resources, orphan cleanup, drift detection

.PARAMETER Prompt
    The natural language text to check for infrastructure intent.

.OUTPUTS
    [bool] True if the prompt matches infrastructure patterns.

.EXAMPLE
    Test-InfrastructureIntent -Prompt "Deploy 3 EC2 instances in us-east-1"
    # Returns: True

.EXAMPLE
    Test-InfrastructureIntent -Prompt "Explain this Python function"
    # Returns: False

.EXAMPLE
    if (Test-InfrastructureIntent -Prompt $UserInput) {
        Invoke-AitherInfra -Prompt $UserInput
    }
#>
function Test-InfrastructureIntent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Prompt
    )

    # Mirror IntentEngine.INTENT_PATTERNS[INFRASTRUCTURE] from
    # AitherOS/lib/faculties/IntentEngine.py (Pillar 1)
    $infraPatterns = @(
        # IaC tools
        '\bterraform\b'
        '\bdocker\b'
        '\bkubernetes\b'
        '\bk8s\b'
        '\bhelm\b'
        '\bansible\b'
        '\bpulumi\b'
        '\bcdk\b'

        # Cloud primitives
        '\binfra(structure)?\b'
        '\bcluster\b'
        '\bvm\b'
        '\bcontainer\b'
        '\bpod\b'
        '\bnamespace\b'
        '\bserverless\b'
        '\bload\s*balanc'
        '\bauto\s*scal'

        # AWS services
        '\bec2\b'
        '\brds\b'
        '\bs3\b'
        '\bvpc\b'
        '\belb\b'
        '\beks\b'
        '\becs\b'
        '\blambda\b'
        '\bfargate\b'
        '\bcloudfront\b'
        '\broute\s*53\b'
        '\biam\b.*\b(role|policy|user)\b'

        # Azure services
        '\bazure\b'
        '\baks\b'
        '\bazure\s+(vm|function|app\s+service|container)'

        # GCP services
        '\bgcp\b'
        '\bgke\b'
        '\bgcloud\b'
        '\bcloud\s+run\b'

        # Infrastructure verbs
        '\bdeploy\b'
        '\bprovision\b'
        '\bspin\s*up\b'
        '\btear\s*down\b'
        '\bscale\b.*\binstanc'
        '\bmigrat(e|ion)\b.*\b(server|db|cluster|infra)'

        # IDI-specific
        '\bnuke\b.*\bresource'
        '\borphan\b.*\bresource'
        '\bcleanup\b.*\binfra'
        '\bdrift\b.*\bdetect'
        '\bcost\b.*\b(project|estimat|analyz)'
        '\bidle\b.*\bresource'
    )

    foreach ($pattern in $infraPatterns) {
        if ($Prompt -match $pattern) {
            Write-Verbose "Infrastructure intent matched pattern: $pattern"
            return $true
        }
    }
    return $false
}
