#!/bin/bash
# Set up Shed on this Mac: Pi and Prime Agent at their latest versions with your API keys, GPT-6.1 Terra and
# Pi's subagent extension; the bridge as a login service; the Mac app; HTTPS access over Tailscale.
# Safe to run again: every step updates in place and keeps settings it doesn't own.
#
#   OPENAI_API_KEY=sk-... setup/install.sh [--no-service] [--no-app] [--no-tailscale]
#
#   Keys are read from OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY and DEEPSEEK_API_KEY, any of them.
#
#   --no-service    build and install the bridge, but don't register it with launchd
#   --no-app        skip building the Mac app
#   --no-tailscale  don't publish the bridge on the tailnet
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${AGENT_REMOTE_PORT:-7878}"
LABEL="dev.agentremote.bridge"
SERVICE=1 APP=1 TAILSCALE=1
for arg in "$@"; do
  case "$arg" in
    --no-service) SERVICE=0 ;;
    --no-app) APP=0 ;;
    --no-tailscale) TAILSCALE=0 ;;
    -h | --help) sed -n '2,12p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname)" = Darwin ] || { echo "Shed supports macOS only." >&2; exit 1; }
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

step "Pi"
if ! command -v pi >/dev/null; then
  # Pi's installer only offers to install Node interactively, so provide it up front when Homebrew can.
  node_ok() { command -v npm >/dev/null && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)' 2>/dev/null; }
  if ! node_ok && command -v brew >/dev/null; then brew install node; fi
  curl -fsSL https://pi.dev/install.sh | sh
else
  pi update --self
fi
pi update --models
note "pi $(pi --version)"

step "DeepSeek Harness"
# The bridge runs dsh with its own plugin, in a `shed` profile it writes on each start. The provider key is set
# once in `dsh web` (Models), which keeps it in ~/.dsh.
if command -v npm >/dev/null; then
  npm install --global --silent @deepseek-ai/dsh@latest
  note "dsh $(npm ls --global --depth 0 @deepseek-ai/dsh 2>/dev/null | sed -n 's/.*@deepseek-ai\/dsh@//p')"
else
  note "skipped: needs Node (npm)"
fi

step "Prime Agent"
before="$(command -v prime-agent >/dev/null && prime-agent --version 2>/dev/null || true)"
if [ -n "$before" ]; then prime-agent update; else curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh; fi
after="$(prime-agent --version)"
note "prime-agent $after"
if [ -n "$before" ] && [ "$before" != "$after" ] && pgrep -f "prime-agent --mode daemon" >/dev/null; then
  note "A Prime daemon from $before is still running. It keeps its sessions; stop it (prime-agent stop --all, or"
  note "quit its sessions) when convenient, and the bridge starts the new version."
fi

# Pi runs on the Node it was installed against: its own (~/.local/share/pi-node) or one already on PATH, such as
# nvm's. The setup's own JSON edits use the same one, and the service PATH below must include it.
NODE="$(command -v node || echo "$HOME/.local/share/pi-node/current/bin/node")"
SERVICE_PATH="$HOME/.local/bin:$(dirname "$NODE"):$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configure() { "$NODE" "$ROOT/setup/lib/configure.mjs" "$@"; }

step "Agent configuration"
if [ -n "${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}${GEMINI_API_KEY:-}${DEEPSEEK_API_KEY:-}" ]; then
  configure auth "$HOME/.pi/agent/auth.json"
  configure auth "$HOME/.prime/agent/auth.json"
else
  note "No API key in the environment: leaving both agents' credentials as they are."
fi
if [ -n "${OPENAI_API_KEY:-}" ]; then
  # Only where no default is set yet, and only with a key that makes it usable.
  configure default-model "$HOME/.pi/agent/settings.json" openai gpt-6.1-terra medium
  configure default-model "$HOME/.prime/agent/settings.json" openai gpt-6.1-terra medium
