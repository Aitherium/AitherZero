#Requires -Version 7.0

<#
.SYNOPSIS
    Put a customer appliance repo on THIS machine, enroll it, and deploy it.
.DESCRIPTION
    The last mile of the appliance-onboard playbook, after the toolchain (python,
    git, gh, awdk) is installed and `adk login` has run:

      1. GitHub sign-in (`gh auth login --web`) when gh is not yet authenticated -
         appliance repos are private.
      2. Clone -Repo into -Dir, or fast-forward it when it is already there.
      3. `adk enroll` (`adk enroll --invite <code>` with -Invite) - registers the
         machine so the vendor can run its fixed list of
         signed commands (status, logs, redeploy). Already-enrolled is a no-op.
      4. `deploy/deploy.ps1` from the repo, which builds and starts the stack.

    Every step is idempotent; re-running is the way to finish a partial run.
.PARAMETER Repo
    GitHub repo as owner/name. Required.
.PARAMETER Dir
    Where to put it. Default: <home>/<repo name>.
.PARAMETER Enroll
    Run `adk enroll`. Default $true.
.PARAMETER Invite
    Employee invite code from an onboarding link (/setup-pc?i=<code>), or an awb1. invite
    token. When set, step 3 runs `adk enroll --invite <code>`, which enrolls this machine
    under the inviting org with the role the invite carries. Only the last four
    characters are ever printed.
.PARAMETER Deploy
    Run the repo's deploy/deploy.ps1. Default $true.
.PARAMETER DryRun
    Print what would run.
.EXAMPLE
    ./3266_Onboard-Appliance.ps1 -Repo Contoso/contoso-appliance
.NOTES
    Stage: Onboarding
    Dependencies: 1002_Install-Git, 1007_Install-GitHubCLI, 3260_Install-AWDK, 3263_Connect-Aitherium
    Tags: appliance, onboarding, enroll, deploy
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [string]$Dir = '',
    [object]$Enroll = $true,
    [object]$Deploy = $true,
    [string]$Invite = '',
    [switch]$DryRun
)

. "$PSScriptRoot/_init.ps1"

function ConvertTo-Flag([object]$v) { return -not ($v -in @($false, 'false', '$false', '0', 0, '', $null)) }
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    if ($DryRun) { Write-Host "[DRY RUN] $Exe $($Arguments -join ' ')"; return }
    Write-Host "+ $Exe $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments[0]) exited with code $LASTEXITCODE" }
}

if ($Repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { throw "-Repo must be owner/name, got '$Repo'" }
if (-not $Dir) { $Dir = Join-Path $HOME ($Repo.Split('/')[1]) }
$Invite = "$Invite".Trim()
if ($Invite -in @('$Invite', '$null')) { $Invite = '' }  # an unset playbook variable
if ($Invite -and $Invite -notmatch '^[2-9A-HJ-NP-TV-Z]{5}-?[2-9A-HJ-NP-TV-Z]{5}$' -and
    $Invite -cnotmatch '^awb1\.[A-Za-z0-9._~-]{16,2040}$') {
    throw "-Invite is not an invite code (expected ABCDE-FGHJK)"
}
$interactive = -not ($env:CI -eq 'true' -or $env:AITHERZERO_NONINTERACTIVE -eq '1')

if (Get-Command Update-AitherSessionPath -ErrorAction SilentlyContinue) { Update-AitherSessionPath }
foreach ($tool in 'git', 'gh') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found. Run the appliance-onboard playbook, which installs it." }
}

# 1. GitHub sign-in
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    if (-not $interactive) { throw "gh is not signed in and this session is non-interactive. Set GH_TOKEN, or run: gh auth login --web" }
    Invoke-Checked gh @('auth', 'login', '--web', '--git-protocol', 'https', '--hostname', 'github.com')
    Invoke-Checked gh @('auth', 'setup-git')
} else {
    Write-Host "GitHub: already signed in"
    # A GH_TOKEN sign-in (CI/CD) never ran setup-git, so a later `git pull` on a
    # private repo would prompt or fail; the credential helper is idempotent.
    Invoke-Checked gh @('auth', 'setup-git')
}

# 2. Clone or update
if (Test-Path (Join-Path $Dir '.git')) {
    Invoke-Checked git @('-C', $Dir, 'pull', '--ff-only')
} else {
    Invoke-Checked gh @('repo', 'clone', $Repo, $Dir)
}

# 3. Enroll
if (ConvertTo-Flag $Enroll) {
    $adk = Get-Command adk -ErrorAction SilentlyContinue
    if (-not $adk) { throw "adk not found. Run 32-onboarding/3260_Install-AWDK first." }
    if ($Invite) {
        # Never echo the code: it admits a person. Print its last four characters only.
        $hint = $Invite.Substring([Math]::Max(0, $Invite.Length - 4))
        if ($DryRun) {
            Write-Host "[DRY RUN] adk enroll --invite ...$hint"
        } else {
            Write-Host "+ adk enroll --invite ...$hint"
            # Interactive runs confirm the org the code belongs to; unattended runs
            # (CI/remote, no console to answer) pre-confirm with --yes.
            $enrollArgs = @('enroll', '--invite', $Invite)
            if (-not $interactive) { $enrollArgs += '--yes' }
            & $adk.Source @enrollArgs
            if ($LASTEXITCODE -ne 0) { throw "adk enroll --invite exited with code $LASTEXITCODE" }
        }
    } else {
        Invoke-Checked $adk.Source @('enroll')
    }
}

# 4. Deploy
if (ConvertTo-Flag $Deploy) {
    $deployScript = Join-Path $Dir 'deploy/deploy.ps1'
    if (-not $DryRun -and -not (Test-Path $deployScript)) { throw "$Repo has no deploy/deploy.ps1" }
    Invoke-Checked (Get-Process -Id $PID).Path @('-NoProfile', '-File', $deployScript)
}

Write-Host "`nAppliance ready in $Dir. Re-run this playbook any time; finished steps are skipped."
