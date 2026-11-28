#!/bin/bash
# Tries Process Code as someone new to it: without a coding agent, without the GitHub CLI, or
# signed out of GitHub, so the install and sign-in buttons can be tried for real.
#
#   scripts/try-setup.sh [--no-claude] [--signed-out] [--no-gh] [folder]
#
#   --no-claude   Terminals start in an empty home folder, so no agent is installed there and the
#                 agent's tab offers to install it. The install goes into that folder too.
#   --signed-out  gh and git use their own empty settings, so the GitHub sign-in runs for real and
#                 its git setup lands in a copy of your ~/.gitconfig. gh keeps tokens in the Keychain,
#                 so signing in as yourself replaces the token your own gh uses; it keeps working.
#   --no-gh       Uninstalls Homebrew's gh, so Install GitHub CLI can be tried. If it's still
#                 missing when the app quits, it's installed again.
#
# It runs the debug build, which keeps its own settings, so your saved windows don't open and no
# agent starts in them. The folders it makes are deleted when the app quits.
set -euo pipefail
cd "$(dirname "$0")/.."

no_claude=false signed_out=false no_gh=false folder=""
for argument in "$@"; do
  case "$argument" in
    --no-claude) no_claude=true ;;
    --signed-out) signed_out=true ;;
    --no-gh) no_gh=true ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $argument" >&2; exit 1 ;;
    *) folder="$argument" ;;
  esac
done

swift build
scratch=$(mktemp -d "${TMPDIR:-/tmp}/process-code-try.XXXXXX")
arguments=()

finish() {
  if $no_gh && [ ! -x /opt/homebrew/bin/gh ] && [ ! -x /usr/local/bin/gh ]; then
    echo "Putting gh back: brew install gh"
    brew install gh || echo "Couldn't install gh again. Run: brew install gh" >&2
  fi
  rm -rf "$scratch"
  if $signed_out; then
    echo "If you signed in as yourself, your own gh now uses the new token. Check: gh auth status"
  fi
}
trap finish EXIT

if $no_claude; then
  mkdir -p "$scratch/home"
  [ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$scratch/home/.gitconfig"
  arguments+=(--terminal-home "$scratch/home")
  echo "Terminals start in $scratch/home, with no agent installed."
fi

if $signed_out; then
  mkdir -p "$scratch/gh"
  export GH_CONFIG_DIR="$scratch/gh"
  if [ -f "$HOME/.gitconfig" ]; then cp "$HOME/.gitconfig" "$scratch/gitconfig"; else : > "$scratch/gitconfig"; fi
  export GIT_CONFIG_GLOBAL="$scratch/gitconfig"
  echo "gh is signed out, with its settings in $scratch/gh."
fi

if $no_gh; then
  if ! command -v brew >/dev/null || ! brew list --formula gh >/dev/null 2>&1; then
    echo "--no-gh needs gh installed by Homebrew, to take it away and put it back." >&2
    exit 1
  fi
  brew uninstall gh
  echo "gh is uninstalled. Install GitHub CLI in the Projects window puts it back."
fi

if [ -n "$folder" ]; then
  arguments+=("$(cd "$folder" && pwd)")
fi

echo "Quit the app to finish."
.build/debug/ProcessCode "${arguments[@]+"${arguments[@]}"}"
