// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ProcessCode",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The terminal emulator (pty, rendering, input).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // GitHub-flavoured Markdown to HTML, for the preview. The repository has no version tags.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    ],
    targets: [
        .executableTarget(
            name: "ProcessCode",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/ProcessCode"
        ),
        .testTarget(name: "ProcessCodeTests", dependencies: ["ProcessCode"], path: "Tests/ProcessCodeTests"),
    ]
)
