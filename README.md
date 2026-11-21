# Process Code

A small native Mac editor for working alongside a coding agent. It does the handful of things VS Code is mostly
used for in that setup, in a 4 MB app that idles around 60 MB of memory instead of a 1.6 GB one:

- **A terminal** that opens in the folder with your agent already running (Claude Code by default; Codex, Gemini or
  any command you name). Tabs for more shells. Pasting a copied image works (⌘V), as does Shift-Return for a new
  line in the agent's prompt, and dropping files on the terminal, from Finder or the sidebar, types their paths.
- **One keystroke for a full-height terminal.** ⌘J, the button at the right of the terminal's bar, or a double
  click on that bar gives the terminal the whole window; the same again brings the editor back. Opening a file
  brings the editor back by itself.
- **Focus mode.** With the sidebar hidden and the terminal filling the window or the screen, the bars fade away
  and only the agent's text is left. Move the pointer to the top and they come back; move it away
  and they fade again. Nothing moves when they do, so the terminal never resizes. The lightbulb at the right of
  the terminal's bar (Spotlight) turns this off and on; it's on to begin with.
- **A projects window instead of a welcome page.** A new window lists the git repositories in your projects
  folder (`~/Documents/GitHub` unless you change it), most recently worked on first, each with its branch,
  uncommitted changes and commits waiting to push or pull. Type to filter, Return to open. Clone one of your
  GitHub repositories or start a new one from the same window.
- **A file tree with git status**: new, modified and deleted files are coloured and lettered, and a Changes list
  shows only those. ⌘P finds a file by name.
- **An editor** with syntax colouring for the languages in everyday use (Swift, Python, JavaScript and TypeScript,
  JSON, Rust, C-family, Go, GDScript, Solidity, shell, YAML, TOML, CSS, SQL, HTML, Markdown, LaTeX and more), line
  numbers, find, undo, and indentation that follows the file. Files that change on disk reload by themselves unless
  you've edited them.
- **Previews**: Markdown as GitHub renders it, side by side with the source or alone; PDFs and images; and LaTeX,
  which builds to PDF on save and shows the result beside the source.

Settings are deliberately few: light, dark or the system's, the code font and its size, and which agent starts.

## Requirements

- macOS 27 or later, and Xcode's command line tools to build.
- `git` for the status colours, and the GitHub CLI to clone from your account (`brew install gh`, then
  `gh auth login` once). For LaTeX, a TeX distribution with `latexmk` (MacTeX, or `brew install basictex`).

## Build and install

```sh
git clone https://github.com/edsonayllon/process-code-editor.git
cd process-code-editor
./scripts/build-app.sh --install   # builds and copies Process Code.app to /Applications
./scripts/build-app.sh --update    # the same, then opens the new copy
swift test                         # runs the tests
```

Without a flag the app is left in `build/`. The script signs it with your Apple Development certificate if you
have one, and ad hoc otherwise; with an ad hoc signature macOS asks for folder access again
after each rebuild. Open a folder from the app (⌘O), by dropping it on the Dock icon, or from a shell:

```sh
open -a "Process Code" ~/Documents/GitHub/my-project
```

## Release

`./scripts/build-app.sh --release` builds the app, signs it with a Developer ID Application certificate,
packs it into `build/ProcessCode.dmg`, has Apple notarise it, staples the ticket and checks the result the way
Gatekeeper will. It needs two things once per Mac:

1. A **Developer ID Application** certificate in the keychain: Xcode → Settings → Accounts → your team →
   Manage Certificates → + → Developer ID Application.
2. A notarytool profile named `notary`, using an app-specific password from account.apple.com:

   ```sh
   xcrun notarytool store-credentials notary --apple-id <your Apple ID> --team-id <your Team ID>
   ```

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
| Save (builds LaTeX)                      | ⌘S        |
| Close tab / close window                 | ⌘W / ⇧⌘W  |
| Toggle comment                           | ⌘/        |
| Bigger / smaller text                    | ⌘+ / ⌘−   |
| New window (the projects list)           | ⇧⌘N       |
| Open any folder                          | ⌘O        |
| Settings                                 | ⌘,        |

⌘W never closes a terminal: a terminal tab closes from its own button, and asks first if something is running.

## Projects

The list is every folder in the projects folder that is a git repository, plus any folder you opened from
somewhere else (those can be removed from the list with a right click; nothing on disk is touched). A green dot
marks a project that already has a window, and choosing it brings that window forward. The repository reading,
cloning and creating come from [Lean GitHub](https://github.com/edsonayllon/lean-github-app), which remains the
place to publish a repository, see whether it is private, or move it to the Trash.

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