fi
# Prime's model catalog doesn't list GPT-6.1 Terra or Claude Haiku 5.5 yet. Both agents get its full 1M window; the bridge holds
# sessions to 272k (the standard price) unless one picks a larger window.
configure prime-models "$ROOT/setup/prime/models.json" "$HOME/.prime/agent/models.json"
configure pi-models "$ROOT/setup/pi/models.json" "$HOME/.pi/agent/models.json"
configure bridge-defaults "$ROOT/setup/bridge-defaults.json" "$HOME/.agent-remote/config.json"
# Pi's subagent extension (from Pi's examples) and its agents, which inherit the parent's model, plus background
# commands like Prime's. Both load in Pi's own TUI too.
mkdir -p "$HOME/.pi/agent/extensions" "$HOME/.pi/agent/agents" "$HOME/.pi/agent/prompts"
for extension in subagent background-jobs; do
  rm -rf "$HOME/.pi/agent/extensions/$extension"
  cp -R "$ROOT/setup/pi/extensions/$extension" "$HOME/.pi/agent/extensions/$extension"
done
cp "$ROOT"/setup/pi/agents/*.md "$HOME/.pi/agent/agents/"
cp "$ROOT"/setup/pi/prompts/*.md "$HOME/.pi/agent/prompts/"
note "installed Pi's subagent and background-jobs extensions, agents and prompts"

step "Bridge"
if ! command -v cargo >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
(cd "$ROOT/bridge" && cargo build --release)
note "signed with $("$ROOT/setup/lib/sign-bridge.sh" "$ROOT/bridge/target/release/agent-remote")"
mkdir -p "$HOME/.agent-remote/bin" "$HOME/.agent-remote/logs"
install -m 755 "$ROOT/bridge/target/release/agent-remote" "$HOME/.agent-remote/bin/agent-remote"
note "installed ~/.agent-remote/bin/agent-remote"

if [ "$SERVICE" = 1 ]; then
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$plist")"
  # The bridge spawns pi and starts Prime's daemon, so it needs the PATH the agents were installed with.
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME/.agent-remote/bin/agent-remote</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$SERVICE_PATH</string>
  </dict>
  <key>WorkingDirectory</key><string>$HOME</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Prime's daemon runs in its own process group and must outlive bridge restarts. -->
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$HOME/.agent-remote/logs/bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/.agent-remote/logs/bridge.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    note "bridge running on 127.0.0.1:$PORT (launchd $LABEL, log ~/.agent-remote/logs/bridge.log)"
  else
    note "the bridge didn't answer on port $PORT; see ~/.agent-remote/logs/bridge.log"
  fi
fi

if [ "$APP" = 1 ]; then
  step "Mac app"
  if command -v swift >/dev/null; then
    "$ROOT/apps/scripts/bundle-mac.sh" release
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Shed.app"
    cp -R "$ROOT/apps/build/Shed.app" "$HOME/Applications/"
    note "installed ~/Applications/Shed.app (it reads the local bridge token on its own)"
  else
    note "Swift isn't installed: run xcode-select --install, then rerun this script."
  fi
fi

if [ "$TAILSCALE" = 1 ]; then
  step "Tailscale"
  ts="$(command -v tailscale || true)"
  [ -z "$ts" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  if [ -z "$ts" ]; then
    note "Tailscale isn't installed. Install it (brew install --cask tailscale, or the App Store), log in, rerun."
  elif ! "$ts" status >/dev/null 2>&1; then
    note "Tailscale isn't connected. Log in, then rerun this script."
  else
    # Its own HTTPS port, so an existing `tailscale serve` on 443 is left alone.
    "$ts" serve --bg --https="$PORT" "http://127.0.0.1:$PORT" >/dev/null
    host="$("$ts" status --json | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).Self.DNSName.replace(/\.$/,"")))')"
    note "bridge published on the tailnet: wss://$host:$PORT/ws"
  fi
fi

step "Done"
note "The Mac app on this Mac connects to the bridge on its own."
if [ -n "${host:-}" ]; then
  note "To control this Mac from an iPhone or another Mac, add a computer in Shed with:"
  note "  address  wss://$host:$PORT/ws"
  note "  token    plutil -extract token raw -o - ~/.agent-remote/config.json"
fi
