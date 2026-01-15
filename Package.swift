// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "claude-statusline",
  platforms: [.macOS(.v14)],
  products: [
    .executable(
      name: "claude-statusline",
      targets: ["claude-statusline"]
    ),
  ],
  dependencies: [
    // PR comment library for multi-platform support
    .package(
      url: "https://github.com/promptping-ai/pull-request-ping",
      from: "0.1.0"
    ),
    // CLI argument parsing
    .package(
      url: "https://github.com/apple/swift-argument-parser",
      from: "1.3.0"
    ),
    // Modern subprocess execution
    .package(
      url: "https://github.com/swiftlang/swift-subprocess",
      from: "0.1.0"
    ),
  ],
  targets: [
    .executableTarget(
      name: "claude-statusline",
      dependencies: [
        .product(name: "PullRequestPing", package: "pull-request-ping"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ]
    ),
    .testTarget(
      name: "ClaudeStatuslineTests",
      dependencies: ["claude-statusline"]
    ),
  ]
)
