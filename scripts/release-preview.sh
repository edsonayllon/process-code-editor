#!/bin/bash
# Prints, as Markdown, the version and release notes that scripts/release.sh would give if HEAD were the
# release branch: for a pull request into release, run it on the merge result. It publishes nothing and needs
# no GitHub access: semantic-release runs dry against a throwaway copy of this repository, with only the
# plugins that read commits, so nothing is built, tagged or pushed.
#
#   scripts/release-preview.sh            # in a checkout of the merge (what the workflow does)
#
# The workflow .github/workflows/release-preview.yml runs it on pull requests into release and posts the result.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d "${TMPDIR:-/tmp}/release-preview.XXXXXX")
trap 'rm -rf "$work"' EXIT

# A bare copy whose release branch is HEAD, with every tag, so semantic-release sees release as it would be.
git clone --quiet --bare . "$work/origin.git"
git push --quiet --force "$work/origin.git" HEAD:refs/heads/release
git clone --quiet --branch release "$work/origin.git" "$work/tree"

# Last in the notes step, it sees the notes the generator wrote and keeps them as written (a dry run prints
# them reformatted for a terminal).
cat > "$work/capture.cjs" <<'JS'
const fs = require("fs");
const path = require("path");
module.exports.generateNotes = (_, { nextRelease }) => {
  fs.writeFileSync(path.join(__dirname, "version"), nextRelease.version);
  fs.writeFileSync(path.join(__dirname, "notes.md"), nextRelease.notes || "");
  return "";
};
JS

# Without the CI's variables, so it reads the branch from git and doesn't stop because this is a pull request.
# The alarm ends a hung run (npx fetching, say) after 4 minutes.
(cd "$work/tree" && env -i PATH="$PATH" HOME="$HOME" perl -e 'alarm 240; exec @ARGV' npx --yes \
  -p semantic-release@25 \
  semantic-release --dry-run --no-ci --branches release --repository-url "file://$work/origin.git" \
  --plugins @semantic-release/commit-analyzer,@semantic-release/release-notes-generator,"$work/capture.cjs" \
  > "$work/log" 2>&1) || { cat "$work/log" >&2; exit 1; }

# The notes link to commits through the copy; point them at the repository on GitHub instead.
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  repo="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
else
  repo=$(git remote get-url origin | sed -E 's#^git@github\.com:#https://github.com/#; s#\.git$##')
fi
[ -f "$work/notes.md" ] && sed -E -i.bak "s#https?:/+[^()]*release-preview\.[A-Za-z0-9]+/origin#$repo#g" "$work/notes.md"

last=$(git -C "$work/tree" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
if [ -f "$work/version" ]; then
  echo "### Merging this releases v$(cat "$work/version")"
  echo
  echo "From \`${last:-the first commit}\`, once \`scripts/release.sh\` runs on release. These will be the notes:"
  echo
  cat "$work/notes.md"
else
  echo "### Merging this doesn't make a release"
  echo
  echo "Nothing since \`${last:-the first commit}\` is a \`feat\`, \`fix\`, \`perf\` or breaking change, so \`scripts/release.sh\` would stop."
fi
