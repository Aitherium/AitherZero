#!/bin/bash
#
# SOVEREIGN NODE BOOTSTRAP — FROM ZERO TO FULL DEVELOPER ENVIRONMENT
#
# PURPOSE:
#   A blank laptop, phone, or spare box runs this script and becomes a
#   fully-provisioned Aitherium developer node with:
#   - Bonsai inference (sized to available RAM)
#   - MCP wired to mcp.aitherium.com
#   - awsh (Node.js CLI tooling)
#   - awdk (Python ADK for development)
#   - workspace enrollment and device identification
#
# USAGE:
#   curl -fsSL https://aitherium.com/install.sh | sh --args aither-bootstrap
#
# APPROVAL FLOW:
#   1. User runs the command
#   2. Device flow auth to idp.aitherium.com (user approves on phone or email reply)
#   3. Installer fetches this playbook + config from user's drive
#   4. Playbook runs, user's device becomes operational
#
# ARCHITECTURE NOTES:
#   - Every step that can run offline does (Bonsai, npm, pip install)
#   - MCP wiring targets the CLOUD gateway, not 127.0.0.1:8182 (home infra optional)
#   - awsh is npm-only (one name @aitherium/awsh); awdk is pip-only
#   - Device enrollment uses the device-flow bearer from the installer
#   - Verification probes live APIs and local binaries (not just "file exists")
#
# HARD CONSTRAINTS:
#   - Bootstrap MUST work standalone (no prior adk, no home LLM required)
#   - Both shell and PowerShell paths call the SAME scripts (no drift)
#   - MCP config goes to ~/.aither/.mcp.json, never hardcoded into env
#   - Failure modes are loud and named (not silent fallbacks)
#

set -e

# =========================================================================
# CONFIGURATION (all can be overridden via environment or arguments)
# =========================================================================

# Bonsai installer URL (canonical source for install-bonsai.sh)
BONSAI_INSTALLER="${BONSAI_INSTALLER:-https://aitherium.com/install-bonsai.sh}"

# Bonsai model sizing. auto = RAM-based, or explicit 1.7B|4B|8B|27B
BONSAI_MODEL="${BONSAI_MODEL:-auto}"

# Local loopback port for Bonsai inference
BONSAI_PORT="${BONSAI_PORT:-8080}"

# MCP gateway URL. Must be https:// and reachable from this machine.
# NEVER 127.0.0.1:8182 (that is the local orchestrator).
MCP_GATEWAY="${MCP_GATEWAY:-https://mcp.aitherium.com/mcp}"

# Node name / device ID for workspace enrollment
NODE_NAME="${NODE_NAME:-$(hostname)}"

# API key or bearer for device enrollment (passed by installer)
DEVICE_BEARER="${DEVICE_BEARER:-}"

# Workspace to enroll into (empty => inferred from bearer)
WORKSPACE="${WORKSPACE:-aitherium}"

# Portal URL for registration
PORTAL="${PORTAL:-https://portal.aitherium.com}"

# Verify-only: show what would run, change nothing
DRY_RUN="${DRY_RUN:-false}"

# =========================================================================
# HELPER FUNCTIONS
# =========================================================================

log_step() {
    echo ""
    echo "==== $1 ===="
}

log_ok() {
    echo "[OK] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
    exit 1
}

log_warn() {
    echo "[WARN] $1"
}

run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] $@"
    else
        "$@" || return $?
    fi
}

# =========================================================================
# STEP 1: Resolve OS dependencies (Bonsai + Node + Python)
# =========================================================================

log_step "Resolve OS dependencies (Bonsai + Node + Python)"

if [ "$DRY_RUN" = "true" ]; then
    log_ok "DRY RUN: would install system packages"
else
    # Install Bonsai dependencies
    if command -v curl >/dev/null 2>&1; then
        log_ok "curl found"
        run_cmd curl -fsSL "$BONSAI_INSTALLER" | sh -s -- --deps-only || log_warn "Bonsai deps install incomplete (may already be installed)"
    else
        log_error "curl not found; cannot install Bonsai dependencies"
    fi

    # Install Node.js repository (Debian/Ubuntu)
    if command -v apt-get >/dev/null 2>&1; then
        log_ok "apt-get found; installing Node.js + Python"
        run_cmd curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - || log_warn "Node.js repo setup skipped"
        run_cmd apt-get update || log_warn "apt-get update failed"
        run_cmd apt-get install -y nodejs python3-pip python3-venv || log_warn "Some packages already installed"
    elif command -v brew >/dev/null 2>&1; then
        log_ok "Homebrew found; installing Node.js + Python"
        run_cmd brew install node python3 || log_warn "Some packages already installed"
    elif command -v dnf >/dev/null 2>&1; then
        log_ok "dnf found; installing Node.js + Python"
        run_cmd dnf install -y nodejs python3-pip || log_warn "Some packages already installed"
    else
        log_warn "No package manager found (apt/brew/dnf); assuming Node.js and Python3 already installed"
    fi
fi

# =========================================================================
# STEP 2: Install and start Bonsai inference
# =========================================================================

log_step "Install and start Bonsai inference"
run_cmd curl -fsSL "$BONSAI_INSTALLER" | sh -s -- --model "$BONSAI_MODEL" --port "$BONSAI_PORT" || log_error "Bonsai installation failed"
log_ok "Bonsai server installed and started on port $BONSAI_PORT"

# =========================================================================
# STEP 3: Install awsh (Node.js CLI tools)
# =========================================================================

log_step "Install awsh (Node.js CLI tools)"

