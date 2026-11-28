# Process Code

A small native Mac editor for working alongside a coding agent. It does the handful of things VS Code is mostly
used for in that setup, in a 4 MB app that idles around 60 MB of memory instead of a 1.6 GB one:

- **A terminal** that opens in the folder with your agent already running (Claude Code by default; Codex, Gemini or
  any command you name). Claude Code carries on the folder's last conversation (`claude --continue`) when there is
  one (Settings can turn this off); a new agent tab (⇧⌘A) starts fresh, and so do Codex, Gemini and custom
  commands. Tabs for more shells. Pasting a copied image works (⌘V), as does Shift-Return for a new line in the
  agent's prompt, and dropping files on the terminal, from Finder or the sidebar, types their paths. If the agent
  isn't installed, its tab says so with one button that installs it in that terminal and starts it: Anthropic's
  installer for Claude Code, Homebrew (or npm without it) for Codex and Gemini.
- **One keystroke for a full-height terminal.** ⌘J, the button at the right of the terminal's bar, or a double
  click on that bar gives the terminal the whole window; the same again brings the editor back. Opening a file
  brings the editor back by itself.
- **Focus mode.** With the sidebar hidden and the terminal filling the window or the screen, the bars fade away
  and only the agent's text is left. Move the pointer to the top and they come back; move it away
  and they fade again. Nothing moves when they do, so the terminal never resizes. The lightbulb at the right of
  the terminal's bar (Spotlight) turns this off and on; it's on to begin with.
- **A projects window instead of a welcome page.** A new window lists the git repositories in your projects
  folder (`~/Documents/GitHub` unless you change it), most recently worked on first, each with its branch,
  uncommitted changes and commits waiting to push or pull, and a lock on the private ones. Type to filter,
  Return to open. Clone one of your GitHub repositories or start a new one from the same window, publish one to
  GitHub, or move one to the Trash.
- **A file tree with git status**: new, modified and deleted files are coloured and lettered, and a Changes list
  shows only those. ⌘P finds a file by name.
- **An editor** with syntax colouring for the languages in everyday use (Swift, Python, JavaScript and TypeScript,
  JSON, Rust, C-family, Go, GDScript, Solidity, shell, YAML, TOML, CSS, SQL, HTML, Markdown, LaTeX and more), line
  numbers, find, undo, and indentation that follows the file. Files that change on disk reload by themselves unless
  you've edited them.
- **Nothing to save before you go.** Unsaved changes are kept as you type. Quit, close the window or crash, and
  reopening the folder brings back the same tabs with the changes still unsaved. If a file changed on disk in the
  meantime, the tab says so and you choose Keep Mine or Reload. Only closing a single tab asks whether to save.
  The changes wait as plain text in `~/Library/Application Support/Process Code/Drafts` until they're saved or let
  go, so anything secret typed and not saved is there too.
- **Previews**: Markdown as GitHub renders it, side by side with the source or alone; PDFs, images and videos; and
  LaTeX, which builds to PDF on save and shows the result beside the source.
- **Two files side by side.** Option-click a file in the sidebar (or right-click it, Open to the Side) and it opens
  beside the one that's showing, each under its name. Clicking other files then changes the first pane and leaves the
  second where it is. With a video in each, one button in the top bar plays both from the same moment and another
  takes both back to the start, and a video that's rendered again is shown again at the same place.

Settings are deliberately few: light, dark or the system's, the code font and its size, which agent starts, and
a button that checks for a new version.

## Requirements

- macOS 27 or later, and Xcode's command line tools to build.
- `git` for the status colours, and the GitHub CLI to clone from your account, publish to it and see which
  repositories are private (`brew install gh`, then `gh auth login` once). For LaTeX, a TeX distribution with `latexmk` (MacTeX, or `brew install basictex`).

## Download

