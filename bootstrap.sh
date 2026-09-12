#!/bin/sh
# AitherZero one-paste bootstrap for Linux / macOS / Termux.
#
#   curl -fsSL https://raw.githubusercontent.com/Aitherium/AitherZero/main/bootstrap.sh | sh
#   curl -fsSL .../bootstrap.sh | sh -s -- --playbook node-onboard --var Token=<tok>
#   AITHERZERO_PLAYBOOK=none  curl -fsSL .../bootstrap.sh | sh
#
# Options: --playbook <name>  --var Key=Value (repeatable)  --ref <git-ref>
#          --path <dir>  --update  --dry-run  --non-interactive  --native
#
# Two lanes, decided by what the host can run:
#
#   pwsh lane (Linux glibc, macOS): install PowerShell 7 with the distro's
#     package manager, fetch bootstrap.ps1 and hand off. The playbook engine
#     does the rest — this file knows nothing about the toolchain.
#
#   native lane (Termux / Android, or --native): pwsh needs glibc and Termux
#     is bionic, so PowerShell cannot run here. This lane performs the same
#     steps the dev-workstation playbook defines, with `pkg`. It is the ONE
#     place the playbook's step list is duplicated; keep it in sync with
#     library/playbooks/dev-workstation.psd1 and say so in the PR when you
#     change either.
#
# POSIX sh only — no bashisms; Termux's default is bash but Alpine's is ash.

set -eu

# Never stop the user with "Feature X is disabled - enable?" (see bootstrap.ps1).
export AITHERZERO_AUTOENABLE=1

REPO="Aitherium/AitherZero"
PLAYBOOK="${AITHERZERO_PLAYBOOK:-dev-workstation}"
REF="${AITHERZERO_REF:-main}"
INSTALL_PATH="${AITHERZERO_ROOT:-$HOME/.aitherzero}"
NATIVE=0
DRYRUN=0
EXTRA_ARGS=""
VARS_JSON=""

# --var Key=Value -> {"Key":"Value",...}; bootstrap.ps1 reads it from
# AITHERZERO_VARIABLES_JSON (the same channel its own 5.1 -> pwsh re-exec uses).
add_var() {
  k="${1%%=*}"; v="${1#*=}"
  [ -n "$k" ] && [ "$k" != "$1" ] || { echo "--var expects Key=Value, got: $1" >&2; exit 2; }
  v="$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  VARS_JSON="${VARS_JSON:+$VARS_JSON,}\"$k\":\"$v\""
}

while [ $# -gt 0 ]; do
  case "$1" in
    --playbook) PLAYBOOK="$2"; shift 2 ;;
    --var)      add_var "$2"; shift 2 ;;
    --ref)      REF="$2"; shift 2 ;;
    --path)     INSTALL_PATH="$2"; shift 2 ;;
    --native)   NATIVE=1; shift ;;
    --dry-run)  DRYRUN=1; shift ;;
    --update)   EXTRA_ARGS="$EXTRA_ARGS -Update"; shift ;;
    --non-interactive) EXTRA_ARGS="$EXTRA_ARGS -NonInteractive"; export AITHERZERO_NONINTERACTIVE=1; shift ;;
    -h|--help)
      sed -n '2,28p' "$0" 2>/dev/null || echo "see header of bootstrap.sh"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$VARS_JSON" ]; then export AITHERZERO_VARIABLES_JSON="{$VARS_JSON}"; fi

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m    %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRYRUN" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi; }

# sudo only when needed and available (Termux and root have neither need).
SUDO=""
if [ "$(id -u)" != 0 ] && has sudo; then SUDO="sudo"; fi

# ── host detection ───────────────────────────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo unknown)"
IS_TERMUX=0
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux/files/usr ]; then IS_TERMUX=1; fi
if [ "$IS_TERMUX" = 1 ]; then NATIVE=1; fi

