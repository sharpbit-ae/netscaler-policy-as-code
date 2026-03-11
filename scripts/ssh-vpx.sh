#!/usr/bin/env bash
# ssh-vpx.sh — sshpass replacement using expect for VPX SSH commands
# Handles keyboard-interactive auth with long prompts that sshpass cannot.
# Usage: ssh-vpx.sh PASSWORD NSIP COMMAND...
set -euo pipefail

PASSWORD="${1:?Usage: $0 PASSWORD NSIP COMMAND...}"
NSIP="${2:?Missing NSIP}"
shift 2
CMD="$*"

if [[ -z "$CMD" ]]; then
    echo "ERROR: No command specified" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pass values via environment to avoid quote escaping issues
export _SSH_VPX_PASS="$PASSWORD"
export _SSH_VPX_IP="$NSIP"
export _SSH_VPX_CMD="$CMD"

exec expect "$SCRIPT_DIR/ssh-vpx.exp"
