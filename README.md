# Shed

Shed lets you run coding agents on your Macs and drive them from anywhere. It works with [Pi](https://pi.dev) and [Prime Agent](https://app.primeintellect.ai/prime-agent): start a session on your desk machine, watch it think and run tools from your phone, and steer it.

<p align="center">
  <img src="docs/images/mac.png" alt="Shed on macOS: the session list for two computers, and a Prime session's transcript" width="100%">
</p>

<p align="center">
  <img src="docs/images/iphone-sessions.png" alt="Shed on iPhone: sessions grouped by computer" width="32%">
  &nbsp;&nbsp;
  <img src="docs/images/iphone-session.png" alt="Shed on iPhone: a session with subagent reports" width="32%">
</p>

## What it does

- **One session list for every computer.** Sessions from each Mac running the bridge, Pi and Prime side by side, including Prime sessions started in its own TUI.
- **The full transcript, live.** Reasoning, tool calls and their output, file edits, images and audio stream in as the agent works.
- **Steer while it runs.** Messages sent during a turn steer it; the rest queue. Stop, compact, and switch model, reasoning effort or context window from the composer.
- **Subagents and background commands.** Child sessions show under their parent and open like any other. Shell commands an agent leaves running are listed with live output and can be cancelled.
- **Context and cost at a glance.** A gauge for the context window, and the session's spend so far.
- **Runaway protection.** The bridge stops a reply that has degenerated into whitespace or the same few characters repeated, and tells the agent why.
- **On the iPhone,** a Live Activity follows a running session from the Lock Screen and the Dynamic Island.

## How it works

```
 iPhone app ─┐                                         ┌─ pi --mode rpc      one process per Pi session
             ├─ WebSocket over Tailscale ──► bridge ───┤
 Mac app ────┘                              (:7878)    └─ Prime daemon       every Prime session and subagent
```

Each computer runs the **bridge**, a small Rust service that drives the agents installed there and turns both into one protocol. The **apps** connect to one or more bridges. The bridge listens on `127.0.0.1` only; [Tailscale](https://tailscale.com) makes it reachable from your other devices, privately and over HTTPS. Sessions belong to the agents, not to Shed: quit the app, or restart the bridge, and they keep running.

[docs/architecture.md](docs/architecture.md) covers the design in more depth.

## Requirements

- macOS 15 or later on each computer that runs agents, with the Xcode command line tools (`xcode-select --install`).
- An API key for at least one model provider: OpenAI, Anthropic, Google or DeepSeek.
- [Tailscale](https://tailscale.com/download), to reach the bridge from another device. Not needed to use the Mac app on the same Mac.
- For the iPhone app: iOS 18 or later, and Xcode with an Apple account (a free one works).

The installer takes care of Rust, Pi, Prime Agent and, through Homebrew when available, Node.

## Getting started

### 1. Install on a Mac

```bash
git clone https://github.com/fontanierh/shed.git && cd shed
OPENAI_API_KEY=sk-... setup/install.sh
```

Pass any of `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY` and `DEEPSEEK_API_KEY`. The script:

- installs or updates Pi and Prime Agent, and gives both your keys;
- adds model definitions their catalogs lack yet (GPT-6.1 Terra, Claude Haiku 5.5) and, with an OpenAI key, makes GPT-6.1 Terra the default where none is set;
- installs Pi's subagent and background-jobs extensions;
- builds the bridge and registers it as a login service on `127.0.0.1:7878`;
- installs `~/Applications/Shed.app`;
- publishes the bridge on your tailnet (see below).

It is safe to run again, and that is how you update: every step updates in place and leaves settings it doesn't own alone. `--no-app`, `--no-service` and `--no-tailscale` skip those steps.

Open **Shed** from `~/Applications`. On the Mac that runs the bridge, the app finds it and its token on its own.

### 2. Reach it over Tailscale

The bridge executes whatever the agents decide to run, so it never listens on a network interface. Tailscale gives your devices a private network (a *tailnet*) and lets the bridge join it without opening a port:

1. Install Tailscale on the Mac (`brew install --cask tailscale`, or from the App Store) and on your iPhone, and sign in to the same account on both.
2. In the [admin console](https://login.tailscale.com/admin/dns), enable **MagicDNS** and **HTTPS Certificates**, so the Mac gets a name and a certificate on the tailnet.
3. Run `setup/install.sh` again if Tailscale wasn't set up the first time. It runs

   ```bash
   tailscale serve --bg --https=7878 http://127.0.0.1:7878
   ```

   which serves the bridge at `wss://<mac>.<tailnet>.ts.net:7878/ws`, to devices on your tailnet only. Port 7878 keeps it clear of anything you already serve on 443.

The installer ends by printing that address, and the command that prints the bridge's token:

```bash
plutil -extract token raw -o - ~/.agent-remote/config.json
```

Every connection must present this token, in addition to coming from your tailnet.

### 3. Install the iPhone app

The iPhone app is built from source with your own Apple account. Connect the iPhone by cable once, turn on Developer Mode (Settings › Privacy & Security), and find your team ID in Xcode › Settings › Accounts. Then:

```bash
apps/scripts/install-iphone.sh <TEAM_ID> com.<you>.shed
```

On first launch, enter the address and token from step 2. With a free Apple account the app must be reinstalled every 7 days; a paid developer account extends that to a year.

### 4. Add more computers

Run `setup/install.sh` on each Mac that should run agents, then add it in the apps: the network button next to the Shed title (⌘, on the Mac) opens **Computers**, where **Add Computer** takes its address and token. Sessions from all of them share one list, grouped by computer.

To keep a remote Mac's bridge in step with your checkout, run this from your own Mac over SSH:

```bash
setup/sync-remote.sh user@host            # copy, build there, restart the bridge if it changed
setup/sync-remote.sh user@host --watch    # and repeat every 5 minutes from launchd
```

## Uninstall

```bash
setup/uninstall.sh
```

This removes the login service, the Tailscale publication and the Mac app. Pi, Prime Agent, their settings and sessions, and `~/.agent-remote` are left in place.

## Development

```
bridge/        Rust bridge: protocol, Pi and Prime drivers, transcript normalization
  scripts/     end-to-end checks against a running bridge (smoke, subagents, resume)
apps/          Swift package: ShedKit (shared client and views) and ShedMac
  iOS/         iPhone app and Live Activity, generated with XcodeGen from project.yml
  scripts/     bundle-mac.sh, install-iphone.sh
setup/         installer, uninstaller, remote sync, vendored Pi and Prime configuration
docs/          architecture and the Prime daemon protocol
```

```bash
cd bridge && cargo test && cargo clippy --all-targets   # bridge unit tests and lints
apps/scripts/bundle-mac.sh debug                        # build apps/build/Shed.app
node bridge/scripts/smoke.mjs pi 7878 ~/src/project     # drive a live session through a running bridge
```

The wire protocol is defined in [`bridge/src/protocol.rs`](bridge/src/protocol.rs) and mirrored in [`apps/Sources/ShedKit/Protocol.swift`](apps/Sources/ShedKit/Protocol.swift); change both together. After editing `apps/iOS/project.yml`, regenerate the Xcode project with `xcodegen` in `apps/iOS`.

## License

Shed is released under the [MIT License](LICENSE). It includes [Nordwand Mono](apps/Resources/Fonts/NordwandMono-LICENSE.txt) (SIL Open Font License 1.1), uses [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) (MIT), and adapts Pi's subagent example extension (MIT).
