#!/bin/bash
# Undo install.sh's system changes: the bridge's launchd service, its tailnet publication and the Mac app.
#
# Left in place: Pi, Prime Agent and DeepSeek Harness with their configuration and sessions (Open Codex stays
# their default provider); ~/.agent-remote (token, registry); Open Codex and its own login service
# (com.opencodex.proxy); any `setup/sync-remote.sh --watch` agent (remove it with `--unwatch`); and the tailnet
# routes of sites still published when the bridge stopped (`tailscale serve status` lists them).
set -uo pipefail

PORT="${AGENT_REMOTE_PORT:-7878}"
LABEL="dev.agentremote.bridge"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

ts="$(command -v tailscale || true)"
[ -z "$ts" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -n "$ts" ] && "$ts" serve --https="$PORT" off 2>/dev/null && echo "removed the tailnet publication on port $PORT"

rm -rf "$HOME/Applications/Shed.app" && echo "removed ~/Applications/Shed.app"
