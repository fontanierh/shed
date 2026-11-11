#!/bin/bash
# Set up Shed on this Mac, step by step: Open Codex (the gateway every agent's models go through) with your
# API keys and subscriptions; Pi, Prime Agent and DeepSeek Harness at their latest versions; the bridge as a login
# service; the Mac app; HTTPS access over Tailscale; the iPhone app. Safe to run again: every step updates in place,
# keeps settings it doesn't own, and only asks for what is still missing.
#
#   setup/install.sh [--no-opencodex] [--no-service] [--no-app] [--no-tailscale] [--no-iphone]
#
#   API keys are read from OPENAI_API_KEY, ANTHROPIC_API_KEY, MISTRAL_API_KEY, DEEPSEEK_API_KEY, GEMINI_API_KEY and
#   OPENROUTER_API_KEY, or asked for when run in a terminal; FIRECRAWL_API_KEY turns on web search for the agents. SHED_TEAM_ID (and optionally SHED_BUNDLE_ID) builds
#   the iPhone app onto a connected iPhone.
#
#   --no-opencodex  give Pi and Prime the keys directly instead of going through Open Codex: the OpenAI, Anthropic,
#                   Gemini and DeepSeek ones, from the environment only
#   --no-service    build and install the bridge, but don't register it with launchd
#   --no-app        skip building the Mac app
#   --no-tailscale  don't publish the bridge on the tailnet
#   --no-iphone     don't build the iPhone app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${AGENT_REMOTE_PORT:-7878}"
LABEL="dev.agentremote.bridge"
# The Open Codex release new installs get: setup/opencodex/*.patch are made against it.
OPENCODEX_VERSION="2.97.0"
OPENCODEX=1 SERVICE=1 APP=1 TAILSCALE=1 IPHONE=1
for arg in "$@"; do
  case "$arg" in
    --no-opencodex) OPENCODEX=0 ;;
    --no-service) SERVICE=0 ;;
    --no-app) APP=0 ;;
    --no-tailscale) TAILSCALE=0 ;;
    --no-iphone) IPHONE=0 ;;
    -h | --help) sed -n '2,18p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[ "$(uname)" = Darwin ] || { echo "Shed supports macOS only." >&2; exit 1; }
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
# Questions only when someone is at the terminal; otherwise the defaults (skip) apply.
interactive() { [ -t 0 ] && [ -t 1 ]; }
ask() { interactive && { read -r -p "  $1 [y/N] " answer; [[ "$answer" =~ ^[Yy] ]]; }; }
# What the summary at the end reports, one line per part.
summary=()

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
# Pi installs its own Node/npm in ~/.local/share/pi-node/current/bin on Macs without Homebrew or system Node:
# put it on PATH now so DeepSeek Harness and Open Codex find npm too.
[ -d "$HOME/.local/share/pi-node/current/bin" ] && export PATH="$HOME/.local/share/pi-node/current/bin:$PATH"
note "pi $(pi --version)"
summary+=("Pi $(pi --version)")

step "DeepSeek Harness"
# The bridge runs dsh with its own plugin, in a `shed` profile it writes on each start. With Open Codex, that profile
# gives dsh Open Codex's models; without it, the provider key is set once in `dsh web` (Models), kept in ~/.dsh.
if command -v npm >/dev/null; then
  npm install --global --silent @deepseek-ai/dsh@latest
  dsh_version="$(npm ls --global --depth 0 @deepseek-ai/dsh 2>/dev/null | sed -n 's/.*@deepseek-ai\/dsh@//p')"
  note "dsh $dsh_version"
  summary+=("DeepSeek Harness $dsh_version")
else
  note "skipped: needs Node (npm)"
fi

step "Prime Agent"
before="$(command -v prime-agent >/dev/null && prime-agent --version 2>/dev/null || true)"
if [ -n "$before" ]; then prime-agent update; else curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh; fi
after="$(prime-agent --version)"
note "prime-agent $after"
summary+=("Prime Agent $after")
if [ -n "$before" ] && [ "$before" != "$after" ] && pgrep -f "prime-agent --mode daemon" >/dev/null; then
  note "A Prime daemon from $before is still running. It keeps its sessions; stop it (prime-agent stop --all, or"
  note "quit its sessions) when convenient, and the bridge starts the new version."
fi

# Pi runs on the Node it was installed against: its own (~/.local/share/pi-node) or one already on PATH, such as
# nvm's. The setup's own JSON edits use the same one, and the service PATH below must include it.
NODE="$(command -v node || echo "$HOME/.local/share/pi-node/current/bin/node")"
SERVICE_PATH="$HOME/.local/bin:$(dirname "$NODE"):$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
configure() { "$NODE" "$ROOT/setup/lib/configure.mjs" "$@"; }

