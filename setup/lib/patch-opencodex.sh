#!/bin/bash
# Apply Shed's Open Codex fixes (setup/opencodex/*.patch) to an installed Open Codex until a release carries them.
# Each patch is applied only where it fits cleanly; one the installed version already has, or that it has drifted
# from, is left out with a note. Whether a patch is in is read from the package's files each time. Applied patches
# are recorded the way Open Codex local patches are, in
# ~/.opencodex/local-patches/<name>/ (manifest.json, and the files as they were under before/), so a reinstall or
# upgrade of Open Codex can be checked against them.
#
#   setup/lib/patch-opencodex.sh <package dir> <version>
#
# Exits 0 and prints "changed" on its last line when it applied anything (the proxy must restart to load it).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="${1:?usage: patch-opencodex.sh <package dir> <version>}"
VERSION="${2:?usage: patch-opencodex.sh <package dir> <version>}"
STORE="${OPENCODEX_HOME:-$HOME/.opencodex}/local-patches"
changed=0

for patch in "$ROOT"/setup/opencodex/*.patch; do
  name="$(basename "$patch" .patch)"
  dir="$STORE/$name"
  manifest="$dir/manifest.json"
  # Recorded for this very version, by this script or by hand (a backport of the same fix). The record is kept
  # outside the package, so it outlives a reinstall of the same version: the package's files decide, not the record.
  recorded=0
  if [ -f "$manifest" ] && grep -q "\"runtime_version\": \"$VERSION\"" "$manifest"; then
    recorded=1
  fi
  if patch -p1 -R --dry-run -s -f -d "$PKG" <"$patch" >/dev/null 2>&1; then
    if [ "$recorded" = 1 ]; then
      echo "  $name: applied"
    else
      echo "  $name: already in Open Codex $VERSION"
    fi
    continue
  fi
  if ! patch -p1 --dry-run -s -f -d "$PKG" <"$patch" >/dev/null 2>&1; then
    if [ "$recorded" = 1 ]; then
      # A backport by hand need not match the patch line for line, so this is not known to be wrong. Left as it is.
      echo "  $name: recorded as applied to Open Codex $VERSION, but the files differ from the patch: check by hand"
    else
      echo "  $name: doesn't fit Open Codex $VERSION, left out"
    fi
    continue
  fi
  [ "$recorded" = 1 ] && echo "  $name: recorded as applied, but Open Codex $VERSION no longer has it (reinstalled?)"
  files=()
  while IFS= read -r line; do files+=("$line"); done < <(sed -n 's|^+++ b/||p' "$patch")
  rm -rf "$dir/before"
  mkdir -p "$dir/before"
  entries=()
  for file in "${files[@]}"; do
    if [ -f "$PKG/$file" ]; then
      mkdir -p "$dir/before/$(dirname "$file")"
      cp -p "$PKG/$file" "$dir/before/$file"
      entries+=("{\"path\": \"$file\", \"existed\": true, \"before_sha256\": \"$(shasum -a 256 "$PKG/$file" | cut -d' ' -f1)\"}")
    else
      entries+=("{\"path\": \"$file\", \"existed\": false}")
    fi
  done
  patch -p1 -s -f -d "$PKG" <"$patch"
  {
    printf '{\n  "runtime_version": "%s",\n  "files": [\n' "$VERSION"
    for i in "${!entries[@]}"; do printf '    %s%s\n' "${entries[$i]}" "$([ "$i" -lt $((${#entries[@]} - 1)) ] && echo ,)"; done
    printf '  ],\n  "source": "Shed setup/opencodex/%s.patch",\n  "applied_at": "%s"\n}\n' "$name" "$(date +%FT%T%z)"
  } >"$manifest"
  echo "  $name: applied to Open Codex $VERSION"
  changed=1
done
[ "$changed" = 1 ] && echo changed
exit 0
