// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProcessCode",
    platforms: [.macOS("27.0")],
    dependencies: [
        // The terminal emulator (pty, rendering, input).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // GitHub-flavoured Markdown to HTML, for the preview. The repository has no version tags.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
        // Finds, verifies and installs new versions of the app.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "ProcessCode",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ProcessCode"
        ),
        .testTarget(name: "ProcessCodeTests", dependencies: ["ProcessCode"], path: "Tests/ProcessCodeTests"),
    ]
)
