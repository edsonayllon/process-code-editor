# Lean Code

A small native Mac editor for working alongside a coding agent. It does the handful of things VS Code is mostly
used for in that setup, in a 4 MB app that idles around 60 MB of memory instead of a 1.6 GB one:

- **A terminal** that opens in the folder with your agent already running (Claude Code by default; Codex, Gemini or
  any command you name). Tabs for more shells. Pasting a copied image works (⌘V), as does Shift-Return for a new
  line in the agent's prompt, and dropping files on the terminal types their paths.
- **One keystroke for a full-height terminal.** ⌘J, the button at the right of the terminal's bar, or a double
  click on that bar gives the terminal the whole window; the same again brings the editor back. Opening a file
  brings the editor back by itself.
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

- macOS 14 or later, and Xcode's command line tools to build.
- `git` for the status colours, and the GitHub CLI to clone from your account (`brew install gh`, then
  `gh auth login` once). For LaTeX, a TeX distribution with `latexmk` (MacTeX, or `brew install basictex`).

## Build and install

```sh
./scripts/build-app.sh --install   # builds and copies Lean Code.app to /Applications
swift test                         # runs the tests
```

Without `--install` the app is left in `build/`. Open a folder from the app (⌘O), by dropping it on the Dock icon,
or from a shell:

```sh
open -a "Lean Code" ~/Documents/GitHub/resume
```

## Shortcuts

| Action                                   | Keys      |
| ---------------------------------------- | --------- |
| Fill the window with the terminal / back | ⌘J        |
| Hide or show the terminal                | ⇧⌘J       |
| Hide or show the sidebar                 | ⌘B        |
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
"build/Lean Code.app/Contents/MacOS/LeanCode" . --shell --open README.md --mode split --layout split \
    --appearance dark --snapshot /tmp/shot.png
```
