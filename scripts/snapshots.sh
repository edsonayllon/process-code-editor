#!/bin/bash
# Renders the app's screens to build/snapshots/, in light and dark, so a change to how it looks can be
# judged on every screen at once. The workspace shots use a throwaway clone of this repository with a
# modified, an added and a deleted file in it, since a clean folder shows none of the git colours.
#
#     ./scripts/snapshots.sh            # all screens
#     ./scripts/snapshots.sh focus      # only the screens whose name contains "focus"
#
# The windows open on screen for a few seconds each; leave the pointer off them.
set -euo pipefail
cd "$(dirname "$0")/.."

ONLY="${1:-}"
OUT="$PWD/build/snapshots"
DEMO="$(mktemp -d)/demo"
trap 'rm -rf "$(dirname "$DEMO")"' EXIT

swift build 2>&1 | tail -1
BIN="$PWD/.build/debug/ProcessCode"
mkdir -p "$OUT"

git clone -q . "$DEMO"
(
  cd "$DEMO"
  echo "// a change" >> Sources/ProcessCode/Theme.swift
  echo "A change." >> README.md
  echo "Notes." > Notes.md
  git rm -q LICENSE
)

# The sixteen terminal colours, then git's own, then a word with the caret moved back onto it.
# (`echo` ends each row: a "\n" here would be typed as Return.)
COLOURS='clear; for i in 0 1 2 3 4 5 6 7; do printf "\\e[3${i}m colour$i \\e[9${i}m bright$i \\e[0m"; echo; done; git status -s\n'
COLOURS+=$'caret\e[D\e[D\e[D'

# shot <name> <arguments…>: one picture per appearance. A run that hangs is killed after 40 seconds.
shot() {
  local name="$1"; shift
  [[ -z "$ONLY" || "$name" == *"$ONLY"* ]] || return 0
  for appearance in dark light; do
    local file="$OUT/$name-$appearance.png"
    rm -f "$file"
    perl -e 'alarm 40; exec @ARGV' "$BIN" "$@" --appearance "$appearance" --snapshot "$file" >/dev/null 2>&1 || true
    [ -f "$file" ] && echo "$file" || echo "FAILED: $name-$appearance" >&2
  done
}

SIZE=(--size 1400x900)
shot split    "$DEMO" --shell "${SIZE[@]}" --open Sources/ProcessCode/Theme.swift --layout split --type "$COLOURS" --delay 3.5
shot changes  "$DEMO" --shell "${SIZE[@]}" --open Sources/ProcessCode/Theme.swift --layout editor --sidebar changes --delay 3
shot markdown "$DEMO" --shell "${SIZE[@]}" --open README.md --mode split --layout editor --delay 3
shot focus    "$DEMO" --shell "${SIZE[@]}" --layout terminal --sidebar hidden --type "$COLOURS" --delay 3.5
shot bars     "$DEMO" --shell "${SIZE[@]}" --layout terminal --sidebar hidden --reveal-bars --type "$COLOURS" --delay 3.5
shot projects --delay 3
shot settings "$DEMO" --shell --settings --delay 2.5
