#!/bin/bash
set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if .venv exists
if [ ! -d ".venv" ]; then
    echo "Virtual environment not found. Please run 0752_Setup-AgentVenv.ps1 or create it manually."
    # Auto-recovery if possible (assuming AitherZero env)
    # python3 -m venv .venv
    # ./.venv/bin/pip install -r requirements.txt
fi

# Run the agent
echo "Starting AitherZero local automation agent..."
./.venv/bin/python agent.py