if [ "$OPENCODEX" = 1 ]; then
  step "Open Codex"
  # Every agent's models come from Open Codex: the bridge writes its catalog into Pi's, Prime's and dsh's
  # configuration and offers nothing else, so a key or login added here reaches all of them. An Open Codex already on
  # this Mac is used as it is, never upgraded: it may carry local patches of its own.
  pkg="${OPENCODEX_PACKAGE:-}"
  if [ -z "$pkg" ]; then
    for candidate in "$HOME/.local/share/opencodex-runtime/node_modules/@bitkyc08/opencodex" \
      "$(npm root --global 2>/dev/null || true)/@bitkyc08/opencodex"; do
      [ -f "$candidate/package.json" ] && { pkg="$candidate"; break; }
    done
  fi
  if [ -z "$pkg" ]; then
    command -v npm >/dev/null || { echo "Open Codex needs Node (npm), and neither PATH nor ~/.local/share/pi-node had it." >&2; exit 1; }
    npm install --global --silent "@bitkyc08/opencodex@$OPENCODEX_VERSION"
    pkg="$(npm root --global)/@bitkyc08/opencodex"
  fi
  ocx_version="$("$NODE" -p "require('$pkg/package.json').version")"
  # Its bundled Bun runs it directly, so it works without Node on PATH.
  bun=""
  for candidate in "$pkg/node_modules/bun/bin/bun.exe" "$(dirname "$(dirname "$pkg")")/bun/bin/bun.exe"; do
    [ -x "$candidate" ] && { bun="$candidate"; break; }
  done
  ocx() { if [ -n "$bun" ]; then "$bun" "$pkg/src/cli/index.ts" "$@"; else "$NODE" "$pkg/bin/ocx.mjs" "$@"; fi; }
  note "Open Codex $ocx_version ($pkg)"
  patched="$("$ROOT/setup/lib/patch-opencodex.sh" "$pkg" "$ocx_version")"
  printf '%s\n' "$patched" | grep -v '^changed$' || true
  # /v1/models answers on every version (/readyz is newer).
  ready() { curl -fsS http://127.0.0.1:10100/v1/models >/dev/null 2>&1; }
  if [ -f "$HOME/Library/LaunchAgents/com.opencodex.proxy.plist" ]; then
    # A restart loads the patches just applied.
    if [[ "$patched" == *changed ]]; then launchctl kickstart -k "gui/$(id -u)/com.opencodex.proxy"; fi
  else
    # Open Codex's own service: a login item on 127.0.0.1:10100. It may ask a question or two of its own.
    ocx service install || note "Open Codex's service didn't install; run: ocx service install"
  fi
  for _ in $(seq 1 40); do ready && break; sleep 0.5; done
  if ready; then
    note "proxy running on 127.0.0.1:10100 (dashboard http://localhost:10100)"
    [ -f "$HOME/.opencodex/admin-api-token" ] || note "no ~/.opencodex/admin-api-token yet: the apps' spend figures need it"
  else
    note "Open Codex didn't answer on port 10100; see ~/.opencodex/service.log"
  fi

  # API keys. Each goes to Open Codex alone, on stdin, so it never shows in ps; a provider that has one is left be.
  has_account() { ocx account list "$1" --json 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.exit(JSON.parse(s).accounts?.some(a=>!process.argv[1]||a.type===process.argv[1])?0:1)}catch{process.exit(1)}})' "${2:-}"; }
  if ready; then
    keyed=()
    for entry in "OPENAI_API_KEY openai-apikey OpenAI" "ANTHROPIC_API_KEY anthropic-apikey Anthropic" \
      "MISTRAL_API_KEY mistral Mistral" "DEEPSEEK_API_KEY deepseek DeepSeek" "GEMINI_API_KEY google Gemini" \
      "OPENROUTER_API_KEY openrouter OpenRouter"; do
      read -r variable provider label <<<"$entry"
      if has_account "$provider"; then keyed+=("$label"); continue; fi
      key="${!variable:-}"
      if [ -z "$key" ] && interactive; then
        read -r -s -p "  $label API key (Enter to skip): " key; echo
      fi
      [ -n "$key" ] || continue
      ocx provider add "$provider" --live --json >/dev/null 2>&1 || true
      if printf '%s' "$key" | ocx account add-key "$provider" --label shed --json >/dev/null 2>&1; then
        keyed+=("$label"); note "added the $label key"
      else
        note "Open Codex didn't take the $label key; add it in the dashboard (Providers)"
      fi
    done
    unset key
    [ "${#keyed[@]}" -gt 0 ] && note "API keys: ${keyed[*]}"

    # Subscriptions sign in through the browser, so only on request.
    if has_account openai codex; then
      note "ChatGPT subscription: signed in"
    elif ask "Sign in with a ChatGPT subscription (its models show as \"ChatGPT subscription\")?"; then
      ocx account login openai || note "not signed in; retry with: ocx account login openai"
    else
      note "ChatGPT subscription: not signed in (later: the dashboard, or ocx account login openai)"
    fi
    # A Claude subscription is for Anthropic's own apps: the bridge leaves its models out, so Claude comes from the
    # Anthropic API key alone.
    models="$(curl -fsS http://127.0.0.1:10100/v1/models 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).data.length)}catch{console.log(0)}})')"
    note "$models models available to every agent"
    summary+=("Open Codex $ocx_version: $models models")
  else
    summary+=("Open Codex $ocx_version: not running (see ~/.opencodex/service.log)")
  fi
fi

