#!/bin/bash
# Undo Shed's system changes on this Mac: the bridge's launchd service, its tailnet publication and the routes of
# the sites it published, every `setup/sync-remote.sh --watch` agent, and the Mac app.
#
# Left in place: Pi, Prime Agent and DeepSeek Harness with their configuration and sessions (Open Codex stays
# their default provider); ~/.agent-remote (token, registry); and Open Codex with its own login service
# (com.opencodex.proxy).
set -uo pipefail

PORT="${AGENT_REMOTE_PORT:-7878}"
LABEL="dev.agentremote.bridge"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped $LABEL"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

ts="$(command -v tailscale || true)"
[ -z "$ts" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -n "$ts" ] && "$ts" serve --https="$PORT" off 2>/dev/null && echo "removed the tailnet publication on port $PORT"

# The routes of the sites the bridge published, and only those: it recorded each one, and the serve configuration
# is shared with whatever else this Mac publishes. A record is a site's port, and the tailnet port it answers on
# (`served`) when its own was taken there. The bridge is stopped by now, so nothing publishes them again.
sites="$HOME/.agent-remote/sites.json"
if [ -n "$ts" ] && [ -f "$sites" ]; then
  ports="$(plutil -p "$sites" 2>/dev/null | awk '
    /"port" =>/ { port = $3 }
    /"served" =>/ { served = $3 }
    /^  }/ { if (served != "") print served; else if (port != "") print port; port = served = "" }')"
  # `off` also fails for a route that is already gone, so what is still published is read from the status, not
  # from how `off` ended. A route that stays, or a status that can't be read, keeps the record: it is the only
  # place that says which routes are Shed's, and running this again tries them again.
  for port in $ports; do
    "$ts" serve --https="$port" off 2>/dev/null && echo "removed the site route on port $port"
  done
  left=""
  if status="$("$ts" serve status 2>/dev/null)"; then
    for port in $ports; do
      printf '%s\n' "$status" | grep -Eq "^https://[^/ ]+:$port( |/|$)" && left="$left $port"
    done
  else
    left=" (unknown: tailscale gave no status)"
  fi
  if [ -z "$left" ]; then
    rm -f "$sites"
  else
    echo "still published:$left. Kept $sites; running this again tries them again." >&2
  fi
fi

# What keeps other Macs in step with this checkout.
for plist in "$HOME/Library/LaunchAgents"/dev.agentremote.sync.*.plist; do
  [ -e "$plist" ] || continue
  label="$(basename "$plist" .plist)"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  rm -f "$plist" && echo "stopped syncing ${label#dev.agentremote.sync.}"
done

rm -rf "$HOME/Applications/Shed.app" && echo "removed ~/Applications/Shed.app"