# ── native lane (Termux) ─────────────────────────────────────────────────────
# Mirrors library/playbooks/dev-workstation.psd1: python, git, node, awdk, awsh.
if [ "$NATIVE" = 1 ]; then
  step "native lane ($( [ "$IS_TERMUX" = 1 ] && echo Termux || echo requested )) — PowerShell cannot run here"
  if [ "$PLAYBOOK" != "dev-workstation" ] && [ "$PLAYBOOK" != "none" ]; then
    die "only the dev-workstation playbook has a native lane; '$PLAYBOOK' needs pwsh"
  fi

  if [ "$IS_TERMUX" = 1 ]; then
    PKG="pkg install -y"
    # rust/clang/libxml2/libxslt: awdk pulls cryptography + lxml, which have no
    # Termux wheels and build from source.
    step "packages (pkg)"
    run pkg update -y
    run $PKG python git nodejs-lts rust clang make libxml2 libxslt openssl
  elif has apt-get; then
    step "packages (apt)"
    run $SUDO apt-get update -y
    run $SUDO apt-get install -y python3 python3-pip python3-venv git curl ca-certificates
    # Debian/Ubuntu's own `nodejs` is v18 (measured: ubuntu:24.04); awsh needs
    # Node 20+ (`styleText` from node:util). Use NodeSource's 20.x repo.
    if ! node --version 2>/dev/null | grep -Eq '^v(2[0-9]|[3-9][0-9])'; then
      run sh -c "curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO bash -"
      run $SUDO apt-get install -y nodejs
    fi
  elif has dnf; then
    step "packages (dnf)"
    run $SUDO dnf install -y python3 python3-pip git nodejs npm curl
  elif has apk; then
    step "packages (apk)"
    run $SUDO apk add --no-cache python3 py3-pip git nodejs npm curl
  elif has brew; then
    step "packages (brew)"
    run brew install python git node
  else
    die "no supported package manager (pkg/apt/dnf/apk/brew)"
  fi

  step "awdk (adk)"
  run python3 -m pip install --upgrade --user "awdk[shell,platform,node]" \
    || run python3 -m pip install --upgrade --user --break-system-packages "awdk[shell,platform,node]"
  USER_BIN="$(python3 -c 'import site; print(site.USER_BASE)')/bin"
  case ":$PATH:" in *":$USER_BIN:"*) ;; *) export PATH="$USER_BIN:$PATH"; warn "add to your shell rc: export PATH=\"$USER_BIN:\$PATH\"" ;; esac

  step "awsh"
  # @aitherium/awsh, NOT @aitherium/shell-cli (stale; ships no `awsh` bin).
  run npm install -g @aitherium/awsh
  NPM_BIN="$(npm prefix -g)/bin"
  case ":$PATH:" in *":$NPM_BIN:"*) ;; *) export PATH="$NPM_BIN:$PATH" ;; esac

  step "verify"
  [ "$DRYRUN" = 1 ] && exit 0
  fail=0
  for t in python3 git node npm adk awsh; do
    if has "$t"; then ok "$t  $(command -v "$t")"; else warn "$t  MISSING"; fail=1; fi
  done
  [ "$fail" = 0 ] || die "some tools are missing (see above)"
  adk status || true
  awsh --version
  ok "done. next: adk login, then adk quickstart (local GPU) or adk quickstart --cloud; awsh to chat."
  exit 0
fi

# ── pwsh lane ────────────────────────────────────────────────────────────────
step "PowerShell 7+"
if has pwsh; then
  ok "pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo present)"
else
  case "$OS" in
    Darwin)
      has brew || die "Homebrew not found. Install it from https://brew.sh, then re-run."
      run brew install --cask powershell ;;
    Linux)
      if has apt-get; then
        # Microsoft's repo carries every supported Ubuntu/Debian release.
        run $SUDO apt-get update -y
        run $SUDO apt-get install -y wget apt-transport-https software-properties-common curl
        . /etc/os-release
        DEB="packages-microsoft-prod.deb"
        run sh -c "curl -fsSL https://packages.microsoft.com/config/${ID}/${VERSION_ID}/${DEB} -o /tmp/${DEB}"
        run $SUDO dpkg -i "/tmp/${DEB}"
        run $SUDO apt-get update -y
        run $SUDO apt-get install -y powershell
      elif has dnf; then
        run $SUDO rpm --import https://packages.microsoft.com/keys/microsoft.asc
        run sh -c "curl -fsSL https://packages.microsoft.com/config/rhel/9/prod.repo | $SUDO tee /etc/yum.repos.d/microsoft.repo >/dev/null"
        run $SUDO dnf install -y powershell
      elif has snap; then
        run $SUDO snap install powershell --classic
      elif has apk; then
        die "Alpine: PowerShell has no apk package; use --native or install pwsh manually (https://aka.ms/pwsh-alpine), then re-run."
      else
        die "no supported package manager for pwsh; install PowerShell 7 manually (https://aka.ms/pwsh) or use --native"
      fi ;;
    *) die "unsupported OS: $OS" ;;
  esac
  has pwsh || die "pwsh still not on PATH after install; open a new shell and re-run"
fi

step "hand off to bootstrap.ps1"
[ "$DRYRUN" = 1 ] && EXTRA_ARGS="$EXTRA_ARGS -DryRun"
if [ -f "$INSTALL_PATH/bootstrap.ps1" ]; then
  PS1_PATH="$INSTALL_PATH/bootstrap.ps1"
else
  PS1_PATH="$(mktemp -t aitherzero-bootstrap.XXXXXX).ps1"
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/bootstrap.ps1" -o "$PS1_PATH"
fi
# shellcheck disable=SC2086
exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$PS1_PATH" -Playbook "$PLAYBOOK" -InstallPath "$INSTALL_PATH" -Ref "$REF" $EXTRA_ARGS