step "Agent configuration"
if [ "$OPENCODEX" = 0 ]; then
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
  configure opencodex "$HOME/.agent-remote/config.json" off
else
  # The bridge writes Open Codex's models into both agents; this only picks a starting default where none is set:
  # GPT-6.1 Terra through the OpenAI key, or else through the ChatGPT subscription.
  terra="gpt-6.1-terra"
  [ -n "${OPENAI_API_KEY:-}" ] || has_account openai-apikey && terra="openai-apikey/gpt-6.1-terra"
  configure default-model "$HOME/.pi/agent/settings.json" opencodex "$terra" medium
  configure default-model "$HOME/.prime/agent/settings.json" opencodex "$terra" medium
  configure opencodex "$HOME/.agent-remote/config.json" on
fi
# The model lists, the bridge's defaults, and Pi's extensions, agents and prompts: the same list sync-remote.sh
# applies on another Mac.
"$ROOT/setup/lib/agent-files.sh" "$ROOT/setup" "$NODE"
# Web search and page reading for every agent, through the bridge's shed-web command.
configure web "$HOME/.agent-remote/config.json"
note "installed Pi's subagent and background-jobs extensions, agents and prompts"

step "Bridge"
if ! command -v cargo >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
(cd "$ROOT/bridge" && cargo build --release)
# On its own line: a signing that fails stops here instead of installing the build unsigned.
identity="$("$ROOT/setup/lib/sign-bridge.sh" "$ROOT/bridge/target/release/agent-remote")"
note "signed with $identity"
mkdir -p "$HOME/.agent-remote/bin" "$HOME/.agent-remote/logs"
# The same code signed again differs only in its signing time: the code's hash says whether the bridge changed.
cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
installed_code="$(cdhash "$HOME/.agent-remote/bin/agent-remote")"
install -m 755 "$ROOT/bridge/target/release/agent-remote" "$HOME/.agent-remote/bin/agent-remote"
new_code="$(cdhash "$HOME/.agent-remote/bin/agent-remote")"
note "installed ~/.agent-remote/bin/agent-remote"

if [ "$SERVICE" = 1 ]; then
  plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$plist")"
  # The bridge spawns pi and starts Prime's daemon, so it needs the PATH the agents were installed with.
  wanted="$(mktemp)"
  cat > "$wanted" <<PLIST
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
  # Restarted only when something changed: a restart ends every Pi and DeepSeek turn in progress, and a rerun of the
  # installer for one setting should not.
  if [ -n "$new_code" ] && [ "$new_code" = "$installed_code" ] && cmp -s "$wanted" "$plist" \
    && launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    rm -f "$wanted"
    note "bridge unchanged, left running"
  else
    mv "$wanted" "$plist"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
  fi
  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    note "bridge running on 127.0.0.1:$PORT (launchd $LABEL, log ~/.agent-remote/logs/bridge.log)"
    summary+=("Bridge: running on 127.0.0.1:$PORT")
  else
    note "the bridge didn't answer on port $PORT; see ~/.agent-remote/logs/bridge.log"
    summary+=("Bridge: not answering (see ~/.agent-remote/logs/bridge.log)")
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
    summary+=("Mac app: ~/Applications/Shed.app")
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
    summary+=("Tailscale: wss://$host:$PORT/ws")
  fi
fi

if [ "$IPHONE" = 1 ]; then
  step "iPhone app"
  # Built from source with your own Apple account, onto an iPhone paired with this Mac.
  team="${SHED_TEAM_ID:-}"
  if [ -z "$team" ] && command -v xcodebuild >/dev/null && interactive &&
    ask "Build the iPhone app onto a connected iPhone now (needs Xcode signed in to an Apple account)?"; then
    read -r -p "  Apple team ID (Xcode > Settings > Accounts): " team
    read -r -p "  Bundle ID [dev.agentremote.shed]: " SHED_BUNDLE_ID
  fi
  if [ -n "$team" ]; then
    if "$ROOT/apps/scripts/install-iphone.sh" "$team" "${SHED_BUNDLE_ID:-dev.agentremote.shed}"; then
      summary+=("iPhone app: installed")
    else
      summary+=("iPhone app: not installed (see above)")
    fi
  else
    note "Later, with the iPhone connected and Developer Mode on:"
    note "  apps/scripts/install-iphone.sh <TEAM_ID> com.<you>.shed"
    summary+=("iPhone app: apps/scripts/install-iphone.sh <TEAM_ID> com.<you>.shed")
  fi
fi

step "Done"
if [ "${#summary[@]}" -gt 0 ]; then
  for line in "${summary[@]}"; do note "$line"; done
  echo
fi
note "The Mac app on this Mac connects to the bridge on its own."
if [ -n "${host:-}" ]; then
  note "To control this Mac from an iPhone or another Mac, add a computer in Shed with:"
  note "  address  wss://$host:$PORT/ws"
  note "  token    plutil -extract token raw -o - ~/.agent-remote/config.json"
fi
if [ "$OPENCODEX" = 1 ]; then
  note "Keys, subscriptions and models: the Open Codex dashboard at http://localhost:10100. A model added there"
  note "shows in every agent within a minute."
fi
