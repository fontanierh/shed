#!/bin/bash
# Sign the bridge binary with a lasting identity, so macOS keeps its answers to the bridge's permission prompts
# (reading Documents, Desktop, Downloads) from one build to the next. Signed ad hoc, as the linker leaves it, every
# build looks like a new app and is asked again, and an agent's command waits on the prompt until someone answers.
#
#   setup/lib/sign-bridge.sh path/to/agent-remote
#
#   Uses SHED_SIGN_IDENTITY if set ("-" for ad hoc), else the first Developer ID Application or Apple Development
#   certificate in the keychain. Prints the identity used.
set -euo pipefail

binary="${1:?usage: setup/lib/sign-bridge.sh path/to/agent-remote}"
identities="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "(.*)"$/\1/p')"
identity="${SHED_SIGN_IDENTITY:-$(grep -m1 '^Developer ID Application: ' <<<"$identities" || grep -m1 '^Apple Development: ' <<<"$identities" || true)}"

if [ -z "$identity" ] || [ "$identity" = - ]; then
  codesign --force --sign - --identifier dev.agentremote.bridge "$binary"
  echo "ad hoc (no signing certificate in the keychain)"
else
  codesign --force --sign "$identity" --identifier dev.agentremote.bridge --timestamp=none "$binary"
  echo "$identity"
fi
