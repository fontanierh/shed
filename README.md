# Shed

Control Pi and Prime Agent sessions running on a Mac from the Mac app (and, later, an iPhone) over Tailscale: steer, watch reasoning and tool calls, track context and cost, compact, switch models and effort, and follow subagents.

## Set up a Mac

Requirements: macOS 15+, Xcode command line tools (`xcode-select --install`), and Tailscale installed and logged in. The script installs Rust, Pi and Prime Agent itself. Node comes from Homebrew when it's available; otherwise Pi's installer offers it.

```bash
OPENAI_API_KEY=sk-... setup/install.sh
```

The script:

- installs or updates Pi and Prime Agent, and refreshes their model catalogs
- adds the OpenAI key to both agents
- adds GPT-6.1 Terra to Prime
- makes `openai/gpt-6.1-terra` (medium) the default model, if no default is set yet
- installs Pi's subagent and background-jobs extensions (background commands like Prime's, also in Pi's own TUI)
- installs the bridge as a login service on `127.0.0.1:7878`
- installs `~/Applications/Shed.app`
- publishes the bridge on the tailnet at `wss://<mac>.<tailnet>.ts.net:7878/ws`

Run it again at any time to update everything. Flags: `--no-service`, `--no-app`, `--no-tailscale`. `setup/uninstall.sh` removes the service, the tailnet publication and the app.

To run a bridge on another Mac, run `setup/install.sh --no-app` there once, then keep it in step with this checkout from here with `setup/sync-remote.sh user@host`. It copies the source over SSH, builds it there and restarts that bridge only when the binary changed; `--watch` runs it every 5 minutes from launchd, `--unwatch` stops that.

Other devices need the bridge token in `~/.agent-remote/config.json`. The Mac app on the same machine picks it up on its own.

## Layout

- `bridge/` is the Rust bridge. `PRIME-DAEMON.md` documents Prime's daemon protocol, and `scripts/` has end-to-end checks (`smoke.mjs`, `subagents.mjs`, `async-subagents.mjs`, `resume-check.mjs`).
- `apps/` holds `AgentRemoteKit` (shared with the future iOS app) and the Mac app. Build it with `apps/scripts/bundle-mac.sh`.
- `setup/` holds the installer and the vendored agent configuration.
- `DESIGN.md` covers the architecture and how each feature maps to each agent.
