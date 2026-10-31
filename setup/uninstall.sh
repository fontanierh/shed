#!/bin/bash
# Undo install.sh's system changes: the launchd service, the tailnet publication and the Mac app.
# Leaves Pi, Prime Agent, their configuration and sessions, and ~/.agent-remote (token, registry) in place.
set -uo pipefail

PORT="${AGENT_REMOTE_PORT:-7878}"
LABEL="dev.agentremote.bridge"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

ts="$(command -v tailscale || true)"
[ -z "$ts" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -n "$ts" ] && "$ts" serve --https="$PORT" off 2>/dev/null && echo "removed the tailnet publication on port $PORT"

rm -rf "$HOME/Applications/Shed.app" "$HOME/Applications/Agent Remote.app" && echo "removed ~/Applications/Shed.app"
