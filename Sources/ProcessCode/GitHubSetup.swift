import AppKit

/// Where setting up the GitHub CLI has got to, from the projects window.
enum GitHubSetupStep: Equatable {
    case idle
    /// Something is under way, described in a few words.
    case working(String)
    /// GitHub's download page is open, for a Mac without Homebrew.
    case downloading
    /// `gh auth login` is waiting for the code to be entered on GitHub; nil until gh gives it.
    case signingIn(code: String?)
    case failed(String)
}

/// One button to install the GitHub CLI (with Homebrew), and one to sign in to it, so cloning,
/// publishing and the privacy locks work without a trip to the terminal.
extension ProjectStore {
    static let deviceLoginPage = URL(string: "https://github.com/login/device")!
    static let downloadPage = URL(string: "https://cli.github.com")!

    nonisolated static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installs gh with Homebrew. Without Homebrew it opens GitHub's download page instead: the
    /// macOS installer there isn't signed, and the app won't run an unsigned installer for you.
    func installGitHubCLI() {
        guard let brew = ProjectStore.homebrew else {
            openPage(ProjectStore.downloadPage)
            setupStep = .downloading
            return
        }
        setupStep = .working("Installing the GitHub CLI with Homebrew…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Shell.run(brew, ["install", "gh"], timeout: 900)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if result.status == 0 {
                    self.setupStep = .idle
                    self.recheckGitHub()
                } else {
                    let said = ProjectStore.lastLines(of: result.output)
                    self.setupStep = .failed(result.status == 124
                        ? "Homebrew didn't finish in 15 minutes. Try again, or run brew install gh in a terminal."
                        : "Homebrew couldn't install it: \(said)")
                }
            }
        }
    }

    /// Signs in through the browser: gh hands out a one-time code and waits while it's entered on
    /// GitHub's page. Run without a terminal, gh doesn't open the page itself, and only newer
    /// versions copy the code, so both are done here.
    func signInToGitHub() {
        guard signIn == nil else { return }
        signInCancelled = false
        setupStep = .signingIn(code: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "login", "--web", "--hostname", "github.com", "--git-protocol", "https"]
        // As tried by hand: with prompts turned off, as everything else here runs gh, it may
        // refuse to start a sign-in at all.
        var environment = Shell.environment
        environment["GH_PROMPT_DISABLED"] = nil
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        // gh's last words (why it failed) may still be in the pipe when it exits, so the outcome
        // waits for both its exit and the end of its output, or 2 seconds after the exit if
        // something it started keeps the output open. A cancelled one that failed has nothing to
        // say; one that had already succeeded is finished as a success.
        var said = "", status: Int32?, outputEnded = false, done = false
        func finishIfDone(_ store: ProjectStore) {
            guard let status, outputEnded || (store.signInCancelled && status != 0), !done else { return }
            done = true
            output.fileHandleForReading.readabilityHandler = nil
            store.signIn = nil
            store.finishSignIn = nil
            if store.signInCancelled && status != 0 {
                store.setupStep = .idle
            } else if status == 0 {
                store.setupStep = .working("Finishing sign-in…")
                DispatchQueue.global(qos: .userInitiated).async { [weak store] in
                    // So git pushes and pulls over HTTPS with the same sign-in.
                    Shell.run("/usr/bin/env", ["gh", "auth", "setup-git"], timeout: ProjectStore.ghTimeout)
                    DispatchQueue.main.async { [weak store] in
                        store?.setupStep = .idle
                        store?.recheckGitHub(signedIn: true)
                    }
                }
            } else {
                store.setupStep = .failed(ProjectStore.explain(Shell.Result(status: status, output: said), tool: "gh"))
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !data.isEmpty else {
                    outputEnded = true
                    return finishIfDone(self)
                }
                said += chunk
                if self.setupStep == .signingIn(code: nil), let code = ProjectStore.deviceCode(in: said) {
                    self.setupStep = .signingIn(code: code)
                    self.copyText(code)
                    self.openPage(ProjectStore.deviceLoginPage)
                }
            }
        }
        finishSignIn = { [weak self] in if let self { finishIfDone(self) } }
        process.terminationHandler = { [weak self] finished in
            let exit = finished.terminationStatus
            DispatchQueue.main.async { [weak self] in
                status = exit
                if let self { finishIfDone(self) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    outputEnded = true
                    if let self { finishIfDone(self) }
                }
            }
        }
        do {
            try process.run()
            signIn = process
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            setupStep = .failed("The GitHub CLI couldn't be started: \(error.localizedDescription)")
        }
    }

    func cancelSignIn() {
        signInCancelled = true
        signIn?.terminate()
        finishSignIn?()
        if signIn == nil { setupStep = .idle }
    }

    /// Asks gh again whether it's installed and signed in, then reads the locks if it is. `signedIn`
    /// says a sign-in has just succeeded.
    func recheckGitHub(signedIn: Bool = false) {
        DispatchQueue.global(qos: .utility).async {
            let result = Shell.run("/usr/bin/env", ["gh", "auth", "status", "--hostname", "github.com"], timeout: ProjectStore.ghTimeout)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.githubSetup = ProjectStore.githubSetup(after: result, was: self.githubSetup, signedIn: signedIn)
                if self.githubSetup == nil { self.loadPrivacy(force: true) }
                if self.githubSetup != .notInstalled, self.setupStep == .downloading { self.setupStep = .idle }
            }
        }
    }

    /// What's left to set up after `gh auth status` gave `result`, given what was left before. A
    /// failure that names neither a missing CLI nor a missing sign-in (a timeout, no network) says
    /// nothing about either, so it changes only what it must: gh answered, so it's installed, and a
    /// sign-in that just succeeded counts.
    nonisolated static func githubSetup(after result: Shell.Result, was before: GitHubSetup?, signedIn: Bool) -> GitHubSetup? {
        if result.status == 0 { return nil }
        if let known = githubSetup(from: result) { return known }
        if signedIn { return nil }
        return before == .notInstalled ? .signedOut : before
    }

    /// The one-time code in what `gh auth login --web` says, such as "ABCD-1234".
    nonisolated static func deviceCode(in output: String) -> String? {
        output.range(of: "\\b[A-Z0-9]{4}-[A-Z0-9]{4}\\b", options: .regularExpression).map { String(output[$0]) }
    }

    nonisolated static func lastLines(of output: String, count: Int = 3) -> String {
        output.split(separator: "\n").suffix(count).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