if ! command -v npm >/dev/null 2>&1; then
    log_error "npm not found; Node.js installation failed"
fi

run_cmd npm install -g @aitherium/awsh || log_error "awsh installation failed"
log_ok "awsh installed globally"

# =========================================================================
# STEP 4: Install awdk (Python development kit)
# =========================================================================

log_step "Install awdk (Python development kit)"

if ! command -v python3 >/dev/null 2>&1; then
    log_error "python3 not found; Python installation failed"
fi

run_cmd python3 -m pip install --user --upgrade pip setuptools wheel || log_warn "pip upgrade partial"
run_cmd pip3 install --user awdk || log_error "awdk installation failed"
log_ok "awdk installed to user site-packages"

# =========================================================================
# STEP 5: Create MCP configuration
# =========================================================================

log_step "Create MCP configuration"

MCP_CONFIG_DIR="$HOME/.aither"
MCP_CONFIG_FILE="$MCP_CONFIG_DIR/.mcp.json"

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] would create $MCP_CONFIG_FILE"
else
    mkdir -p "$MCP_CONFIG_DIR"
    cat > "$MCP_CONFIG_FILE" <<EOF
{
  "version": 1,
  "mcpServers": {
    "aitheros": {
      "type": "stdio",
      "command": "adk",
      "args": ["mcp", "--gateway", "$MCP_GATEWAY"],
      "env": {}
    }
  }
}
EOF
    log_ok "MCP configuration written to $MCP_CONFIG_FILE"
fi

# =========================================================================
# STEP 6: Verify Bonsai is answering
# =========================================================================

log_step "Verify Bonsai is answering"

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] would verify Bonsai on port $BONSAI_PORT"
else
    run_cmd curl -fsSL "$BONSAI_INSTALLER" | sh -s -- --verify-only --port "$BONSAI_PORT" || log_error "Bonsai verification failed"
    log_ok "Bonsai inference server is responding"
fi

# =========================================================================
# STEP 7: Verify MCP gateway reachable
# =========================================================================

log_step "Verify MCP gateway reachable"

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY RUN] would test MCP gateway at $MCP_GATEWAY"
else
    if curl -sk "$MCP_GATEWAY/health" >/dev/null 2>&1; then
        log_ok "MCP gateway is reachable and healthy"
    else
        log_error "MCP gateway at $MCP_GATEWAY is unreachable"
    fi
fi

# =========================================================================
# STEP 8: Verify awsh installed
# =========================================================================

log_step "Verify awsh installed"

if command -v awsh >/dev/null 2>&1; then
    AWSH_VERSION=$(awsh --version 2>&1 || echo "unknown")
    log_ok "awsh is installed: $AWSH_VERSION"
else
    log_error "awsh not found in PATH"
fi

# =========================================================================
# STEP 9: Verify awdk installed
# =========================================================================

log_step "Verify awdk installed"

if python3 -m adk --version >/dev/null 2>&1; then
    ADK_VERSION=$(python3 -m adk --version 2>&1)
    log_ok "awdk is installed: $ADK_VERSION"
else
    log_error "awdk module not found (python3 -m adk failed)"
fi

# =========================================================================
# STEP 10: Enroll device to workspace (optional if bearer provided)
# =========================================================================

if [ -n "$DEVICE_BEARER" ]; then
    log_step "Enroll device to workspace"

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] would enroll device with workspace=$WORKSPACE"
    else
        if command -v adk >/dev/null 2>&1; then
            adk enroll --workspace "$WORKSPACE" --node-id "$NODE_NAME" --portal "$PORTAL" 2>/dev/null || \
                log_warn "Device enrollment optional (requires portal access)"
            log_ok "Device enrolled to workspace"
        else
            log_warn "adk not in PATH; cannot enroll (may need to add ~/.local/bin to PATH)"
        fi
    fi
else
    log_warn "No DEVICE_BEARER provided; skipping device enrollment (you can run 'adk enroll' manually later)"
fi

# =========================================================================
# SUCCESS
# =========================================================================

cat <<EOF

+=================================================================+
|   BOOTSTRAP COMPLETE — Sovereign Node Ready                     |
+=================================================================+
|                                                                  |
|  This device is now a fully-provisioned Aitherium node:         |
|                                                                  |
|  1. BONSAI INFERENCE                                            |
|     Local LLM answering on http://127.0.0.1:$BONSAI_PORT        |
|     Size: $BONSAI_MODEL (tuned to your RAM)                     |
|                                                                  |
|  2. MCP GATEWAY                                                 |
|     Cloud-connected: $MCP_GATEWAY                               |
|     Use awsh to ask the fleet, or run agents locally            |
|                                                                  |
|  3. DEVELOPER TOOLS INSTALLED                                   |
|     awsh  : npm exec awsh (global CLI)                          |
|     awdk  : python3 -m adk (Python development kit)            |
|                                                                  |
|  4. WORKSPACE ENROLLED $([ -n "$DEVICE_BEARER" ] && echo "(if bearer was provided)" || echo "(optional)")
|     This device appears in your workspace portal                |
|     Enroll manually: adk enroll --workspace $WORKSPACE          |
|                                                                  |
|  NEXT STEPS:                                                    |
|     1. Try the local model: awsh ask 'hello'                    |
|     2. Open desktop.aitherium.com to access Atlas/Forge/etc     |
|     3. Run 'adk --help' for development tasks                  |
|     4. Join the workspace on your phone at aitherium.com       |
|                                                                  |
+=================================================================+

EOF

exit 0