The notarised app is attached to every [release](https://github.com/edsonayllon/process-code-editor/releases);
the newest is always at
<https://github.com/edsonayllon/process-code-editor/releases/latest/download/ProcessCode.dmg>. Open the DMG and
drag Process Code to Applications.

The app looks for a new version each time it opens, and when you choose Check for Updates… in Settings or the
Process Code menu. A new version found as it opens is downloaded quietly, its signature checked, and put in place
when you next quit, so nothing interrupts you and nothing running in a terminal is cut short. Check for Updates…
offers to install it at once. Versions 1.0.0 and 1.1.0 came before
this and don't update themselves: download the newest once by hand. A copy built from source doesn't update
itself either.

## Build and install

```sh
git clone https://github.com/edsonayllon/process-code-editor.git
cd process-code-editor
./scripts/build-app.sh --install   # builds and copies Process Code.app to /Applications
./scripts/build-app.sh --update    # the same, then opens the new copy
swift test                         # runs the tests
scripts/try-setup.sh --no-claude --signed-out   # tries the install and sign-in buttons as a new user would
```

`scripts/try-setup.sh` runs the debug build, which has its own settings, so none of your windows open. Its
`--no-claude` starts terminals in an empty home folder with the system's PATH, so no agent is found and
installing Claude Code goes there (Codex and Gemini install with Homebrew or npm, for the whole Mac).
`--signed-out` gives gh and git empty settings of their own, so the GitHub sign-in runs for real; gh keeps its
token in the Keychain, so signing in as yourself replaces the one your own gh uses, which keeps working. `--no-gh`
uninstalls Homebrew's gh to try Install GitHub CLI, and puts it back on quit if it's still missing. The folders it
makes are deleted when the app quits.

Without a flag the app is left in `build/`. The script signs it with your Apple Development certificate if you
have one, and ad hoc otherwise; with an ad hoc signature macOS asks for folder access again
after each rebuild. Open a folder from the app (⌘O), by dropping it on the Dock icon, or from a shell:

```sh
open -a "Process Code" ~/Documents/GitHub/my-project
```

## Release

```sh
gh pr create --base release --head main --fill   # bring main into release; the PR shows the coming version and notes
git switch release && git pull
./scripts/release.sh --dry-run   # the version and notes the commits since the last tag would give
./scripts/release.sh             # test, build, notarise, tag vX.Y.Z and publish the DMG and its feed on GitHub
git switch main
```

Releases are cut on this Mac from the `release` branch with [semantic-release](https://semantic-release.gitbook.io), not in
GitHub Actions, because signing and notarising need the Mac's keychain. `scripts/release.sh` refuses to run on any
other branch or in CI. The commit messages since the last tag
decide the version: a `fix:` makes a patch, a `feat:` a minor and a breaking change a major; with only `docs:`,
`chore:` and the like there is nothing to release. It needs Node 24.10 or later and a logged-in GitHub CLI.
Work lands on `main` and reaches `release` only through a pull request from `main`; `release` has to be clean
and match GitHub. On that pull request a GitHub Actions check (`.github/workflows/release-preview.yml`, about a
minute on Linux) runs `scripts/release-preview.sh` and comments the version and notes the merge will release. It
only reads commits; nothing is built or published there. The website's download button points at the latest release, so it needs no
change afterwards.

The build step is `./scripts/build-app.sh --release`, which builds the app, signs it with a Developer ID Application certificate,
packs it into `build/ProcessCode.dmg`, has Apple notarise it, staples the ticket and checks the result the way
Gatekeeper will. It then signs the disk image for [Sparkle](https://sparkle-project.org), the updater inside the
app, and writes `build/appcast.xml`, the feed that names this version, its download and that signature. Both
files are attached to the release, and installed copies read the feed at
`releases/latest/download/appcast.xml`. It needs three things once per Mac:

1. A **Developer ID Application** certificate in the keychain: Xcode → Settings → Accounts → your team →
   Manage Certificates → + → Developer ID Application.
2. A notarytool profile named `notary`, using an app-specific password from account.apple.com:

   ```sh
   xcrun notarytool store-credentials notary --apple-id <your Apple ID> --team-id <your Team ID>
   ```
3. The Sparkle key. Make it once, ever:

   ```sh
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   The private half goes into the login keychain; the public half is printed, and goes into
   `SPARKLE_PUBLIC_KEY` at the top of `scripts/build-app.sh`, which is committed. Every released app accepts
   only updates signed with this key, so **keep a copy of the private key somewhere safe**
   (`generate_keys -x sparkle-private-key` writes it to a file, `generate_keys -f sparkle-private-key` reads
   it into another Mac's keychain). If it's lost, no installed copy can be updated again. A release stops
   before it builds anything if the key in the keychain isn't the one in the script.

Every build runs under the hardened runtime with `Resources/ProcessCode.entitlements`, so a local build
behaves like the release. Notarisation takes a few minutes and gives up after 20.

## Shortcuts

| Action                                   | Keys      |
| ---------------------------------------- | --------- |
| Fill the window with the terminal / back | ⌘J        |
| Hide or show the terminal                | ⇧⌘J       |
| Hide or show the sidebar                 | ⌘B        |
| Hide or show the margins                 | ⇧⌘M       |
| Files / Changes                          | ⌃⌘G       |
| Go to file                               | ⌘P        |
| Start the agent in a new tab             | ⇧⌘A       |
| New terminal tab                         | ⌘T        |
| Clear the terminal                       | ⌘K        |
| Next / previous tab (of the focused pane)| ⇧⌘] / ⇧⌘[ |
| Source, side by side, preview            | ⇧⌘V       |
| Move the tab to the side / close the side| ⌘\         |
| Save (builds LaTeX)                      | ⌘S        |
| Close tab / close window                 | ⌘W / ⇧⌘W  |
| Toggle comment                           | ⌘/        |
| Bigger / smaller text                    | ⌘+ / ⌘−   |
| New window (the projects list)           | ⇧⌘N       |
| Open any folder                          | ⌘O        |
| Settings                                 | ⌘,        |

⌘W never closes a terminal: a terminal tab closes from its own button, and asks first if something is running.

Move to Trash in the sidebar asks first only when emptying the Trash would lose something: changes git doesn't
have (new, modified or ignored files, or a folder that isn't a repository) or unsaved text in an open file.
Edit ▸ Undo (⌘Z) puts it back. In an editor, ⌘Z and ⇧⌘Z go through its typing and the Trash in the order they
happened.

## Projects

The list is every folder in the projects folder that is a git repository, plus any folder you opened from
somewhere else (those can be removed from the list with a right click; nothing on disk is touched). A green dot
marks a project that already has a window, and choosing it brings that window forward. A lock marks a repository
that is private on GitHub; the list shows first and asks GitHub afterwards, so the locks never hold it up.

- **New Repo…** starts a repository, and can publish it to your GitHub account straight away, private or public.
- **Publish to GitHub…**, on the right click of a repository marked "not on GitHub", makes the GitHub repository,
  sets it as `origin` and pushes.
- **Move to Trash…** moves the folder to the Trash, where it can be put back. It never deletes anything outright
  and never touches GitHub, and it says first what would be lost: changes not committed, commits not pushed, or
  a repository that isn't on GitHub at all. A project with a window open on it, or on a folder inside it, can't be moved; close the window first. A window open on a folder above it closes the project's tabs.

All of this goes through the GitHub CLI's sign-in (`gh auth login`), so the app has no login of its own. If the
CLI isn't installed or signed in, a line at the foot of the window fixes it with one button: Install GitHub CLI
runs `brew install gh` (without Homebrew it opens GitHub's download page, since GitHub's Mac installer isn't
signed), and Sign In to GitHub opens GitHub in the browser with the one-time code on the clipboard. Close the
line and it stays closed; the same button still turns up in the Clone, New Repo and Publish sheets when one of
them can't go on without it. This replaces the separate Repo Select app.

## LaTeX

Saving a `.tex` file builds it. If the folder has LaTeX Workshop settings in `.vscode/settings.json`, the build
runs that recipe (so a project with its own build script keeps working unchanged). Otherwise it runs `latexmk`,
with XeLaTeX or LuaLaTeX when the source asks for one. The PDF shown is `name.pdf` beside the source, or the PDF in
that folder whose name contains the source's. A failed build shows a warning in the bar; click it for the errors.

## How it's built

Swift, AppKit and SwiftUI, with two dependencies: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the
terminal and [cmark-gfm](https://github.com/swiftlang/swift-cmark) for Markdown. PDFs use PDFKit and the Markdown
preview uses the system's WebKit, so neither adds to the app's size.

The window can photograph itself, which is how its design is checked:

```sh
"build/Process Code.app/Contents/MacOS/ProcessCode" . --shell --open README.md --mode split --layout split \
    --appearance dark --snapshot /tmp/shot.png
```

## License

[MIT](LICENSE). The app links SwiftTerm (MIT) and cmark-gfm (BSD 2-Clause); anyone who distributes a built copy
must include those projects' licence notices with it.
