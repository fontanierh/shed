#!/bin/bash
# Keep the bridge on another Mac in step with this checkout: build it here and sign it with this Mac's certificate
# (setup/lib/sign-bridge.sh), copy it over SSH, and swap it in (restarting its launchd service) only when the code
# changed. A Mac of another architecture builds it from the copied source instead, unsigned. The other Mac needs
# setup/install.sh run once, and SSH from this Mac by key.
#
#   setup/sync-remote.sh user@host [--watch | --unwatch]
#
#   --watch     also install a launchd agent here that syncs every 5 minutes, and now
#   --unwatch   remove that agent
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?usage: setup/sync-remote.sh user@host [--watch | --unwatch]}"
HOST="${TARGET#*@}"
LABEL="dev.agentremote.sync.$HOST"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/.agent-remote/remotes/$HOST.hash"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

case "${2:-}" in
  --watch)
    mkdir -p "$(dirname "$PLIST")" "$HOME/.agent-remote/logs"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$ROOT/setup/sync-remote.sh</string><string>$TARGET</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/.agent-remote/logs/sync-$HOST.log</string>
  <key>StandardErrorPath</key><string>$HOME/.agent-remote/logs/sync-$HOST.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "syncing $TARGET every 5 minutes (launchd $LABEL, log ~/.agent-remote/logs/sync-$HOST.log)"
    exit 0 ;;
  --unwatch)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "stopped syncing $TARGET"
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $2" >&2; exit 2 ;;
esac

# What the bridge is built from, plus Pi's extensions it relies on. Unchanged since the last sync: nothing to do.
hash="$(cd "$ROOT" && find bridge/src bridge/Cargo.toml bridge/Cargo.lock setup/pi setup/prime setup/lib setup/bridge-defaults.json -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-40)"
[ "$hash" = "$(cat "$STATE" 2>/dev/null)" ] && exit 0

echo "$(date '+%F %T') syncing $TARGET"
ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET")
rsync -a --delete --exclude target -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$ROOT/bridge" "$ROOT/setup" "$TARGET:shed/"
built=""
if [ "$("${ssh[@]}" uname -m)" = "$(uname -m)" ]; then
  (cd "$ROOT/bridge" && cargo build --release --quiet)
  mkdir -p "$ROOT/bridge/target/remote"
  cp "$ROOT/bridge/target/release/agent-remote" "$ROOT/bridge/target/remote/agent-remote"
  echo "  signed with $("$ROOT/setup/lib/sign-bridge.sh" "$ROOT/bridge/target/remote/agent-remote")"
  rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$ROOT/bridge/target/remote/agent-remote" "$TARGET:shed/agent-remote"
  built=1
fi
"${ssh[@]}" bash -s -- "$built" <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd ~/shed/bridge
if [ -n "$1" ]; then
  mkdir -p target/release && mv ~/shed/agent-remote target/release/agent-remote
else
  cargo build --release --quiet
fi
for extension in subagent background-jobs; do
  rm -rf ~/.pi/agent/extensions/$extension
  cp -R ~/shed/setup/pi/extensions/$extension ~/.pi/agent/extensions/$extension
done
cp ~/shed/setup/pi/agents/*.md ~/.pi/agent/agents/
cp ~/shed/setup/pi/prompts/*.md ~/.pi/agent/prompts/
node ~/shed/setup/lib/configure.mjs prime-models ~/shed/setup/prime/models.json ~/.prime/agent/models.json >/dev/null
node ~/shed/setup/lib/configure.mjs pi-models ~/shed/setup/pi/models.json ~/.pi/agent/models.json >/dev/null
node ~/shed/setup/lib/configure.mjs bridge-defaults ~/shed/setup/bridge-defaults.json ~/.agent-remote/config.json >/dev/null
# The same code signed again differs only in its signing time: compare the code's hash.
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
new="$(cdhash target/release/agent-remote)"
if [ -n "$new" ] && [ "$new" = "$(cdhash ~/.agent-remote/bin/agent-remote)" ]; then
  echo "  bridge unchanged"
else
  install -m 755 target/release/agent-remote ~/.agent-remote/bin/agent-remote
  launchctl kickstart -k "gui/$(id -u)/dev.agentremote.bridge"
  for _ in $(seq 20); do curl -fsS http://127.0.0.1:7878/health >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fsS http://127.0.0.1:7878/health >/dev/null && echo "  bridge updated and restarted"
fi
REMOTE
mkdir -p "$(dirname "$STATE")"
echo "$hash" > "$STATE"
