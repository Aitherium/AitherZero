@{
    Name        = "bootstrap-bonsai-device"
    Description = "Turn a personal device (phone Linux VM, laptop, spare box) into a Bonsai inference endpoint on its owner's workspace - dependencies resolved, no manual steps"
    Version     = "1.0.0"
    Author      = "AitherZero"
    Category    = "deploy"

    # ==========================================================================
    # WHY THIS EXISTS SEPARATELY FROM bootstrap-inference-node
    # ==========================================================================
    #
    # The fleet-node bootstrap playbook targets MANAGED nodes: it assumes SSH,
    # docker, a controller with adk already installed, and the control plane
    # running. None of that holds for the case here - a person's own phone or
    # laptop, reached by nobody, owned by them.
    #
    # It also does NOT resolve operating-system dependencies, and that gap is
    # what turned a real Pixel install into "the inference server will not run
    # on this system": the prebuilt llama.cpp binaries need libgomp, libstdc++
    # and libgcc_s, and a minimal Debian (which Android's Linux terminal is)
    # ships none of them.
    #
    # THE MANUAL STEPS THIS REPLACES, each previously typed by hand:
    #   sudo apt install -y libgomp1 libstdc++6 libgcc-s1
    #   curl -fsSL https://aitherium.com/install-bonsai.sh | sh
    #   adk login --api-key <key>
    #   adk enroll --portal https://portal.aitherium.com
    #   adk up --port 8080 --yes
    #
    # ==========================================================================
    # HARD CONSTRAINT - READ BEFORE "SIMPLIFYING" THIS
    # ==========================================================================
    #
    # The installer this drives MUST stay runnable standalone via
    #   curl -fsSL https://aitherium.com/install-bonsai.sh | sh
    # because the first device someone sets up has no pwsh, no AitherZero and
    # no config.psd1 on it. This playbook is the ORCHESTRATED path for devices
    # we already manage; it does not replace the one-paste path, and making the
    # public installer depend on AitherZero would break every stranger who is
    # not running it.
    #
    # Both paths call the SAME script with different verbs, so the dependency
    # logic cannot drift between them.
    #
    # ==========================================================================
    # ARCHITECTURE NOTE - GLIBC vs BIONIC
    # ==========================================================================
    #
    # Read from the ELF, not assumed:
    #   interpreter = /lib/ld-linux-aarch64.so.1   -> glibc
    #   RUNPATH     = $ORIGIN                      -> bundled .so resolve fine
    #
    # So these binaries run in Android 16's Linux terminal (a real Debian VM,
    # glibc) and CANNOT run under Termux (Android/bionic) at any price. On
    # Termux the installer routes to proot-distro instead of failing. No package
    # fixes bionic-vs-glibc, so do not try to add one.
    #
    # ==========================================================================
    # PSD1 CONVENTION - WHY EVERY VARIABLE IS IN Environment
    # ==========================================================================
    #
    # Import-PowerShellDataFile REJECTS "$Var" inside a double-quoted string
    # ("Cannot generate a PowerShell object for a ScriptBlock evaluating dynamic
    # expressions"). The first draft of this file interpolated parameters
    # directly into Command and would not parse at all. Parameters therefore
    # travel as single-quoted '$Param' placeholders in Environment - the same
    # convention bootstrap-inference-node.psd1 uses - and Command references
    # them as SHELL variables, which are expanded at run time by sh.
    # ==========================================================================

    Parameters = @{
        Model           = 'auto'    # auto | 1.7B | 4B | 8B | 27B  (auto sizes from RAM)
        Port            = '8080'    # loopback port the server listens on
        ApiKey          = ''        # portal API key - REQUIRED to enrol as YOUR endpoint
        Portal          = 'https://portal.aitherium.com'
        WithAgent       = $true     # install aither-adk and enrol the device
        StartAgent      = $false    # also run `adk up` (opt-in: it holds the terminal)
        InstallerUrl    = 'https://aitherium.com/install-bonsai.sh'
        DryRun          = $false
    }

    Prerequisites = @(
        "A glibc Linux, macOS or Windows target - NOT Termux (see the glibc note above)"
        "curl or wget on the target"
        "Network egress to github.com (binaries) and huggingface.co (weights)"
        "A portal API key if the device should join YOUR workspace rather than nothing"
    )

    Sequence = @(
        @{
            Name        = "Resolve OS dependencies"
            Description = "Enumerate every missing shared library via ldd and install it - the step whose absence produced 'will not run on this system'"
            Command     = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --deps-only"'
            Environment = @{
                BONSAI_INSTALLER = '$InstallerUrl'
            }
            # Fail hard. Everything after this needs a binary that actually execs,
            # and continuing would repeat the original defect: failing later, after
            # a multi-GB download, with a worse message.
            ContinueOnError = $false
        }

        @{
            Name        = "Install and start Bonsai"
            Description = "Fetch the prebuilt server and ternary weights sized for this hardware, serve on loopback, and prove it ANSWERS rather than merely listens"
            Command     = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --model $BONSAI_MODEL --port $BONSAI_PORT"'
            Environment = @{
                BONSAI_INSTALLER = '$InstallerUrl'
                BONSAI_MODEL     = '$Model'
                BONSAI_PORT      = '$Port'
            }
            ContinueOnError = $false
        }

        @{
            Name        = "Attach this device to the owner's workspace"
            Description = "Install aither-adk into its own venv (Debian 12+ is PEP 668) and enrol this device as an endpoint"
            # NO API KEY, NO ENROLMENT. adk falls back to the tenant 'personal' when
            # it has no identity, registering the device somewhere the owner cannot
            # see while reporting success. Skipping is correct; guessing is not.
            Condition   = '$WithAgent -eq $true -and $ApiKey -ne ""'
            Command     = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --model $BONSAI_MODEL --port $BONSAI_PORT --with-adk --api-key $BONSAI_KEY --portal $BONSAI_PORTAL"'
            Environment = @{
                BONSAI_INSTALLER = '$InstallerUrl'
                BONSAI_MODEL     = '$Model'
                BONSAI_PORT      = '$Port'
                BONSAI_KEY       = '$ApiKey'
                BONSAI_PORTAL    = '$Portal'
            }
            ContinueOnError = $true
        }

        @{
            Name        = "Start the agent"
            Description = "Run the adk agent against the local model so it joins the owner's fleet"
            # Opt-in: `adk up` holds the foreground, which is wrong as a default
            # inside an orchestrated run.
            Condition   = '$StartAgent -eq $true -and $ApiKey -ne ""'
            Command     = 'sh -c "$HOME/.aitherium/bonsai/adk-venv/bin/adk up --port $BONSAI_PORT --yes"'
            Environment = @{
                BONSAI_PORT = '$Port'
            }
            ContinueOnError = $true
        }

        @{
            Name        = "Verify the endpoint answers"
            Description = "Ask the model a question over the local API - a listening port is not a working model"
            # Calls the installer's own --verify-only rather than inlining curl and a
            # JSON body. Shell quoting inside declarative data is what broke the first
            # draft of this file.
            Command     = 'sh -c "curl -fsSL $BONSAI_INSTALLER | sh -s -- --verify-only --port $BONSAI_PORT"'
            Environment = @{
                BONSAI_INSTALLER = '$InstallerUrl'
                BONSAI_PORT      = '$Port'
            }
            ContinueOnError = $false
        }
    )

    # What a human must check afterwards that no probe here can see.
    PostConditions = @(
        "Android Linux terminal only: port forwarding for the chosen port must be enabled in the Terminal app, or the phone's browser cannot reach the server - the VM and Android do not share a loopback interface."
        "aitherium.com finds the endpoint by probing 127.0.0.1 from the page; loopback is a browser secure-context exception, so an HTTPS page may call it."
        "The server binds 127.0.0.1 deliberately. Binding 0.0.0.0 would publish an unauthenticated inference server to the whole network."
    )
}
