#!/bin/bash
# Cuts a release from main with semantic-release, on this Mac (no GitHub Actions). The commits since the last
# tag decide the version (fix: patch, feat: minor, a breaking change: major); with nothing to release it stops
# there. Otherwise it builds and notarises the DMG at that version (build-app.sh --release), pushes the tag
# vX.Y.Z and publishes a GitHub release with ProcessCode.dmg attached. Pass --dry-run to see the next version
# and its notes without building or publishing anything.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  "" | --dry-run) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

# The tag has to name a commit that is on GitHub and holds exactly what was built.
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
  echo "Releases are cut from main; this is $(git rev-parse --abbrev-ref HEAD)." >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first; a release is built from a clean tree." >&2; exit 1
fi
git fetch --quiet --tags origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "main and origin/main differ. Push or pull first." >&2; exit 1
fi

GH_TOKEN="${GH_TOKEN:-$(gh auth token)}"
export GH_TOKEN

[ -n "${1:-}" ] || swift test

# Pinned, and fetched by npx so the repo needs no package.json. The alarm ends a hung run after 40 minutes
# (notarisation alone gives up after 20).
perl -e 'alarm 2400; exec @ARGV' npx --yes \
  -p semantic-release@25 -p @semantic-release/exec@7 -p @semantic-release/github@12 \
  semantic-release --no-ci "$@"
