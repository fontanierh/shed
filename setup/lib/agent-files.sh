#!/bin/bash
# What Shed adds to the agents' own configuration, on this Mac: Pi's subagent and background-jobs extensions (both
# load in Pi's own TUI too), its agents and prompts, the model lists for Pi and Prime, and the bridge's defaults.
# One list, run by `install.sh` here and by `sync-remote.sh` on the Mac it keeps in step.
#
#   setup/lib/agent-files.sh <setup dir> <node>
set -euo pipefail

SETUP="${1:?usage: agent-files.sh <setup dir> <node>}"
NODE="${2:?usage: agent-files.sh <setup dir> <node>}"
configure() { "$NODE" "$SETUP/lib/configure.mjs" "$@"; }

# Prime's model catalog doesn't list every model Open Codex offers. Both agents get each model's full window; the
# bridge holds sessions to the standard price unless one picks a larger window.
configure prime-models "$SETUP/prime/models.json" "$HOME/.prime/agent/models.json"
configure pi-models "$SETUP/pi/models.json" "$HOME/.pi/agent/models.json"
configure bridge-defaults "$SETUP/bridge-defaults.json" "$HOME/.agent-remote/config.json"

mkdir -p "$HOME/.pi/agent/extensions" "$HOME/.pi/agent/agents" "$HOME/.pi/agent/prompts"
for extension in subagent background-jobs; do
  rm -rf "$HOME/.pi/agent/extensions/$extension"
  cp -R "$SETUP/pi/extensions/$extension" "$HOME/.pi/agent/extensions/$extension"
done
cp "$SETUP"/pi/agents/*.md "$HOME/.pi/agent/agents/"
cp "$SETUP"/pi/prompts/*.md "$HOME/.pi/agent/prompts/"
